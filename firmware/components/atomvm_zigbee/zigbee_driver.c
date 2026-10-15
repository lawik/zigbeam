/*
 * AtomVM port driver for Espressif esp-zigbee-lib (v2 "ezb" API).
 *
 * Exposes the ESP32-C6 as a Zigbee 3.0 End Device with a Home Automation
 * on/off light endpoint. Erlang side opens it with
 *     open_port({spawn, "zigbee"}, [])
 * and talks to it with port:call/2 (see Zigbeam.Zigbee for the protocol).
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <sdkconfig.h>

#if defined(CONFIG_AVM_ENABLE_ZIGBEE_PORT_DRIVER) && defined(CONFIG_ZB_ENABLED)

#include <string.h>

#include <esp_coexist.h>
#include <esp_log.h>
#include <esp_wifi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <nvs_flash.h>
#include <esp_timer.h>
#include <driver/gpio.h>

#include <esp_zigbee.h>
#include <ezbee/zha.h>

#include <atom.h>
#include <context.h>
#include <defaultatoms.h>
#include <globalcontext.h>
#include <interop.h>
#include <mailbox.h>
#include <memory.h>
#include <port.h>
#include <portnifloader.h>
#include <scheduler.h>
#include <term.h>

#define TAG "zigbee_driver"

#define ZB_STORAGE_PARTITION "zb_storage"
#define ZB_TASK_STACK 6144
#define ZB_TASK_PRIO 5
#define ZB_ALL_CHANNELS_MASK 0x07FFF800U /* channels 11..26 */
#define ZB_MAX_ZCL_STRING 32
#define PORT_REPLY_SIZE (TUPLE_SIZE(2) + TERM_BOXED_REFERENCE_SHORT_SIZE)

static const char *const zigbee_atom = "\x6" "zigbee";
static const char *const joined_atom = "\x6" "joined";
static const char *const left_atom = "\x4" "left";
static const char *const steering_failed_atom = "\xF" "steering_failed";
static const char *const signal_atom = "\x6" "signal";
static const char *const attribute_atom = "\x9" "attribute";
static const char *const started_atom = "\x7" "started";
static const char *const factory_new_atom = "\xB" "factory_new";
static const char *const pan_id_atom = "\x6" "pan_id";
static const char *const short_addr_atom = "\xA" "short_addr";
static const char *const channel_atom = "\x7" "channel";
static const char *const ext_pan_id_atom = "\xA" "ext_pan_id";
static const char *const ieee_addr_atom = "\x9" "ieee_addr";
static const char *const endpoint_atom = "\x8" "endpoint";
static const char *const already_started_atom = "\xF" "already_started";
static const char *const not_started_atom = "\xB" "not_started";
static const char *const zcl_error_atom = "\x9" "zcl_error";
static const char *const zb_error_atom = "\x8" "zb_error";
static const char *const aps_data_atom = "\x8" "aps_data";
static const char *const aps_confirm_atom = "\xB" "aps_confirm";

/* Raw APS data path used for Erlang distribution between boards: HA profile,
 * a manufacturer-specific cluster id, our own endpoint on both ends. */
#define ZIGBEAM_APS_PROFILE 0x0104
#define ZIGBEAM_APS_CLUSTER 0xFC42
#define ZIGBEAM_APS_MAX_ASDU 1024

enum zigbee_cmd
{
    ZigbeeInvalidCmd = 0,
    ZigbeeStartCmd,
    ZigbeeStatusCmd,
    ZigbeeJoinCmd,
    ZigbeeLeaveCmd,
    ZigbeeFactoryResetCmd,
    ZigbeeSetAttributeCmd,
    ZigbeeApsSubscribeCmd,
    ZigbeeApsSendCmd,
    ZigbeeCloseCmd
};

static const AtomStringIntPair cmd_table[] = {
    { ATOM_STR("\x5", "start"), ZigbeeStartCmd },
    { ATOM_STR("\x6", "status"), ZigbeeStatusCmd },
    { ATOM_STR("\x4", "join"), ZigbeeJoinCmd },
    { ATOM_STR("\x5", "leave"), ZigbeeLeaveCmd },
    { ATOM_STR("\xD", "factory_reset"), ZigbeeFactoryResetCmd },
    { ATOM_STR("\xD", "set_attribute"), ZigbeeSetAttributeCmd },
    { ATOM_STR("\xD", "aps_subscribe"), ZigbeeApsSubscribeCmd },
    { ATOM_STR("\x8", "aps_send"), ZigbeeApsSendCmd },
    { ATOM_STR("\x5", "close"), ZigbeeCloseCmd },
    SELECT_INT_DEFAULT(ZigbeeInvalidCmd)
};

struct ZigbeeData
{
    GlobalContext *global;
    int32_t owner_process_id;
    int32_t aps_process_id; /* receiver of {zigbee, {aps_data, ..}} / {aps_confirm, ..}; 0 = owner */
    bool started;
    bool auto_join;
    uint8_t endpoint;
    uint32_t channel_mask;
    /* ZCL character strings: length byte + payload */
    char manufacturer[ZB_MAX_ZCL_STRING + 1];
    char model[ZB_MAX_ZCL_STRING + 1];
};

/* The Zigbee stack is a process-wide singleton, so is this. */
static struct ZigbeeData *zb_data = NULL;

/* ------------------------------------------------------------------------ */
/* helpers                                                                   */
/* ------------------------------------------------------------------------ */

static inline term make_atom(GlobalContext *global, const char *atom_str)
{
    return globalcontext_make_atom(global, atom_str);
}

static inline term existing_atom(GlobalContext *global, const char *atom_str)
{
    return globalcontext_existing_term_from_atom_string(global, atom_str);
}

