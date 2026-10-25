# Industrial telemetry dashboard

A Node-RED and FlowFuse Dashboard interface for the ESP32-S3 gateway. It displays temperature, humidity, gateway availability, sensor status and sample age, with a history of the latest 120 accepted measurements.

Each run uses either hardware telemetry or the optional host simulation. The source is visible in the banner, and a run cannot mix the two sources.

## Startup

The tested environment uses Node.js 24.18.1, Node-RED 5.0.8 and FlowFuse Dashboard 1.33.0. From the repository root, prepare the local dependencies as described in [setup](../docs/release/SETUP.md), then start the hardware runtime:

```powershell
.\tools\Start-HardwareDemo.ps1 -LanAddress '192.168.1.105'
```

Replace the example address with the computer's current IPv4 address reachable by the ESP32. It can be omitted when there is one unambiguous active LAN route.

Open <http://127.0.0.1:1880/dashboard/overview>. The receiver snapshot is available at <http://127.0.0.1:1880/api/state>. Node-RED and its editor are bound to loopback. The broker uses anonymous loopback port 1883 for local processes and authenticated LAN port 1884 for the ESP32.

The launcher reuses compatible project processes and stops project-owned simulation publishers when switching to hardware. Use `-RestartDashboard` when loading updated dashboard files, and `-RestartBroker` when changing the broker's LAN address. Process ownership is checked using PID, start time and executable path.

For an existing Node-RED installation, use `dashboard/settings.cjs` as the settings file and provide a user directory containing `node-red` and `@flowfuse/node-red-dashboard`. The settings resolve `flows.json` and `receiver.js` relative to their own folder. Importing `flows.json` also requires the `industrialReceiver` module in `functionGlobalContext`, as shown in the supplied settings. The dashboard is read-only and subscribes to `industrial/gw-01/+`.

## Receiver behavior

- MQTT transport, gateway availability, sensor health and reading freshness are displayed separately.
- If the gateway or MQTT connection is unavailable, a previously known sensor state is labeled Last known and shown in a neutral color. Unknown is used when no sensor state is available.
- A live telemetry message establishes gateway availability after MQTT connects; a retained `online` message alone is not enough.
- Sensor errors preserve the last valid reading and continue increasing its age. Measurements older than 10 seconds are marked **Stale**.
- Freshness uses capture UTC and publisher-reported age. Timestamps up to 2 seconds in the future are tolerated; expired or invalid measurements stay out of the chart.
- Duplicate and reordered sequences, retained telemetry, retired boot IDs and unverified new sessions cannot replace current values.
- A new boot session is accepted after a valid timed measurement newer than the previous session's last capture.
- Temperature uses an adaptive chart axis; humidity uses a separate 0–100% axis. A one-second timer updates sample age.
- History, counters and session state are held in RAM and reset when a new receiver run starts.

See [MQTT contract](../docs/MQTT_CONTRACT.md) for payload details and [hardware validation](../docs/HARDWARE_GATEWAY_VALIDATION_2026-10-25.md) for recorded test results.

## Editing and tests

`overview.vue` is the readable source of the FlowFuse `ui-template` widget. Rebuild the flow after editing it:

```powershell
node dashboard/build_flows.js
node --test tests/test_receiver.js
```

Receiver tests cover numeric edge cases, malformed messages, errors and recovery, stale data, clock skew, duplicates, session changes, broker loss and bounded history. The receiver module uses Node.js built-ins.

## Recording hardware traffic

```powershell
.\tools\Capture-HardwareEvidence.ps1 -Seconds 60
python -m unittest discover -s tests -p test_hardware_evidence.py -v
```

The capture tool subscribes to existing local MQTT traffic. It saves `messages.jsonl` and `summary.json` in a unique `logs/hardware-evidence` directory. Reports distinguish valid hardware readings, sensor errors and rejected messages. The tool does not publish data or control hardware.

Implementation references: [Node-RED function global context](https://nodered.org/docs/user-guide/writing-functions#global-context), [runtime configuration](https://nodered.org/docs/user-guide/runtime/configuration), and [FlowFuse templates](https://dashboard.flowfuse.com/nodes/widgets/ui-template.html).
