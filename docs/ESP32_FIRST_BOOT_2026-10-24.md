# ESP32-S3 board bring-up — 24 October 2026

**Result: the board booted the `hello_world` application successfully with 16 MB flash configured.** The console reached `app_main()` and ran the example's programmed restart sequence.

## Final configuration

| Item | Observation |
|---|---|
| Target / silicon revision | ESP32-S3 / v0.2 |
| Framework | ESP-IDF 6.1 |
| CPU | Two cores; application running at 160 MHz |
| Console | UART0 on GPIO43 / GPIO44, 115200 baud |
| SPI configuration | DIO, 80 MHz |
| Flash configuration | 16 MB |
| Minimum free heap printed by the example | 400,308 bytes |

The initial image used a 2 MB flash setting while the chip was detected as 16 MB. Changing the image configuration to 16 MB and rebuilding removed the mismatch warning.

## Serial excerpt

```text
I (29) boot: compile time Oct 24 2026 18:30:20
I (43) boot.esp32s3: SPI Flash Size : 16MB
I (172) app_init: Compile time:     Oct 24 2026 18:30:06
I (181) app_init: ESP-IDF:          v6.1
I (243) main_task: Calling app_main()
Sameh Fannus
This is esp32s3 chip with 2 CPU core(s), WiFi/BLE, silicon revision v0.2, 16MB external flash
Minimum free heap size: 400308 bytes
```

The countdown ends with `Restarting now.` and `RTC_SW_CPU_RST`, matching the example's intentional `esp_restart()` call.

This component check preceded the completed [physical gateway test](HARDWARE_GATEWAY_VALIDATION_2026-10-25.md).