static void ensure_atoms(GlobalContext *global)
{
    /* Atoms used from the Zigbee task must already exist, since inserting
     * atoms concurrently with the scheduler is not safe. */
    make_atom(global, zigbee_atom);
    make_atom(global, joined_atom);
    make_atom(global, left_atom);
    make_atom(global, steering_failed_atom);
    make_atom(global, signal_atom);
    make_atom(global, attribute_atom);
    make_atom(global, pan_id_atom);
    make_atom(global, short_addr_atom);
    make_atom(global, channel_atom);
    make_atom(global, ext_pan_id_atom);
    make_atom(global, ieee_addr_atom);
    make_atom(global, started_atom);
    make_atom(global, factory_new_atom);
    make_atom(global, endpoint_atom);
    make_atom(global, zcl_error_atom);
    make_atom(global, zb_error_atom);
    make_atom(global, aps_data_atom);
    make_atom(global, aps_confirm_atom);
}

static term error_tuple(Context *ctx, term reason)
{
    port_ensure_available(ctx, TUPLE_SIZE(2));
    return port_create_error_tuple(ctx, reason);
}

static term error_atom_tuple(Context *ctx, const char *reason_atom)
{
    return error_tuple(ctx, make_atom(ctx->global, reason_atom));
}

/* Copy an Erlang binary or charlist into a ZCL pascal string. */
static void term_to_zcl_string(term t, char *out, GlobalContext *global)
{
    size_t len = 0;
    if (term_is_binary(t)) {
        len = term_binary_size(t);
        if (len > ZB_MAX_ZCL_STRING) {
            len = ZB_MAX_ZCL_STRING;
        }
        memcpy(out + 1, term_binary_data(t), len);
    } else if (term_is_list(t)) {
        int ok;
        char *s = interop_term_to_string(t, &ok);
        if (ok && s) {
            len = strlen(s);
            if (len > ZB_MAX_ZCL_STRING) {
                len = ZB_MAX_ZCL_STRING;
            }
            memcpy(out + 1, s, len);
            free(s);
        }
    }
    out[0] = (char) len;
}

/* ------------------------------------------------------------------------ */
/* messages to the owning Erlang process (called from the Zigbee task)       */
/* ------------------------------------------------------------------------ */

static void send_event_tuple(term event_payload_builder_result, Heap *heap)
{
    struct ZigbeeData *d = zb_data;
    term msg = term_alloc_tuple(2, heap);
    term_put_tuple_element(msg, 0, existing_atom(d->global, zigbee_atom));
    term_put_tuple_element(msg, 1, event_payload_builder_result);
    port_send_message_from_task(d->global, term_from_local_process_id(d->owner_process_id), msg);
}

static void send_joined(void)
{
    struct ZigbeeData *d = zb_data;
    ezb_extpanid_t ext_pan_id;
    ezb_nwk_get_extended_panid(&ext_pan_id);
    uint16_t pan_id = ezb_nwk_get_panid();
    uint16_t short_addr = ezb_nwk_get_short_address();
    uint8_t channel = ezb_nwk_get_current_channel();

    /* {zigbee, {joined, [{pan_id, N}, {short_addr, N}, {channel, N}, {ext_pan_id, <<...>>}]}} */
    size_t size = TUPLE_SIZE(2) + TUPLE_SIZE(2) + LIST_SIZE(4, TUPLE_SIZE(2)) + TERM_BINARY_HEAP_SIZE(8);
    BEGIN_WITH_STACK_HEAP(size, heap);
    {
        term list = term_nil();
        term t;

        t = term_alloc_tuple(2, &heap);
        term_put_tuple_element(t, 0, existing_atom(d->global, ext_pan_id_atom));
        term_put_tuple_element(t, 1, term_from_literal_binary(&ext_pan_id, 8, &heap, d->global));
        list = term_list_prepend(t, list, &heap);

        t = term_alloc_tuple(2, &heap);
        term_put_tuple_element(t, 0, existing_atom(d->global, channel_atom));
        term_put_tuple_element(t, 1, term_from_int(channel));
        list = term_list_prepend(t, list, &heap);

        t = term_alloc_tuple(2, &heap);
        term_put_tuple_element(t, 0, existing_atom(d->global, short_addr_atom));
        term_put_tuple_element(t, 1, term_from_int(short_addr));
        list = term_list_prepend(t, list, &heap);

        t = term_alloc_tuple(2, &heap);
        term_put_tuple_element(t, 0, existing_atom(d->global, pan_id_atom));
        term_put_tuple_element(t, 1, term_from_int(pan_id));
        list = term_list_prepend(t, list, &heap);

        term payload = term_alloc_tuple(2, &heap);
        term_put_tuple_element(payload, 0, existing_atom(d->global, joined_atom));
        term_put_tuple_element(payload, 1, list);
        send_event_tuple(payload, &heap);
    }
    END_WITH_STACK_HEAP(heap, d->global);
}

static void send_atom_int(const char *tag_atom, int value)
{
    struct ZigbeeData *d = zb_data;
    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(2) + TUPLE_SIZE(2), heap);
    {
        term payload = term_alloc_tuple(2, &heap);
        term_put_tuple_element(payload, 0, existing_atom(d->global, tag_atom));
        term_put_tuple_element(payload, 1, term_from_int(value));
        send_event_tuple(payload, &heap);
    }
    END_WITH_STACK_HEAP(heap, d->global);
}

static void send_bare_atom(const char *tag_atom)
{
    struct ZigbeeData *d = zb_data;
    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(2), heap);
    {
        send_event_tuple(existing_atom(d->global, tag_atom), &heap);
    }
    END_WITH_STACK_HEAP(heap, d->global);
}

