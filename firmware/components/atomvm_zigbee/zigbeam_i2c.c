/* Bit-banged I2C master NIF (write-only) for the zigbeam firmware.
 *
 * ESP-IDF's I2C drivers need a CPU interrupt slot and i2c_driver_install
 * fails with ESP_FAIL once the Zigbee stack is running on the ESP32-C6, so
 * the OLED on the XIAO expansion board is driven with GPIO toggling instead.
 *
 *   zigbeam_i2c:write(Sda, Scl, Addr, Data :: binary()) -> ok | {error, nack}
 */
#include <sdkconfig.h>
#include <string.h>

#include <driver/gpio.h>
#include <esp_rom_sys.h>

#include <context.h>
#include <defaultatoms.h>
#include <globalcontext.h>
#include <memory.h>
#include <nifs.h>
#include <portnifloader.h>
#include <term.h>

#define HALF_PERIOD_US 2

static inline void sw_delay(void)
{
    esp_rom_delay_us(HALF_PERIOD_US);
}

static void pin_setup(gpio_num_t pin)
{
    gpio_reset_pin(pin);
    gpio_set_direction(pin, GPIO_MODE_INPUT_OUTPUT_OD);
    gpio_pullup_en(pin);
    gpio_set_level(pin, 1);
}

static inline void sda_set(gpio_num_t sda, int level)
{
    gpio_set_level(sda, level);
}

static inline void scl_set(gpio_num_t scl, int level)
{
    gpio_set_level(scl, level);
}

static void i2c_start(gpio_num_t sda, gpio_num_t scl)
{
    sda_set(sda, 1);
    scl_set(scl, 1);
    sw_delay();
    sda_set(sda, 0);
    sw_delay();
    scl_set(scl, 0);
    sw_delay();
}

static void i2c_stop(gpio_num_t sda, gpio_num_t scl)
{
    sda_set(sda, 0);
    sw_delay();
    scl_set(scl, 1);
    sw_delay();
    sda_set(sda, 1);
    sw_delay();
}

/* returns 1 on ACK */
static int i2c_write_byte(gpio_num_t sda, gpio_num_t scl, uint8_t byte)
{
    for (int i = 7; i >= 0; i--) {
        sda_set(sda, (byte >> i) & 1);
        sw_delay();
        scl_set(scl, 1);
        sw_delay();
        scl_set(scl, 0);
    }
    sda_set(sda, 1); /* release for ACK */
    sw_delay();
    scl_set(scl, 1);
    sw_delay();
    int ack = gpio_get_level(sda) == 0;
    scl_set(scl, 0);
    sw_delay();
    return ack;
}

static term nif_write(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    if (UNLIKELY(!term_is_integer(argv[0]) || !term_is_integer(argv[1]) || !term_is_integer(argv[2])
            || !term_is_binary(argv[3]))) {
        RAISE_ERROR(BADARG_ATOM);
    }
    gpio_num_t sda = (gpio_num_t) term_to_int32(argv[0]);
    gpio_num_t scl = (gpio_num_t) term_to_int32(argv[1]);
    uint8_t addr = (uint8_t) term_to_int32(argv[2]);
    const uint8_t *data = (const uint8_t *) term_binary_data(argv[3]);
    size_t len = term_binary_size(argv[3]);

    pin_setup(sda);
    pin_setup(scl);

    i2c_start(sda, scl);
    int ok = i2c_write_byte(sda, scl, (uint8_t) (addr << 1));
    for (size_t i = 0; ok && i < len; i++) {
        ok = i2c_write_byte(sda, scl, data[i]);
    }
    i2c_stop(sda, scl);

    if (!ok) {
        if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        term err = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(err, 0, ERROR_ATOM);
        term_put_tuple_element(err, 1, globalcontext_make_atom(ctx->global, ATOM_STR("\x4", "nack")));
        return err;
    }
    return OK_ATOM;
}

static const struct Nif write_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_write };

static const struct Nif *zigbeam_i2c_get_nif(const char *nifname)
{
    if (strcmp("zigbeam_i2c:write/4", nifname) == 0) {
        return &write_nif;
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(zigbeam_i2c, NULL, NULL, zigbeam_i2c_get_nif)
