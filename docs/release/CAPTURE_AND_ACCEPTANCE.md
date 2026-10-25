# Hardware acceptance and presentation guide

The physical gateway was tested on 25 October 2026. It reads the SHT20 through Modbus RTU and publishes measurements to the Node-RED dashboard over MQTT.

## Completed checks

| Check | Result | Record |
|---|---|---|
| Integrated sensor-to-dashboard path | 30 accepted hardware measurements in 60.010 seconds, with 0 bad and 0 rejected telemetry messages | MQTT capture and summary |
| Dashboard operation | Hardware / Fresh / Connected / Online / Healthy | Saved dashboard state and screenshot |
| Sensor disconnect and reconnect | Read errors appeared during intentional disconnection; valid readings resumed after reconnection | Manual functional check |
| Gateway Reset / USB disconnect and reconnect | Connection and readings resumed automatically | Manual functional check |

The [hardware test report](../HARDWARE_GATEWAY_VALIDATION_2026-10-25.md) contains technical details and links to raw records. The recovery checks were functional checks; recovery duration, MQTT Last Will timing, broker-outage behavior and extended-run reliability were not measured in this release.

## Recorded telemetry run

| Field | Value |
|---|---|
| Capture interval | 25 October 2026, 13:26:38.527Z–13:27:38.537Z (UTC) |
| Duration | 60.010 seconds |
| Application | industrial_gateway, ESP-IDF 6.1 |
| Run ID | 20261025-132638-fa9e1096 |
| Boot ID | e2d3a5f015ebebed67dd5b46f1e3d55b |
| Sequence interval | 509–538 |
| Telemetry result | 30 good / 0 bad / 0 rejected |
| Dashboard screenshot | [hardware-dashboard-2026-10-25.png](../images/hardware-dashboard-2026-10-25.png) |
| Physical bench photo | [hardware-bench-2026-10-25.png](../images/hardware-bench-2026-10-25.png) |

## Optional 60–90-second project video

| Approximate time | Shot | Focus |
|---|---|---|
| 0–15 s | Physical bench | SHT20, XY485 interface and ESP32-S3 wiring |
| 15–40 s | Live hardware dashboard | Temperature, humidity, gateway status and reading freshness |
| 40–60 s | MQTT payload and recorded result | Hardware source, advancing sequence, 30 good measurements in 60 seconds |
| 60–90 s | Architecture and repository | Data flow, firmware, wiring guide and test records |

Use real footage of the working system. The bench photo and dashboard screenshot also provide a complete still-image presentation. Keep credentials out of recordings and preserve the simulated label when showing the separate host fixture.

## Additional test recordings

For future timing or outage measurements, start the MQTT recorder before the intervention and preserve events across disconnection and recovery. For a Last Will test, keep the broker running long enough to observe its configured offline message, then record reconnect and new hardware telemetry. Report elapsed time from recorded events rather than an edited video's duration.