static void send_signal(uint16_t signal_type, int status)
{
    struct ZigbeeData *d = zb_data;
    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(2) + TUPLE_SIZE(3), heap);
    {
        term payload = term_alloc_tuple(3, &heap);
        term_put_tuple_element(payload, 0, existing_atom(d->global, signal_atom));
        term_put_tuple_element(payload, 1, term_from_int(signal_type));
        term_put_tuple_element(payload, 2, term_from_int(status));
        send_event_tuple(payload, &heap);
    }
    END_WITH_STACK_HEAP(heap, d->global);
}

static void send_to_aps_receiver(term payload, Heap *heap)
{
    struct ZigbeeData *d = zb_data;
    int32_t pid = d->aps_process_id ? d->aps_process_id : d->owner_process_id;
    term msg = term_alloc_tuple(2, heap);
    term_put_tuple_element(msg, 0, existing_atom(d->global, zigbee_atom));
    term_put_tuple_element(msg, 1, payload);
    port_send_message_from_task(d->global, term_from_local_process_id(pid), msg);
}

/* APSDE-DATA.indication on the Zigbee task: {zigbee, {aps_data, SrcShort, Binary}} */
static bool aps_indication_handler(const ezb_apsde_data_ind_t *ind)
{
    if (ind->profile_id != ZIGBEAM_APS_PROFILE || ind->cluster_id != ZIGBEAM_APS_CLUSTER) {
        return false;
    }
    if (ind->status != 0 || ind->src_address.addr_mode != EZB_ADDR_MODE_SHORT) {
        return true;
    }
    struct ZigbeeData *d = zb_data;
    uint16_t len = ind->asdu_length;
    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(2) + TUPLE_SIZE(3) + TERM_BINARY_HEAP_SIZE(len), heap);
    {
        term payload = term_alloc_tuple(3, &heap);
        term_put_tuple_element(payload, 0, existing_atom(d->global, aps_data_atom));
        term_put_tuple_element(payload, 1, term_from_int(ind->src_address.u.short_addr));
        term_put_tuple_element(payload, 2, term_from_literal_binary(ind->asdu, len, &heap, d->global));
        send_to_aps_receiver(payload, &heap);
    }
    END_WITH_STACK_HEAP(heap, d->global);
    return true;
}

/* APSDE-DATA.confirm on the Zigbee task: {zigbee, {aps_confirm, DstShort, Status}} */
static void aps_confirm_handler(const ezb_apsde_data_confirm_t *confirm)
{
    if (confirm->profile_id != ZIGBEAM_APS_PROFILE || confirm->cluster_id != ZIGBEAM_APS_CLUSTER) {
        return;
    }
    struct ZigbeeData *d = zb_data;
    int dst = confirm->dst_address.addr_mode == EZB_ADDR_MODE_SHORT ? confirm->dst_address.u.short_addr : -1;
    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(2) + TUPLE_SIZE(3), heap);
    {
        term payload = term_alloc_tuple(3, &heap);
        term_put_tuple_element(payload, 0, existing_atom(d->global, aps_confirm_atom));
        term_put_tuple_element(payload, 1, term_from_int(dst));
        term_put_tuple_element(payload, 2, term_from_int(confirm->status));
        send_to_aps_receiver(payload, &heap);
    }
    END_WITH_STACK_HEAP(heap, d->global);
}

/* Decode a ZCL attribute value into an Erlang term: bool, integer or binary. */
static term attr_value_to_term(const ezb_zcl_attribute_t *attr, Heap *heap, GlobalContext *global)
{
    const uint8_t *p = (const uint8_t *) attr->data.value;
    uint8_t type = attr->data.type;
    uint16_t size = attr->data.size;

    if (type == EZB_ZCL_ATTR_TYPE_BOOL) {
        return p[0] ? TRUE_ATOM : FALSE_ATOM;
    }
    bool is_signed = (type >= EZB_ZCL_ATTR_TYPE_INT8 && type <= EZB_ZCL_ATTR_TYPE_INT64);
    bool is_unsigned = (type >= EZB_ZCL_ATTR_TYPE_UINT8 && type <= EZB_ZCL_ATTR_TYPE_UINT64)
        || (type >= EZB_ZCL_ATTR_TYPE_MAP8 && type <= EZB_ZCL_ATTR_TYPE_MAP64)
        || type == EZB_ZCL_ATTR_TYPE_ENUM8 || type == EZB_ZCL_ATTR_TYPE_ENUM16;
    if ((is_signed || is_unsigned) && size >= 1 && size <= 8) {
        uint64_t u = 0;
        for (int i = size - 1; i >= 0; i--) {
            u = (u << 8) | p[i];
        }
        int64_t v;
        if (is_signed && size < 8 && (p[size - 1] & 0x80)) {
            v = (int64_t) (u | (~0ULL << (size * 8)));
        } else {
            v = (int64_t) u;
        }
        return term_make_maybe_boxed_int64(v, heap);
    }
    return term_from_literal_binary(p, size, heap, global);
}

static void send_attribute(const ezb_zcl_set_attr_value_message_t *msg)
{
    struct ZigbeeData *d = zb_data;
    uint16_t size = msg->in.attribute.data.size;
    /* {zigbee, {attribute, Ep, Cluster, Attr, Value}} */
    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(2) + TUPLE_SIZE(5) + BOXED_INT64_SIZE + TERM_BINARY_HEAP_SIZE(size), heap);
    {
        term payload = term_alloc_tuple(5, &heap);
        term_put_tuple_element(payload, 0, existing_atom(d->global, attribute_atom));
        term_put_tuple_element(payload, 1, term_from_int(msg->info.dst_ep));
        term_put_tuple_element(payload, 2, term_from_int(msg->info.cluster_id));
        term_put_tuple_element(payload, 3, term_from_int(msg->in.attribute.id));
        term_put_tuple_element(payload, 4, attr_value_to_term(&msg->in.attribute, &heap, d->global));
        send_event_tuple(payload, &heap);
    }
    END_WITH_STACK_HEAP(heap, d->global);
}

