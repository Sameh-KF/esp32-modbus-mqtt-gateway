# SHT20 Modbus RTU read test — 25 October 2026

**Result: 10 requests, 10 valid responses, 0 failed reads.** Each response passed CRC16 validation. This standalone test established the sensor profile used by the completed [MQTT gateway](HARDWARE_GATEWAY_VALIDATION_2026-10-25.md).

## Tested configuration

| Item | Value |
|---|---|
| MCU / framework | ESP32-S3 / ESP-IDF 6.1 |
| UART interface | UART1; GPIO17 → XY485 TXD; GPIO18 ← XY485 RXD |
| XY485 supply / direction | ESP32 3.3 V; automatic direction |
| Sensor serial format | 9600 baud, 8N1 |
| Unit ID | 1 |
| Function / raw start / count | FC04 / `0x0001` / 2 |
| Request | `01 04 00 01 00 02 20 0B` |
| Temperature | Register `0x0001`; signed 16-bit, big-endian; divide by 10 for °C |
| Humidity | Register `0x0002`; unsigned 16-bit, big-endian; divide by 10 for %RH |
| Sensor wiring | Red supply+, black common DC 0 V, yellow A+, white B− |
| Sensor supply | Separate nominal 12 V supply |
| Console | UART0 at 115200 baud |

These are the settings verified on the tested sensor.

## Responses

| Samples | Response bytes | Temperature register | Humidity register | Decoded reading |
|---|---|---:|---:|---|
| 1–7 | `01 04 04 01 04 02 20 BB 01` | 260 | 544 | 26.0 °C / 54.4 %RH |
| 8–10 | `01 04 04 01 04 02 21 7A C1` | 260 | 545 | 26.0 °C / 54.5 %RH |

All ten response CRCs were recalculated and matched. The wire CRC is little-endian: `BB 01` represents `0x01BB`, and `7A C1` represents `0xC17A`. Requests were issued every two seconds.

## Resolved wiring fault

Initial direct reads received no response. Inspection found the white RS485 B conductor detached inside the sensor. After repairing the conductor and restoring yellow=A+ / white=B−, the same firmware and read settings produced the 10/10 successful run. No address, baud-rate or register-map change was required.

## Test record

The [serial transcript](evidence/2026-10-25/sht20-esp-after-white-wire-repair-user-monitor.txt) preserves the requests, responses and `attempts=10 good=10 bad=0` summary. Its SHA256 is `2CB412E420D65B2A4EDA8BF7FA420059214CA48B1F8AEDB2885E40FF8C5F2A4D`.

The standalone application's ELF prefix is `762e4d39a`, matching local SHA256 `762E4D39A8B30AD8C52018B5016C0D0F53385B7F9F599AE7304DB5CABBFE690D`.

This test verifies communication, framing and decoding on the physical sensor. The [hardware validation report](HARDWARE_GATEWAY_VALIDATION_2026-10-25.md) records the subsequent end-to-end test and its measurement scope.
