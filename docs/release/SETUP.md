# Reproduce the gateway

This guide sets up the physical SHT20 → RS485 → ESP32-S3 → MQTT → Node-RED system. The [test report](../HARDWARE_GATEWAY_VALIDATION_2026-10-25.md) records the completed hardware checks and the 60-second telemetry capture.

## Requirements

- ESP32-S3 with 16 MB Flash, an XY485 UART-to-RS485 interface, an SHT20 Modbus RS485 sensor, a suitable sensor supply and a USB data cable.
- ESP-IDF 6.1; the component manifest pins `espressif/mqtt` to 1.1.0.
- Windows x64, PowerShell 5.1 or 7, Python 3.10 or later, and Node.js 22.9 or later with npm.

## Prepare the host

From the repository root, install the local runtime and create the broker password file:

```powershell
.\tools\Install-Demo.ps1
New-Item -ItemType Directory -Path .\secrets -Force | Out-Null
& .\.runtime\mosquitto\mosquitto_passwd.exe -c .\secrets\mosquitto.passwd esp32_lab
```

Enter the password when prompted. Use `-c` only for a new password file; omit it when adding an account to an existing file. Keep `secrets/` and the generated firmware `sdkconfig` private.

Start the hardware broker and dashboard, replacing the example address with the PC's LAN IPv4 address:

```powershell
.\tools\Start-HardwareDemo.ps1 -LanAddress 192.168.1.105
```

The launcher binds authenticated MQTT port 1884 to that address. Port 1883 is available on loopback for the local dashboard and recorder. Add `-RestartDashboard` when switching an existing simulated dashboard to hardware mode, or `-RestartBroker` if an existing project broker needs a new LAN address. The launcher manages only processes recorded for this project. If installation used a custom `-RuntimeRoot`, pass the same directory to the launcher and capture tools, and use it in place of `.runtime` for `mosquitto_passwd.exe`.

The ESP32 and host PC must communicate on the local network. If a host firewall rule is required, limit it to TCP 1884 on the trusted local network.

## Wire the hardware

| Connection | Destination |
|---|---|
| ESP32-S3 3V3 | XY485 VCC |
| ESP32-S3 GND | XY485 GND and sensor supply 0 V |
| GPIO17 / UART1 TX | XY485 TXD input |
| GPIO18 / UART1 RX | XY485 RXD output |
| Sensor yellow / A+ | XY485 A+ |
| Sensor white / B− | XY485 B− |
| Sensor red / supply + | Suitable external sensor supply + |
| Sensor black / supply − | External sensor supply 0 V |

The XY485 provides automatic direction control. In this board's labeling, GPIO17 connects to TXD and GPIO18 to RXD. Verify the actual module pin labels. Sensor supply voltage must not connect to ESP32 GPIO, 3V3 or the XY485 VCC in this circuit. The USB-to-RS485 adapter is a separate diagnostic tool; the final gateway uses the XY485 interface.

## Configure and flash the firmware

Open `firmware/gateway` as an ESP-IDF project. For a fresh checkout, select target `esp32s3` and the board's actual serial port. In `Menuconfig`, set:

| Menu | Settings |
|---|---|
| `Gateway WiFi` | Local Wi-Fi SSID and password |
| `Gateway MQTT` | `mqtt://<PC-LAN-IPv4>:1884`, broker username and password |
| `Gateway clock` | Reachable SNTP server; default `pool.ntp.org` |

The tested sensor profile is unit 1, 9600 baud, 8N1, function 04, raw start address 1 and count 2. The checked-in defaults include the board's 16 MB Flash setting.

In that project's ESP-IDF terminal, build and flash:

```powershell
idf.py reconfigure
idf.py build
idf.py -p COM9 flash monitor
```

Replace `COM9` with the board's actual port. Close any other monitor using that port before flashing. Expected operation includes successful sensor reads, Wi-Fi/MQTT connection and timestamp synchronization.

## View and record measurements

Open [the local dashboard](http://127.0.0.1:1880/dashboard/overview). A working run shows `Hardware` / `Fresh` / `Connected` / `Online` / `Healthy`, with live temperature and humidity. Gateway availability, sensor health and reading freshness are separate states.

From PowerShell at the repository root, save a 60-second capture:

```powershell
.\tools\Capture-HardwareEvidence.ps1 -Seconds 60
```

The recorder stores raw messages, a summary and dashboard state under the runtime's `logs/hardware-evidence/` directory. It subscribes without publishing simulated measurements. See the [acceptance record and optional video guide](CAPTURE_AND_ACCEPTANCE.md) for existing results and a short presentation sequence.

The separate `host/` simulator exercises receiver behavior without hardware. Its measurements are labeled `simulated` and kept distinct from physical readings.