/* ------------------------------------------------------------------------ */
/* Zigbee stack callbacks (run on the Zigbee task)                           */
/* ------------------------------------------------------------------------ */

static void steering_retry_cb(void *ctx)
{
    (void) ctx;
    ezb_bdb_start_top_level_commissioning(EZB_BDB_MODE_NETWORK_STEERING);
}

static void steering_retry_timer_cb(void *arg)
{
    (void) arg;
    /* esp_timer task -> hop onto the Zigbee task, where stack APIs are safe */
    esp_zigbee_task_queue_post(steering_retry_cb, NULL);
}

static void schedule_steering_retry(uint32_t delay_ms)
{
    static esp_timer_handle_t timer = NULL;
    if (timer == NULL) {
        const esp_timer_create_args_t args = {
            .callback = steering_retry_timer_cb,
            .name = "zb_steer_retry",
        };
        if (esp_timer_create(&args, &timer) != ESP_OK) {
            return;
        }
    }
    esp_timer_stop(timer);
    esp_timer_start_once(timer, (uint64_t) delay_ms * 1000);
}

static bool app_signal_handler(const ezb_app_signal_t *app_signal)
{
    ezb_app_signal_type_t type = ezb_app_signal_get_type(app_signal);

    switch (type) {
        case EZB_ZDO_SIGNAL_SKIP_STARTUP:
            ESP_LOGI(TAG, "stack init");
            ezb_bdb_start_top_level_commissioning(EZB_BDB_MODE_INITIALIZATION);
            break;

        case EZB_BDB_SIGNAL_DEVICE_FIRST_START:
        case EZB_BDB_SIGNAL_DEVICE_REBOOT: {
            ezb_bdb_comm_status_t status = *((const ezb_bdb_comm_status_t *) ezb_app_signal_get_params(app_signal));
            if (status == EZB_BDB_STATUS_SUCCESS) {
                bool factory_new = ezb_bdb_is_factory_new();
                ESP_LOGI(TAG, "device started, factory_new=%d", factory_new);
                if (factory_new) {
                    if (zb_data->auto_join) {
                        ezb_bdb_start_top_level_commissioning(EZB_BDB_MODE_NETWORK_STEERING);
                    }
                } else {
                    /* rejoined the network we already knew */
                    send_joined();
                }
            } else {
                ESP_LOGW(TAG, "%s failed (0x%02x)", ezb_app_signal_to_string(type), status);
                send_signal(type, status);
            }
        } break;

        case EZB_BDB_SIGNAL_STEERING: {
            ezb_bdb_comm_status_t status = *((const ezb_bdb_comm_status_t *) ezb_app_signal_get_params(app_signal));
            if (status == EZB_BDB_STATUS_SUCCESS) {
                ESP_LOGI(TAG, "joined pan 0x%04x ch %d addr 0x%04x", ezb_nwk_get_panid(),
                    ezb_nwk_get_current_channel(), ezb_nwk_get_short_address());
                send_joined();
            } else {
                ESP_LOGW(TAG, "steering failed (0x%02x)", status);
                send_atom_int(steering_failed_atom, status);
                if (zb_data->auto_join) {
                    /* keep trying; Erlang side can also call join explicitly */
                    schedule_steering_retry(5000);
                }
            }
        } break;

        case EZB_ZDO_SIGNAL_LEAVE:
            ESP_LOGI(TAG, "left network");
            send_bare_atom(left_atom);
            break;

        default:
            ESP_LOGD(TAG, "signal %s (0x%04x)", ezb_app_signal_to_string(type), type);
            send_signal(type, 0);
            break;
    }
    return true;
}

static void zcl_action_handler(ezb_zcl_core_action_callback_id_t callback_id, void *message)
{
    switch (callback_id) {
        case EZB_ZCL_CORE_SET_ATTR_VALUE_CB_ID: {
            ezb_zcl_set_attr_value_message_t *msg = (ezb_zcl_set_attr_value_message_t *) message;
            if (msg->info.status == EZB_ZCL_STATUS_SUCCESS) {
                send_attribute(msg);
            }
            msg->out.result = EZB_ZCL_STATUS_SUCCESS;
        } break;
        default:
            ESP_LOGD(TAG, "zcl action 0x%04lx", (unsigned long) callback_id);
            break;
    }
}

static esp_err_t create_device(struct ZigbeeData *d)
{
    ezb_af_device_desc_t dev_desc = ezb_af_create_device_desc();
    ezb_zha_on_off_light_config_t light_cfg = EZB_ZHA_ON_OFF_LIGHT_CONFIG();
    ezb_af_ep_desc_t ep_desc = ezb_zha_create_on_off_light(d->endpoint, &light_cfg);

    ezb_zcl_cluster_desc_t basic = ezb_af_endpoint_get_cluster_desc(ep_desc, EZB_ZCL_CLUSTER_ID_BASIC, EZB_ZCL_CLUSTER_SERVER);
    if (d->manufacturer[0]) {
        ezb_zcl_basic_cluster_desc_add_attr(basic, EZB_ZCL_ATTR_BASIC_MANUFACTURER_NAME_ID, d->manufacturer);
    }
    if (d->model[0]) {
        ezb_zcl_basic_cluster_desc_add_attr(basic, EZB_ZCL_ATTR_BASIC_MODEL_IDENTIFIER_ID, d->model);
    }

    esp_err_t err = ezb_af_device_add_endpoint_desc(dev_desc, ep_desc);
    if (err != ESP_OK) {
        return err;
    }
    err = ezb_af_device_desc_register(dev_desc);
    if (err != ESP_OK) {
        return err;
    }
    ezb_zcl_core_action_handler_register(zcl_action_handler);
    ezb_apsde_data_indication_handler_register(aps_indication_handler);
    ezb_apsde_data_confirm_handler_register(aps_confirm_handler);
    return ESP_OK;
}

