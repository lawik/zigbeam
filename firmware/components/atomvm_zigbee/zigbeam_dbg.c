/* Debug NIFs for the zigbeam firmware: interrupt table dump and a direct
 * legacy-I2C install attempt, so failures can be read over distribution
 * when the console is not reachable. */
#include <sdkconfig.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <driver/i2c.h>
#include <esp_err.h>
#include <esp_intr_alloc.h>

#include <context.h>
#include <defaultatoms.h>
#include <globalcontext.h>
#include <memory.h>
#include <nifs.h>
#include <portnifloader.h>
#include <term.h>

static term make_binary(Context *ctx, const char *data, size_t len)
{
    if (UNLIKELY(memory_ensure_free(ctx, term_binary_heap_size(len)) != MEMORY_GC_OK)) {
        return OUT_OF_MEMORY_ATOM;
    }
    return term_from_literal_binary(data, len, &ctx->heap, ctx->global);
}

static term nif_intr_dump(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);
    char *buf = NULL;
    size_t len = 0;
    FILE *f = open_memstream(&buf, &len);
    if (f == NULL) {
        return ERROR_ATOM;
    }
    esp_intr_dump(f);
    fclose(f);
    term ret = make_binary(ctx, buf, len);
    free(buf);
    return ret;
}

/* zigbeam_dbg:i2c_try(Sda, Scl, Hz) -> binary describing each step */
static term nif_i2c_try(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    char out[160];
    i2c_config_t conf;
    memset(&conf, 0, sizeof(conf));
    conf.mode = I2C_MODE_MASTER;
    conf.sda_io_num = term_to_int32(argv[0]);
    conf.scl_io_num = term_to_int32(argv[1]);
    conf.sda_pullup_en = GPIO_PULLUP_ENABLE;
    conf.scl_pullup_en = GPIO_PULLUP_ENABLE;
    conf.master.clk_speed = term_to_int32(argv[2]);
    esp_err_t a = i2c_param_config(I2C_NUM_0, &conf);
    esp_err_t b = (a == ESP_OK) ? i2c_driver_install(I2C_NUM_0, I2C_MODE_MASTER, 0, 0, 0) : -999;
    esp_err_t c = (b == ESP_OK) ? i2c_driver_delete(I2C_NUM_0) : -999;
    int n = snprintf(out, sizeof(out), "param_config=%s install=%s delete=%s",
        esp_err_to_name(a), b == -999 ? "skipped" : esp_err_to_name(b), c == -999 ? "skipped" : esp_err_to_name(c));
    return make_binary(ctx, out, n);
}

static void dummy_isr(void *arg)
{
    (void) arg;
}

/* zigbeam_dbg:intr_try(Source, Flags) -> binary with the esp_err name */
static term nif_intr_try(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    intr_handle_t h = NULL;
    esp_err_t a = esp_intr_alloc(term_to_int32(argv[0]), term_to_int32(argv[1]), dummy_isr, NULL, &h);
    if (a == ESP_OK) {
        esp_intr_free(h);
    }
    const char *name = esp_err_to_name(a);
    return make_binary(ctx, name, strlen(name));
}

static const struct Nif intr_try_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_intr_try };
static const struct Nif intr_dump_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_intr_dump };
static const struct Nif i2c_try_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_i2c_try };

static const struct Nif *zigbeam_dbg_get_nif(const char *nifname)
{
    if (strcmp("zigbeam_dbg:intr_dump/0", nifname) == 0) {
        return &intr_dump_nif;
    }
    if (strcmp("zigbeam_dbg:intr_try/2", nifname) == 0) {
        return &intr_try_nif;
    }
    if (strcmp("zigbeam_dbg:i2c_try/3", nifname) == 0) {
        return &i2c_try_nif;
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(zigbeam_dbg, NULL, NULL, zigbeam_dbg_get_nif)
