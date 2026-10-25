# RS485 interface check — 25 October 2026

**Result: two XY485 modules exchanged all six test frames successfully: 3/3 in each direction.** This established the UART/RS485 path before connecting the SHT20.

## Fixture

| Connection | Configuration |
|---|---|
| Controller | ESP32-S3; ESP-IDF 6.1 |
| First interface | UART1 TX=GPIO17 → XY485 TXD; RX=GPIO18 ← XY485 RXD |
| Second interface | UART2 TX=GPIO16 → XY485 TXD; RX=GPIO21 ← XY485 RXD |
| Module power | 3.3 V; common GND |
| Bus | A+ to A+, B− to B−; Earth terminal unused |
| Serial format | 9600 baud, 8N1 |
| Console | Separate UART0 USB connection at 115200 baud |

The sensor and USB-to-RS485 adapter were disconnected from the test bus. Each round sent distinct `PAIR_A` and `PAIR_B` markers containing a fresh boot nonce and round number; a pass required the exact current marker on the opposite UART.

## Result

The run used boot nonce `D95D42ACE31C255A` and application ELF prefix `044a00d86`. Each received frame was 26 bytes.

```text
SUMMARY U1->U2 3/3 PASS; U2->U1 3/3 PASS
```

The [serial excerpt](evidence/2026-10-25/rs485-pair-pass-user-monitor-excerpt.txt) preserves the six transfers and summary.

## Application to the gateway

The completed gateway uses the first UART/XY485 path directly with the SHT20. A USB-to-RS485 adapter was useful for early PC diagnostics but is not part of the final Wi-Fi gateway or this successful pair fixture. The [sensor read test](SHT20_PHYSICAL_VALIDATION_2026-10-25.md) and [end-to-end test](HARDWARE_GATEWAY_VALIDATION_2026-10-25.md) cover the subsequent integration.