static void zigbee_task(void *arg)
{
    struct ZigbeeData *d = (struct ZigbeeData *) arg;

    esp_zigbee_config_t config = {
        .device_config = {
            .device_type = EZB_NWK_DEVICE_TYPE_END_DEVICE,
            .install_code_policy = false,
            .zed_config = {
                .ed_timeout = EZB_NWK_ED_TIMEOUT_64MIN,
                .keep_alive = 250, /* poll the parent often: frames for us wait there until we poll */
            },
        },
        .platform_config = {
            .storage_partition_name = ZB_STORAGE_PARTITION,
            .radio_config = {
                .radio_mode = ESP_ZIGBEE_RADIO_MODE_NATIVE,
            },
        },
    };

    ESP_ERROR_CHECK(esp_zigbee_init(&config));
    /* Keep the receiver on: frames for us are delivered as they arrive instead
     * of waiting at the parent for our next poll, which matters for the
     * distribution link (latency per frame ~ms instead of ~keep_alive). */
    ezb_set_rx_on_when_idle(true);
    ezb_aps_secur_enable_distributed_security(false);
    ESP_ERROR_CHECK(ezb_bdb_set_primary_channel_set(d->channel_mask));
    ESP_ERROR_CHECK(ezb_bdb_set_secondary_channel_set(ZB_ALL_CHANNELS_MASK));
    ESP_ERROR_CHECK(ezb_app_signal_add_handler(app_signal_handler));
    ESP_ERROR_CHECK(create_device(d));
    ESP_ERROR_CHECK(esp_zigbee_start(false));
    esp_zigbee_launch_mainloop();
    esp_zigbee_deinit();
    vTaskDelete(NULL);
}

/* ------------------------------------------------------------------------ */
/* port commands (run on the AtomVM scheduler)                               */
/* ------------------------------------------------------------------------ */

static term do_start(Context *ctx, int32_t caller_pid, term req)
{
    struct ZigbeeData *d = ctx->platform_data;
    if (d->started) {
        return error_atom_tuple(ctx, already_started_atom);
    }

    term opts = term_get_tuple_arity(req) >= 2 ? term_get_tuple_element(req, 1) : term_nil();
    GlobalContext *global = ctx->global;

    d->owner_process_id = caller_pid;
    d->endpoint = 10;
    d->channel_mask = ZB_ALL_CHANNELS_MASK;
    d->auto_join = true;
    strcpy(d->manufacturer, "\x7" "zigbeam");
    strcpy(d->model, "\x8" "esp32-c6");

    term v = interop_kv_get_value(opts, ATOM_STR("\x8", "endpoint"), global);
    if (term_is_integer(v)) {
        d->endpoint = (uint8_t) term_to_int(v);
    }
    v = interop_kv_get_value(opts, ATOM_STR("\xC", "channel_mask"), global);
    if (term_is_any_integer(v)) {
        d->channel_mask = (uint32_t) term_maybe_unbox_int64(v) & ZB_ALL_CHANNELS_MASK;
    }
    v = interop_kv_get_value(opts, ATOM_STR("\x9", "auto_join"), global);
    if (v == FALSE_ATOM) {
        d->auto_join = false;
    }
    v = interop_kv_get_value(opts, ATOM_STR("\xC", "manufacturer"), global);
    if (!term_is_invalid_term(v)) {
        term_to_zcl_string(v, d->manufacturer, global);
    }
    v = interop_kv_get_value(opts, ATOM_STR("\x5", "model"), global);
    if (!term_is_invalid_term(v)) {
        term_to_zcl_string(v, d->model, global);
    }

    /* Seeed XIAO ESP32-C6 RF switch: GPIO3 low enables the switch, GPIO14
     * selects the antenna (low = onboard ceramic, high = external U.FL).
     * Both float after reset; on some boards that leaves the radio deaf
     * (steering fails with NO_NETWORK), so drive them explicitly. */
    gpio_reset_pin(GPIO_NUM_3);
    gpio_set_direction(GPIO_NUM_3, GPIO_MODE_OUTPUT);
    gpio_set_level(GPIO_NUM_3, 0);
    gpio_reset_pin(GPIO_NUM_14);
    gpio_set_direction(GPIO_NUM_14, GPIO_MODE_OUTPUT);
    gpio_set_level(GPIO_NUM_14, 0);

    esp_err_t err = nvs_flash_init_partition(ZB_STORAGE_PARTITION);
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase_partition(ZB_STORAGE_PARTITION));
        err = nvs_flash_init_partition(ZB_STORAGE_PARTITION);
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs init of %s failed: %s", ZB_STORAGE_PARTITION, esp_err_to_name(err));
        return error_tuple(ctx, term_from_int(err));
    }

#if CONFIG_ESP_COEX_SW_COEXIST_ENABLE
    /* Share the single 2.4GHz radio between Wi-Fi STA and 802.15.4. Only
     * relevant when the app brought Wi-Fi up (the serial transports don't). */
    wifi_mode_t wifi_mode;
    if (esp_wifi_get_mode(&wifi_mode) == ESP_OK) {
        esp_coex_wifi_i154_enable();
        esp_wifi_set_ps(WIFI_PS_MIN_MODEM);
    }
