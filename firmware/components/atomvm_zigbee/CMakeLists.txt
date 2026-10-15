# AtomVM port driver wrapping espressif/esp-zigbee-lib (v2 API).
idf_component_register(
    SRCS "zigbee_driver.c"
    PRIV_REQUIRES "libatomvm" "avm_sys" "nvs_flash" "esp_coex" "esp_wifi" "esp_timer" "espressif__esp-zigbee-lib"
    WHOLE_ARCHIVE
)
target_compile_features(${COMPONENT_LIB} INTERFACE c_std_11)
