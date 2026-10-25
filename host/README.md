# Host fixtures

Optional software fixtures for exercising the MQTT pipeline and receiver without hardware. The simulator provides a synthetic Modbus TCP device; `gateway.py` publishes its readings with `source_mode: simulated`. The physical ESP32-S3 firmware is in [firmware/gateway](../firmware/gateway).

Validated dependencies: Python 3.14.6, `pymodbus==3.16.1`, `paho-mqtt==2.1.0`.

Run from the repository folder using the prepared Python environment:

```text
python host/simulator.py --host 127.0.0.1 --port 1502
python host/gateway.py --modbus-host 127.0.0.1 --modbus-port 1502 --mqtt-host 127.0.0.1 --mqtt-port 1883 --trust-system-clock --log work/gateway.jsonl
```

Mosquitto must already be running. The optional log path above is relative to your current directory. The gateway can start before either service: it continues polling and reconnecting.

`--trust-system-clock` explicitly assumes the computer's UTC clock is synchronized. The program performs no external clock validation. Without this flag, numeric readings can still be good, but `time_valid` is false and the capture timestamp is null; a receiver must not label those readings verified fresh.

## Synthetic source

The default device ID is 1. Only this artificial FC03 map is used:

| Zero-based address | Encoding | Meaning |
|---|---|---|
| 0 | Signed 16-bit two's complement, divide by 10 | Temperature in degrees C |
| 1 | Unsigned 16-bit, divide by 10 | Relative humidity in percent |

The default fixture returns 25.0 °C and 60.0% relative humidity. To test other values, including zero or negative temperatures, create a JSON file:

```json
{"temperature_c": -5.2, "humidity_pct": 48.7}
```

Pass its path with `--state-file`. The file is read on every request; update it atomically to avoid a transient partially written file. A missing or malformed state file produces a Modbus device-failure response instead of silently returning previous values. Stop the simulator to test a transport outage. Both cases keep gateway availability separate from source quality.

## MQTT behavior

All telemetry and diagnostics have `source_mode: simulated`. The gateway uses the agreed topic prefix `industrial/gw-01`; pass `--prefix` to override it. Defaults are a two-second polling interval, one-second Modbus timeout, ten-second keepalive, and one-second reconnect delay.

The source loop and MQTT worker run independently. A single application slot keeps the latest sample; counters track overwritten and expired messages. The MQTT client bounds both its inflight and queued messages to one. Each lost connection abandons that client's outbox and creates a new clean session, so old samples from an outage cannot replay as fresh. Delivery during an outage is intentionally lossy. QoS1 can duplicate a message; receivers must deduplicate by device, boot ID, and sequence.

Availability is retained, with an offline last will. Normal termination attempts a retained offline publication and acknowledgement before closing. Forced termination relies on the broker detecting the lost connection. `source_sample` and `mqtt_telemetry` log events distinguish source polling from publishing. A publish event records acceptance by the client library, not proof of subscriber receipt; use an independent receiver for integration evidence.

Run model tests with:

```text
python -m unittest discover -s tests -p test_host.py -v
```