#endif

    if (xTaskCreate(zigbee_task, "zigbee_main", ZB_TASK_STACK, d, ZB_TASK_PRIO, NULL) != pdPASS) {
        return error_tuple(ctx, OUT_OF_MEMORY_ATOM);
    }
    d->started = true;
    return OK_ATOM;
}

/*
 * Commands that touch the running stack are executed on the Zigbee task via
 * esp_zigbee_task_queue_post (no lock needed there) and reply to the caller
 * from that task, so the AtomVM scheduler never blocks on the Zigbee lock.
 */
struct PendingCmd
{
    enum zigbee_cmd cmd;
    int32_t caller_pid;
    uint64_t ref_ticks;
    uint16_t cluster_id;
    uint16_t attr_id;
    uint8_t value[8];
    /* aps_send */
    uint16_t dst_short;
    uint16_t data_len;
    uint8_t *data;
};

static term kv_heap(Heap *heap, GlobalContext *global, const char *key_atom, term value, term tail)
{
    term t = term_alloc_tuple(2, heap);
    term_put_tuple_element(t, 0, existing_atom(global, key_atom));
    term_put_tuple_element(t, 1, value);
    return term_list_prepend(t, tail, heap);
}

static void reply_from_task(struct PendingCmd *pc, size_t payload_size, term (*build)(struct PendingCmd *, Heap *))
{
    struct ZigbeeData *d = zb_data;
    BEGIN_WITH_STACK_HEAP(PORT_REPLY_SIZE + payload_size, heap);
    {
        term payload = build(pc, &heap);
        term ref = term_from_ref_ticks(pc->ref_ticks, &heap);
        term msg = term_alloc_tuple(2, &heap);
        term_put_tuple_element(msg, 0, ref);
        term_put_tuple_element(msg, 1, payload);
        port_send_message_from_task(d->global, term_from_local_process_id(pc->caller_pid), msg);
    }
    END_WITH_STACK_HEAP(heap, d->global);
}

static term build_ok(struct PendingCmd *pc, Heap *heap)
{
    (void) pc;
    (void) heap;
    return OK_ATOM;
}

static int pending_error_code = 0;
static const char *pending_error_tag = NULL;

static term build_error(struct PendingCmd *pc, Heap *heap)
{
    (void) pc;
    GlobalContext *global = zb_data->global;
    term reason = term_alloc_tuple(2, heap);
    term_put_tuple_element(reason, 0, existing_atom(global, pending_error_tag));
    term_put_tuple_element(reason, 1, term_from_int(pending_error_code));
    term err = term_alloc_tuple(2, heap);
    term_put_tuple_element(err, 0, ERROR_ATOM);
    term_put_tuple_element(err, 1, reason);
    return err;
}

static term build_status(struct PendingCmd *pc, Heap *heap)
{
    (void) pc;
    struct ZigbeeData *d = zb_data;
    GlobalContext *g = d->global;
    ezb_extpanid_t ext_pan_id;
    ezb_nwk_get_extended_panid(&ext_pan_id);
    ezb_extaddr_t ieee;
    ezb_nwk_get_extended_address(&ieee);

    term list = term_nil();
    list = kv_heap(heap, g, ieee_addr_atom, term_from_literal_binary(&ieee, 8, heap, g), list);
    list = kv_heap(heap, g, ext_pan_id_atom, term_from_literal_binary(&ext_pan_id, 8, heap, g), list);
    list = kv_heap(heap, g, channel_atom, term_from_int(ezb_nwk_get_current_channel()), list);
    list = kv_heap(heap, g, short_addr_atom, term_from_int(ezb_nwk_get_short_address()), list);
    list = kv_heap(heap, g, pan_id_atom, term_from_int(ezb_nwk_get_panid()), list);
    list = kv_heap(heap, g, endpoint_atom, term_from_int(d->endpoint), list);
    list = kv_heap(heap, g, factory_new_atom, ezb_bdb_is_factory_new() ? TRUE_ATOM : FALSE_ATOM, list);
    list = kv_heap(heap, g, joined_atom, ezb_bdb_dev_joined() ? TRUE_ATOM : FALSE_ATOM, list);
    list = kv_heap(heap, g, started_atom, TRUE_ATOM, list);
    return list;
}

#define STATUS_PAYLOAD_SIZE (LIST_SIZE(9, TUPLE_SIZE(2)) + 2 * TERM_BINARY_HEAP_SIZE(8))
#define ERROR_PAYLOAD_SIZE (TUPLE_SIZE(2) + TUPLE_SIZE(2))

