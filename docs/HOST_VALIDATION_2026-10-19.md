# Host validation — 19 October 2026

**Result: the ten-minute simulated host integration and all 13 outage/recovery checks passed.** The physical ESP32-S3 path was tested separately on 25 October; see the [hardware report](HARDWARE_GATEWAY_VALIDATION_2026-10-25.md).

## System exercised

Synthetic PyModbus TCP source on `127.0.0.1:1502` → Python host gateway → actual Eclipse Mosquitto on `127.0.0.1:1883` → Node-RED / FlowFuse Dashboard and its `/api/state` receiver on `127.0.0.1:1880`.

The published MQTT messages use QoS 1 and explicitly state `source_mode: simulated`. The host fixture uses FC03 registers 0 and 1 with signed temperature and unsigned humidity in tenths. The physical SHT20 uses a separate FC04 profile. See [tool versions and sources](TOOLCHAIN.md).

## Measured normal run

Recorded UTC interval including startup and fault tests: **12:57:16.692 to 13:07:51.983**. The normal-operation phase lasted **600.009 seconds** before deliberate faults.

| Observation | Measured result |
|---|---|
| Normal-run duration | 600.009 s |
| Receiver snapshots checked | 589 |
| New accepted good samples after baseline | 298 |
| Distinct temperature values | 172 |
| Distinct humidity values | 182 |
| Maximum sample age observed by API polling | 2,098 ms |
| Expected states at every normal-run snapshot | Broker connected; gateway online; source healthy; measurement fresh |

The test polled the state API approximately once per second and checked component processes remained alive. Maximum observed age is an observation of this host test, not an end-to-end latency bound or an MCU performance result.

## Faults and known values

| Scenario | Measured observation in the long run |
|---|---|
| Stop Modbus source | Source error detected in 0.670 s; gateway remained online and values were preserved |
| Wait for old data | Stale observed at sample age 10,076 ms, 8.617 s after stopping the source |
| Restart source | Healthy fresh readings returned in 2.074 s |
| Known negative reading | −5.2 °C and 48.7% reached the receiver |
| Known zero reading | 0 °C and 0% were valid, fresh measurements |
| Known positive reading | 23.4 °C and 62.5% reached the receiver |
| Stop MQTT broker | Receiver reported disconnected transport and unknown gateway availability |
| Continue source polling without MQTT | Three source reads recorded during the seven-second outage window |
| Restart broker | Fresh receiver data returned in 4.948 s; observed sample age 121 ms |
| Abruptly stop gateway | Broker Last Will changed availability to offline; observed on the local host |
| Restart gateway | A new boot ID was accepted with a new timed reading |

Stale age is measured from the last valid capture, not from the instant the source is disconnected. That sample was already more than a second old when the source stopped. The display's one-second timer may update later than an immediate API snapshot.

## Unit checks and browser inspection

- **34 receiver tests passed**, including invalid data, zero/negative values, capture timestamps, stale ticks without messages, duplicates, ordering, retired sessions, transport status and bounded history.
- **Five host-model tests passed**, including signed conversion, invalid register types/ranges, failed reads and bounded latest-sample buffering.
- A browser inspection confirmed changing readings, the **SIMULATED · HOST TEST** banner and separate connection/source/freshness states. No browser console errors were observed during the check. [Captured dashboard](images/host-dashboard.png).

Malformed, duplicate and delayed-message handling is covered by deterministic receiver unit tests.

## Reproduce

Stop the demonstration first so ports are free. From the project directory, use the prepared environment's Python executable:

```powershell
<runtime>/python-env/Scripts/python.exe tests/run_integration.py --runtime-root <runtime> --seconds 600 --output test-results/host-run
```

Replace `<runtime>` with the actual runtime directory; it is a placeholder, not a literal command path. The integration runner starts and owns all four processes, records JSON evidence and stops them on completion. The normal dashboard launcher is `tools/Start-Demo.ps1`.

## Evidence and limitations

The figures above describe the long integration run. A separate short verification run is summarized below; its timings are kept separate. The [integration runner](../tests/run_integration.py) creates new JSON results when reproduced.

A short verification run used strengthened checks for preserved values after source errors, newer sequences, continued polling during broker loss and abrupt gateway termination. It **passed all 13 checks** from 13:08:08.911 to 13:08:53.597 UTC. Its normal phase lasted 10.185 s; source recovery was 0.457 s, broker recovery 5.039 s, stale was observed at age 10,147 ms, and three source polls occurred during broker loss. Its report is kept separately; these timings do not replace the long-run measurements above.

The deployed flow has a regression test for Node-RED 5 MQTT status keys. The host installer completed successfully with the dependency lock unchanged.

Publisher and receiver use the same Windows UTC clock, explicitly trusted with `--trust-system-clock`; no independent NTP validation was performed. The receiver permits at most 2 s of future skew and uses the older of UTC capture time and reported age. The broker and dashboard are loopback-only. The demo makes no durable sample-recovery promise during MQTT outages.

This report records the simulated host test only. Physical sensor, RS485 and unified firmware results are recorded in the [25 October hardware report](HARDWARE_GATEWAY_VALIDATION_2026-10-25.md).

