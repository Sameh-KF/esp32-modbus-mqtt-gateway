# Hardware validation — 25 October 2026

**Result: the physical SHT20 → RS485 → ESP32-S3 → MQTT → Node-RED dashboard path passed a recorded 60-second run.** Manual checks also confirmed that readings resume after reconnecting the sensor and restarting the gateway.

## Recorded run

The gateway reads the sensor through one XY485 interface on UART1 and publishes over Wi-Fi to Mosquitto. Node-RED receives and displays the readings. The capture tool subscribed to MQTT and recorded the dashboard state without publishing test data. USB supplied ESP32 power and the programming/console connection; a USB-to-RS485 adapter is not required in the operating data path.

| Observation | Result |
|---|---|
| Capture interval | 2026-10-25 13:26:38.527–13:27:38.537 UTC; 60.010 seconds |
| Received MQTT messages | 33: 30 telemetry, 1 availability, 2 diagnostics |
| Accepted hardware telemetry | **30 GOOD; 0 BAD; 0 rejected** |
| Session / sequence | `e2d3a5f015ebebed67dd5b46f1e3d55b`; 509–538 |
| First reading | 25.7 °C / 55.9 %RH |
| Last reading | 25.7 °C / 55.8 %RH |
| Dashboard state | Hardware; connected; online; healthy; fresh |
| Capture errors | None |

## Manual functional checks

| Check | Result |
|---|---|
| Disconnect and reconnect the sensor | Read errors appeared during the deliberate interruption; valid readings resumed after reconnection |
| Reset the ESP32 or disconnect and reconnect its USB supply | MQTT reconnected automatically and sensor readings resumed |

These were bench observations, separate from the recorded normal run. Recovery duration and the broker's offline Last Will transition were not timed or recorded. The 37 earlier cumulative read errors visible in the dashboard belong to deliberate sensor-disconnection checks, not the 60-second run above.

## Test records

- [MQTT summary](evidence/2026-10-25/hardware-live-60s/summary.json)
- [Received MQTT messages](evidence/2026-10-25/hardware-live-60s/messages.jsonl)
- [Dashboard state](evidence/2026-10-25/hardware-live-60s/dashboard-state.json)
- [Build metadata](evidence/2026-10-25/hardware-live-60s/build-artifact-metadata.json)
- [Hardware dashboard screenshot](images/hardware-dashboard-2026-10-25.png)
- [Bench photograph](images/hardware-bench-2026-10-25.png)
- [Standalone SHT20 read test](SHT20_PHYSICAL_VALIDATION_2026-10-25.md)

## Firmware and configuration

The tested application is `industrial_gateway`, target `esp32s3`, built with ESP-IDF 6.1. The local application binary is 949,408 bytes and the ELF is 10,054,848 bytes. The factory application partition is 2 MiB at `0x10000`; flash is configured for 16 MB. Artifact hashes are recorded in the build metadata. Compiled binaries and local `sdkconfig` are excluded from the source release because they can contain network credentials.

The MQTT boot ID identifies the running session. It is separate from the build artifact hash; a unified serial boot transcript was not archived to match the running image against that hash.

## Test scope

This record covers one bench prototype, one sensor and a short normal run, plus the manual functional checks above. The captured effective sample ages were 22.9–117.5 ms, mean 78.1 ms, calculated from PC UTC and publisher-reported age. Publisher time uses SNTP; no independent clock-offset measurement was made, so these figures are not a calibrated latency benchmark.

Timed broker/Wi-Fi outage recovery, offline Last Will behavior, extended operation, sensor calibration, full flash/PSRAM testing and electrical/EMI qualification are outside this test record. The source and boot fields identify telemetry within the lab protocol; they are not cryptographic attestation. Earlier host-fixture results remain explicitly simulated.