/* Runs on the Zigbee task. */
static void run_pending_cmd(void *arg)
{
    struct PendingCmd *pc = (struct PendingCmd *) arg;
    struct ZigbeeData *d = zb_data;

    switch (pc->cmd) {
        case ZigbeeStatusCmd:
            reply_from_task(pc, STATUS_PAYLOAD_SIZE, build_status);
            break;

        case ZigbeeJoinCmd: {
            ezb_err_t err = ezb_bdb_start_top_level_commissioning(EZB_BDB_MODE_NETWORK_STEERING);
            if (err == EZB_ERR_NONE) {
                reply_from_task(pc, 0, build_ok);
            } else {
                pending_error_tag = zb_error_atom;
                pending_error_code = err;
                reply_from_task(pc, ERROR_PAYLOAD_SIZE, build_error);
            }
        } break;

        case ZigbeeLeaveCmd:
            ezb_bdb_reset_via_local_action();
            reply_from_task(pc, 0, build_ok);
            break;

        case ZigbeeFactoryResetCmd:
            reply_from_task(pc, 0, build_ok);
            vTaskDelay(pdMS_TO_TICKS(200)); /* let the reply go out before the chip restarts */
            esp_zigbee_factory_reset();
            break;

        case ZigbeeSetAttributeCmd: {
            ezb_zcl_status_t st = ezb_zcl_set_attr_value(d->endpoint, pc->cluster_id, EZB_ZCL_CLUSTER_SERVER,
                pc->attr_id, EZB_ZCL_STD_MANUF_CODE, pc->value, false);
            if (st != EZB_ZCL_STATUS_SUCCESS) {
                pending_error_tag = zcl_error_atom;
                pending_error_code = st;
                reply_from_task(pc, ERROR_PAYLOAD_SIZE, build_error);
                break;
            }
            ezb_zcl_report_attr_cmd_t report = {
                .cmd_ctrl = {
                    .fc.direction = EZB_ZCL_CMD_DIRECTION_TO_CLI,
                    .dst_addr.addr_mode = EZB_ADDR_MODE_NONE,
                    .src_ep = d->endpoint,
                    .cluster_id = pc->cluster_id,
                },
                .payload = { .attr_id = pc->attr_id },
            };
            ezb_err_t rep = ezb_zcl_report_attr_cmd_req(&report);
            if (rep != EZB_ERR_NONE) {
                /* value is set locally; reporting failed (e.g. no binding yet) */
                ESP_LOGW(TAG, "report of 0x%04x/0x%04x failed (0x%04x)", pc->cluster_id, pc->attr_id, rep);
            }
            reply_from_task(pc, 0, build_ok);
        } break;

        case ZigbeeApsSendCmd: {
            ezb_apsde_data_req_t req;
            memset(&req, 0, sizeof(req));
            req.dst_address.addr_mode = EZB_ADDR_MODE_SHORT;
            req.dst_address.u.short_addr = pc->dst_short;
            req.src_endpoint = d->endpoint;
            req.dst_endpoint = d->endpoint;
            req.cluster_id = ZIGBEAM_APS_CLUSTER;
            req.profile_id = ZIGBEAM_APS_PROFILE;
            req.radius = 0;
            req.tx_options = (pc->dst_short >= 0xFFF8) ? 0 : (EZB_APSDE_TX_OPT_ACK_TX | EZB_APSDE_TX_OPT_FRAG_PERMITTED);
            req.asdu_length = pc->data_len;
            req.asdu = pc->data;
            ezb_err_t err = ezb_apsde_data_request(&req);
            if (err == EZB_ERR_NONE) {
                reply_from_task(pc, 0, build_ok);
            } else {
                pending_error_tag = zb_error_atom;
                pending_error_code = err;
                reply_from_task(pc, ERROR_PAYLOAD_SIZE, build_error);
            }
        } break;

        default:
            break;
    }
    free(pc->data);
    free(pc);
}

/* Runs on the AtomVM scheduler: validate, then hand off to the Zigbee task.
 * Returns term_invalid_term() when the reply will come from the task. */
static term dispatch_to_task(Context *ctx, enum zigbee_cmd cmd, GenMessage *gen_message)
{
    struct ZigbeeData *d = ctx->platform_data;
    if (!d->started) {
        if (cmd == ZigbeeStatusCmd) {
            port_ensure_available(ctx, LIST_SIZE(1, TUPLE_SIZE(2)));
            return kv_heap(&ctx->heap, ctx->global, started_atom, FALSE_ATOM, term_nil());
        }
        if (cmd == ZigbeeFactoryResetCmd) {
            nvs_flash_erase_partition(ZB_STORAGE_PARTITION);
            return OK_ATOM;
        }
        return error_atom_tuple(ctx, not_started_atom);
    }

    struct PendingCmd *pc = calloc(1, sizeof(struct PendingCmd));
    if (IS_NULL_PTR(pc)) {
        return error_tuple(ctx, OUT_OF_MEMORY_ATOM);
    }
    pc->cmd = cmd;
    pc->caller_pid = term_to_local_process_id(gen_message->pid);
    pc->ref_ticks = term_to_ref_ticks(gen_message->ref);

    if (cmd == ZigbeeSetAttributeCmd) {
        term req = gen_message->req;
        if (term_get_tuple_arity(req) != 4) {
            free(pc);
            return error_tuple(ctx, BADARG_ATOM);
        }
        term cluster_t = term_get_tuple_element(req, 1);
        term attr_t = term_get_tuple_element(req, 2);
        term value_t = term_get_tuple_element(req, 3);
        if (!term_is_integer(cluster_t) || !term_is_integer(attr_t)) {
            free(pc);
            return error_tuple(ctx, BADARG_ATOM);
        }
        pc->cluster_id = (uint16_t) term_to_int(cluster_t);
        pc->attr_id = (uint16_t) term_to_int(attr_t);
        /* Little-endian buffer: the stack copies as many bytes as the attribute's
         * declared type needs, so one 8-byte buffer serves bool/u8/u16/s16/u32... */
        if (value_t == TRUE_ATOM) {
            pc->value[0] = 1;
        } else if (value_t == FALSE_ATOM) {
            pc->value[0] = 0;
        } else if (term_is_any_integer(value_t)) {
            int64_t v = term_maybe_unbox_int64(value_t);
            memcpy(pc->value, &v, sizeof(v));
        } else {
            free(pc);
            return error_tuple(ctx, BADARG_ATOM);
        }
    }

    if (cmd == ZigbeeApsSendCmd) {
        term req = gen_message->req;
        if (term_get_tuple_arity(req) != 3) {
            free(pc);
            return error_tuple(ctx, BADARG_ATOM);
        }
        term dst_t = term_get_tuple_element(req, 1);
        term data_t = term_get_tuple_element(req, 2);
        if (!term_is_integer(dst_t) || !term_is_binary(data_t)
            || term_binary_size(data_t) > ZIGBEAM_APS_MAX_ASDU) {
            free(pc);
            return error_tuple(ctx, BADARG_ATOM);
        }
        pc->dst_short = (uint16_t) term_to_int(dst_t);
        pc->data_len = (uint16_t) term_binary_size(data_t);
        pc->data = malloc(pc->data_len ? pc->data_len : 1);
        if (IS_NULL_PTR(pc->data)) {
            free(pc);
            return error_tuple(ctx, OUT_OF_MEMORY_ATOM);
        }
        memcpy(pc->data, term_binary_data(data_t), pc->data_len);
    }

    if (esp_zigbee_task_queue_post(run_pending_cmd, pc) != ESP_OK) {
        free(pc->data);
        free(pc);
        return error_atom_tuple(ctx, zb_error_atom);
    }
    return term_invalid_term();
}

