# ESP32-S3 monitoring gateway — portfolio

## Title

ESP32-S3 Modbus RTU to MQTT Sensor Monitoring Gateway

## Role

Embedded firmware, RS485 diagnostics, MQTT integration and dashboard

## Description
I built an ESP32-S3 gateway that reads an SHT20 sensor over Modbus RTU/RS485 and publishes temperature and humidity through MQTT to a Node-RED dashboard. It shows live readings, sensor health and connection status, and marks old readings as stale. I implemented CRC validation, error handling and automatic reconnection. Testing included 30 valid readings in a recorded 60-second run, sensor disconnect/reconnect and board restart recovery. Includes firmware, wiring, setup instructions and test records.

## Skills

ESP32, MQTT, Modbus, Embedded System, Internet of Things

## Project images

1. **Physical prototype:** ESP32-S3, XY485 UART-to-RS485 interface and SHT20 temperature/humidity sensor.
2. **Live dashboard:** connected gateway, healthy sensor and fresh temperature/humidity readings.
3. **Sensor communication error:** the gateway stays online while the last valid readings are preserved and marked stale.

## Source and documentation

[GitHub repository](https://github.com/Sameh-KF/esp32-modbus-mqtt-gateway)

[Published Upwork project](https://www.upwork.com/freelancers/~01bf859acae2eb4744?p=2114380756390735872)
