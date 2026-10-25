# MQTT contract — v1

Implemented by the ESP32-S3 gateway and the separate host fixture. The JSON files in `examples/` illustrate the message structure.

The example files contain fixed historical timestamps. A running publisher must generate capture timestamps for its actual samples; replaying a static example must not make it fresh.

## Topics

| Topic | Payload | QoS | Retained |
|---|---|---|---|
| `industrial/gw-01/telemetry` | JSON reading or read failure | 1 | No |
| `industrial/gw-01/availability` | `online` / `offline` | 1 | Yes |
| `industrial/gw-01/diagnostics` | JSON counters and runtime information | 1 | No |

Configure a retained `offline` Last Will before connection. Publish `online` after connection. Host fixtures must not share a client ID with the real gateway or publish concurrently under its device identity.

## Telemetry fields

| Field | Meaning |
|---|---|
| `schema_version` | Integer 1 |
| `device_id` | Stable device name, initially `gw-01` |
| `source_mode` | `simulated` for host fixtures; `hardware` for the ESP32-S3 physical sensor path |
| `boot_id` | A new session identifier after each gateway/harness restart |
| `seq` | Increasing nonnegative integer within the session |
| `slave_id` | Modbus device address; initially 1 |
| `uptime_ms` | Monotonic runtime; not a UTC timestamp |
| `sample_ts_utc` | UTC capture time for this valid sample, or null when unavailable |
| `time_valid` | Whether the sample has a validated UTC capture time |
| `sample_age_ms` | Sample age when preparing the message; null if no valid sample exists |
| `quality` | `good` or `bad` |
| `values` | Object containing `temperature_c` and `humidity_pct`, or null on a failed read |
| `error` | Null on success; a machine-readable reason on failure |

Zero and negative temperature values are valid when returned by the sensor. Read failures use `values: null` and a specific error string.

## Receiver and dashboard rules

- Keep gateway availability separate from sensor/source health.
- Before the first accepted valid sample, display **No data**.
- Preserve the last valid reading when a read fails, but show the source error and its age.
- Mark data **Stale** after more than 10 seconds without a fresh valid sample, including when no messages arrive at all.
- Calculate age from capture time against the synchronized receiver clock. Message arrival time cannot make a delayed sample fresh. `sample_age_ms` alone cannot detect delay in an MQTT outbox.
- Do not grant verified fresh status to data whose time is unverified. Record receiver time and clock assumptions in timing tests.
- Reject samples older than the freshness threshold from the live chart. Treat timestamps more than 2,000 ms in the future as time errors.
- Suppress duplicate chart entries using `device_id`, `boot_id`, and `seq`; reject reordered older samples. Sequence numbers restart only with a new boot/session ID.
- A replay from an old session must not replace a newer accepted sample. The receiver compares capture time and tracks retired boot sessions.

## Outage behavior

Continue polling the source while MQTT is unavailable. Keep only the most recent reading in application RAM and bound the MQTT outbox. Count expired/dropped messages. On recovery, publish a current reading; v1 does not promise durable recovery of all samples from the outage.

Firmware diagnostics include uptime, read success/error counts, Wi-Fi/MQTT connection attempts, last successful sample age, dropped/expired message counters, PUBACK count and measured free heap bytes.

