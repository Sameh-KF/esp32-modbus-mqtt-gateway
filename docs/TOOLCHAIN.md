# Development toolchain

The project was developed and tested on Windows with the versions below. Host integration was exercised on 19 October 2026; physical ESP32-S3 integration followed on 24–25 October.

| Tool | Version used | Role |
|---|---|---|
| ESP-IDF | 6.1 | ESP32-S3 firmware build, flash and monitor |
| Python | 3.14.6 | Modbus host fixture, capture and test tools |
| PyModbus | 3.16.1 | Loopback Modbus TCP source and host gateway |
| paho-mqtt | 2.1.0 | Host MQTT tools |
| Node.js | 24.18.1 | Node-RED runtime |
| npm | 11.16.0 | Dependency installation |
| Node-RED | 5.0.8 | MQTT receiver and dashboard flows |
| FlowFuse Dashboard | 1.33.0 | Dashboard presentation |
| Eclipse Mosquitto | 2.1.2, Windows x64 | MQTT broker |
| 7-Zip | 26.04 | Portable extraction of the Mosquitto installer |

Python dependencies are pinned in `requirements.txt`; Node dependencies are recorded in `package.json` and `package-lock.json`. The firmware's managed MQTT dependency is declared in `firmware/gateway/main/idf_component.yml`.

## Runtime setup

`tools/Install-Demo.ps1` prepares the host dependencies. ESP-IDF is installed separately. Mosquitto is extracted from its official Windows installer for local use; the setup does not create a Windows service or change the global PATH or firewall policy.

The simulated fixture uses loopback services. The physical gateway uses an authenticated LAN MQTT listener on port 1884, with local access on port 1883. Dashboard access is local on port 1880. Runtime data, logs and credentials remain outside the published source. See [setup](release/SETUP.md) for the commands and configuration.

## Time handling

The host publisher uses `--trust-system-clock`; its publisher and receiver share the Windows UTC clock. The physical firmware synchronizes UTC through SNTP. The receiver combines UTC capture time with reported sample age, allows at most 2 seconds of future clock skew and marks a reading stale at age greater than 10 seconds. The dashboard refreshes ages once per second. Timing assumptions for the recorded runs are in the [host](HOST_VALIDATION_2026-10-19.md) and [hardware](HARDWARE_GATEWAY_VALIDATION_2026-10-25.md) test reports.

## Official references

- [ESP-IDF documentation](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/)
- [Eclipse Mosquitto downloads](https://mosquitto.org/download/)
- [Mosquitto installer source](https://github.com/eclipse-mosquitto/mosquitto/blob/master/installer/mosquitto.nsi)
- [Node-RED local installation](https://nodered.org/docs/getting-started/local)
- [FlowFuse Dashboard getting started](https://dashboard.flowfuse.com/getting-started.html)
- [PyModbus project](https://github.com/pymodbus-dev/pymodbus)
- [7-Zip downloads](https://www.7-zip.org/download.html)
