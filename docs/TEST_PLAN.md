# Validation summary

**Status — 25 October 2026:** the physical Modbus RTU → ESP32-S3 → MQTT → dashboard path is working and has a recorded 60-second test. Software suites and a separate simulated host integration exercise cover additional receiver and outage behavior.

## Physical bench checks

| Check | Result | Record |
|---|---|---|
| ESP32-S3 boot and 16 MB flash configuration | Passed | [Board bring-up](ESP32_FIRST_BOOT_2026-10-24.md) |
| Wi-Fi association and DHCP | Passed | [Wi-Fi check](ESP32_WIFI_2026-10-24.md) |
| XY485 pair at 3.3 V / 9600 8N1 | 3/3 transfers in each direction | [RS485 fixture](RS485_LINK_DIAGNOSTICS_2026-10-25.md) |
| Standalone SHT20 reads | 10/10 valid replies; all response CRCs matched | [Sensor test](SHT20_PHYSICAL_VALIDATION_2026-10-25.md) |
| Unified ESP-IDF firmware build and deployment | Completed; build artifacts recorded | [Build metadata](evidence/2026-10-25/hardware-live-60s/build-artifact-metadata.json) |
| Physical sensor → MQTT → dashboard | 30 accepted GOOD readings in 60.010 s; 0 BAD / 0 rejected | [Hardware report](HARDWARE_GATEWAY_VALIDATION_2026-10-25.md) |
| Sensor disconnect/reconnect | Read errors appeared; readings resumed after reconnection | Manual functional check |
| Gateway Reset / USB power interruption | Automatic reconnection and resumed readings | Manual functional check |

The manual checks confirm recovery behavior without measuring recovery time. Detailed timing assumptions and test boundaries are consolidated in the hardware report.

## Software checks

| Suite | Result |
|---|---|
| Gateway protocol checks | 100,235 assertions passed |
| Gateway JSON payload scenarios | 4 passed |
| Dashboard receiver tests | 41 passed |
| Host-model unit tests | 5 passed |
| Hardware-capture tool unit tests | 5 passed |
| Standalone SHT20 probe tests | 15 passed |
| Bounded discovery tests | 44 passed |

The firmware protocol and payload results are in [the test record](../firmware/gateway/tests/VALIDATION_20261025.txt). Receiver coverage includes invalid and null values, zero/negative values, timestamps, source errors, stale ticks, duplicate and reordered samples, boot-session replay, retained availability, transport status and bounded history. Protocol and fixture tests use controlled inputs; the hardware row above identifies the live sensor test.

## Simulated host integration

A separate **600.009-second** run passed all 13 integration checks, including deliberate source and broker interruptions, valid zero/negative values, stale data and gateway restarts. A short rerun of the strengthened runner also passed all 13 checks. Timings are recorded in [the host report](HOST_VALIDATION_2026-10-19.md).

The host fixture uses synthetic Modbus TCP FC03 registers 0 and 1. The physical SHT20 uses the FC04 register profile above. Host media and payloads identify their source as simulated.

## Reproduce

Follow [setup](release/SETUP.md) for the hardware demo and [the capture guide](release/CAPTURE_AND_ACCEPTANCE.md) for the recorder and optional video. Use one Modbus master and one publisher for the gateway identity. Preserve firmware/tool versions, non-secret settings and raw results with each new test.