static NativeHandlerResult consume_zigbee_mailbox(Context *ctx)
{
    Message *message = mailbox_first(&ctx->mailbox);
    GenMessage gen_message;
    if (UNLIKELY(port_parse_gen_message(message->message, &gen_message) != GenCallMessage)) {
        ESP_LOGW(TAG, "Received invalid message.");
        mailbox_remove_message(&ctx->mailbox, &ctx->heap);
        return NativeContinue;
    }

    term req = gen_message.req;
    term cmd_term = term_is_tuple(req) ? term_get_tuple_element(req, 0) : req;
    int local_process_id = term_to_local_process_id(gen_message.pid);
    enum zigbee_cmd cmd = interop_atom_term_select_int(cmd_table, cmd_term, ctx->global);

    term ret;
    switch (cmd) {
        case ZigbeeStartCmd:
            ret = do_start(ctx, local_process_id, req);
            break;
        case ZigbeeStatusCmd:
        case ZigbeeJoinCmd:
        case ZigbeeLeaveCmd:
        case ZigbeeFactoryResetCmd:
        case ZigbeeSetAttributeCmd:
        case ZigbeeApsSendCmd:
            ret = dispatch_to_task(ctx, cmd, &gen_message);
            break;
        case ZigbeeApsSubscribeCmd: {
            /* {aps_subscribe, Pid}: route APS data/confirm events to Pid */
            struct ZigbeeData *d = ctx->platform_data;
            term pid_t = term_is_tuple(req) && term_get_tuple_arity(req) == 2
                ? term_get_tuple_element(req, 1) : term_invalid_term();
            if (term_is_pid(pid_t)) {
                d->aps_process_id = term_to_local_process_id(pid_t);
                ret = OK_ATOM;
            } else {
                ret = error_tuple(ctx, BADARG_ATOM);
            }
        } break;
        case ZigbeeCloseCmd:
            ret = OK_ATOM;
            break;
        default:
            ESP_LOGW(TAG, "Unrecognized command");
            ret = error_tuple(ctx, BADARG_ATOM);
    }

    if (!term_is_invalid_term(ret)) {
        term ret_msg;
        if (UNLIKELY(memory_ensure_free_with_roots(ctx, TUPLE_SIZE(2), 1, &ret, MEMORY_CAN_SHRINK) != MEMORY_GC_OK)) {
            ret_msg = OUT_OF_MEMORY_ATOM;
        } else {
            ret_msg = port_create_tuple2(ctx, gen_message.ref, ret);
        }
        globalcontext_send_message(ctx->global, local_process_id, ret_msg);
    }
    mailbox_remove_message(&ctx->mailbox, &ctx->heap);

    if (cmd == ZigbeeCloseCmd) {
        /* The stack keeps running; we only drop the registered name. */
        globalcontext_unregister_process(ctx->global, term_to_atom_index(make_atom(ctx->global, zigbee_atom)));
        return NativeTerminate;
    }
    return NativeContinue;
}

/* ------------------------------------------------------------------------ */
/* driver registration                                                       */
/* ------------------------------------------------------------------------ */

static void zigbee_driver_init(GlobalContext *global)
{
    ensure_atoms(global);
}

static Context *zigbee_driver_create_port(GlobalContext *global, term opts)
{
    (void) opts;
    Context *ctx = context_new(global);

    if (zb_data == NULL) {
        zb_data = calloc(1, sizeof(struct ZigbeeData));
        if (IS_NULL_PTR(zb_data)) {
            ESP_LOGE(TAG, "Not enough free memory to initialize zigbee port driver!");
            scheduler_terminate(ctx);
            return NULL;
        }
        zb_data->global = global;
    }

    ctx->native_handler = consume_zigbee_mailbox;
    ctx->platform_data = zb_data;

    term reg_name_term = make_atom(global, zigbee_atom);
    atom_index_t atom_index = term_to_atom_index(reg_name_term);
    term local_port_id = term_port_from_local_process_id(ctx->process_id);
    if (UNLIKELY(!globalcontext_register_process(global, atom_index, local_port_id))) {
        scheduler_terminate(ctx);
        ESP_LOGE(TAG, "Only a single zigbee port can be open.");
        return NULL;
    }
    return ctx;
}

REGISTER_PORT_DRIVER(zigbee, zigbee_driver_init, NULL, zigbee_driver_create_port)

#endif /* CONFIG_AVM_ENABLE_ZIGBEE_PORT_DRIVER && CONFIG_ZB_ENABLED */
