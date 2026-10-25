idf_component_register(
    SRCS "app_main.c" "sensor.c" "sht20_protocol.c" "gateway_payload.c"
    INCLUDE_DIRS "."
    PRIV_REQUIRES esp_driver_uart esp_common freertos log soc esp_timer
                  esp_wifi esp_event esp_netif nvs_flash esp_system esp_hw_support mqtt
)
