"""Host-only synthetic Modbus TCP to MQTT fixture, not ESP32 firmware."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import signal
import threading
import time
import uuid

import paho.mqtt.client as mqtt
from pymodbus.client import ModbusTcpClient
from pymodbus.exceptions import ModbusException

try:
    from .model import LatestSample, decode_registers, telemetry
except ImportError:
    from model import LatestSample, decode_registers, telemetry


class JsonLog:
    def __init__(self, path=None):
        self.lock = threading.Lock()
        self.file = None
        if path:
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            self.file = open(path, "a", encoding="utf-8")

    def write(self, event, **fields):
        record = {"event": event, "logged_at_utc": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"), **fields}
        line = json.dumps(record, allow_nan=False, separators=(",", ":"))
        with self.lock:
            print(line, flush=True)
            if self.file:
                self.file.write(line + "\n")
                self.file.flush()

    def close(self):
        if self.file:
            self.file.close()


def read_values(client, device_id):
    try:
        if not client.connected and not client.connect():
            return None, "modbus_connect_failed"
        response = client.read_holding_registers(0, count=2, device_id=device_id)
        if response.isError():
            return None, "modbus_exception"
        return decode_registers(response.registers), None
    except (OSError, ModbusException):
        client.close()
        return None, "modbus_transport_error"
    except (ValueError, TypeError, AttributeError):
        return None, "modbus_invalid_response"


def broker_worker(args, store, stop, logger, started, boot_id):
    """One network thread; abandoned client outboxes cannot replay on reconnect."""
    while not stop.is_set():
        connected = False
        disconnected = False
        pending = {}
        last_sent = -1
        last_diagnostics = time.monotonic()

        def on_connect(client, userdata, flags, reason_code, properties):
            nonlocal connected, disconnected
            if reason_code.is_failure:
                disconnected = True
                return
            connected = True
            store.increment("mqtt_connection_count")
            logger.write("mqtt_connected", source_mode="simulated")
            info = client.publish(args.prefix + "/availability", "online", qos=1, retain=True)
            if info.rc == mqtt.MQTT_ERR_SUCCESS:
                pending[info.mid] = "availability"

        def on_disconnect(client, userdata, flags, reason_code, properties):
            nonlocal connected, disconnected
            connected = False
            disconnected = True

        def on_publish(client, userdata, mid, reason_code, properties):
            pending.pop(mid, None)

        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                             client_id="host-sim-" + boot_id[:8], clean_session=True,
                             protocol=mqtt.MQTTv311, reconnect_on_failure=False)
        client.connect_timeout = 3
        client.max_inflight_messages_set(1)
        client.max_queued_messages_set(1)
        client.will_set(args.prefix + "/availability", "offline", qos=1, retain=True)
        client.on_connect, client.on_disconnect, client.on_publish = on_connect, on_disconnect, on_publish
        store.increment("mqtt_connection_attempts")
        try:
            client.connect(args.mqtt_host, args.mqtt_port, keepalive=args.keepalive)
            while not stop.is_set() and not disconnected:
                result = client.loop(timeout=0.1)
                if result != mqtt.MQTT_ERR_SUCCESS:
                    break
                if not connected or pending:
                    continue
                sample = store.snapshot()
                if sample is not None and sample["seq"] != last_sent:
                    # A good sample that aged while the broker was absent cannot become fresh.
                    if sample["quality"] == "good":
                        age = max(0, round((time.monotonic() - started) * 1000) - sample["uptime_ms"])
                        sample["sample_age_ms"] = age
                        if age > args.max_sample_age * 1000:
                            store.increment("expired_messages_count")
                            store.consumed(sample["seq"])
                            last_sent = sample["seq"]
                            continue
                    info = client.publish(args.prefix + "/telemetry", json.dumps(sample, allow_nan=False), qos=1, retain=False)
                    if info.rc == mqtt.MQTT_ERR_SUCCESS:
                        pending[info.mid] = "telemetry"
                        last_sent = sample["seq"]
                        store.consumed(last_sent)
                        logger.write("mqtt_telemetry", payload=sample)
                elif time.monotonic() - last_diagnostics >= args.diagnostics_interval:
                    payload = store.diagnostics(started, boot_id, args.device_id)
                    info = client.publish(args.prefix + "/diagnostics", json.dumps(payload), qos=1, retain=False)
                    if info.rc == mqtt.MQTT_ERR_SUCCESS:
                        pending[info.mid] = "diagnostics"
                        last_diagnostics = time.monotonic()
                        logger.write("mqtt_diagnostics", payload=payload)
        except (OSError, ValueError) as error:
            logger.write("mqtt_unavailable", error=type(error).__name__, source_mode="simulated")
        finally:
            if stop.is_set() and connected:
                # Finish any QoS1 exchange before the retained offline message where possible.
                deadline = time.monotonic() + 1
                while pending and time.monotonic() < deadline:
                    if client.loop(timeout=0.05) != mqtt.MQTT_ERR_SUCCESS:
                        break
                info = client.publish(args.prefix + "/availability", "offline", qos=1, retain=True)
                deadline = time.monotonic() + 1
                while not info.is_published() and time.monotonic() < deadline:
                    if client.loop(timeout=0.05) != mqtt.MQTT_ERR_SUCCESS:
                        break
            if "telemetry" in pending.values():
                store.increment("dropped_messages_count")
            client.disconnect()
            if connected or disconnected:
                store.increment("mqtt_disconnect_count")
                logger.write("mqtt_disconnected", source_mode="simulated")
        stop.wait(args.reconnect_interval)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--modbus-host", default="127.0.0.1")
    parser.add_argument("--modbus-port", type=int, default=1502)
    parser.add_argument("--mqtt-host", default="127.0.0.1")
    parser.add_argument("--mqtt-port", type=int, default=1883)
    parser.add_argument("--prefix", default="industrial/gw-01")
    parser.add_argument("--device-id", default="gw-01")
    parser.add_argument("--slave-id", type=int, default=1)
    parser.add_argument("--interval", type=float, default=2)
    parser.add_argument("--timeout", type=float, default=1)
    parser.add_argument("--keepalive", type=int, default=10)
    parser.add_argument("--reconnect-interval", type=float, default=1)
    parser.add_argument("--diagnostics-interval", type=float, default=10)
    parser.add_argument("--max-sample-age", type=float, default=10)
    parser.add_argument("--trust-system-clock", action="store_true", help="Explicitly assume this host's UTC clock is synchronized; no external time verification is performed")
    parser.add_argument("--log", help="Append local events to a JSONL file")
    args = parser.parse_args()
    if any(v <= 0 for v in (args.interval, args.timeout, args.reconnect_interval, args.diagnostics_interval, args.max_sample_age)) or not 1 <= args.slave_id <= 247:
        parser.error("intervals/timeouts must be positive; slave id must be 1..247")
    if not 0 < args.modbus_port <= 65535 or not 0 < args.mqtt_port <= 65535 or args.keepalive < 1:
        parser.error("invalid port or keepalive")
    if not args.prefix or any(c in args.prefix for c in "+#"):
        parser.error("prefix must be a nonempty literal topic prefix")
    args.prefix = args.prefix.rstrip("/")
    if not args.prefix:
        parser.error("prefix cannot consist only of slashes")
    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *unused: stop.set())
    signal.signal(signal.SIGTERM, lambda *unused: stop.set())
    logger = JsonLog(args.log)
    started, boot_id = time.monotonic(), str(uuid.uuid4())
    store = LatestSample()
    client = ModbusTcpClient(args.modbus_host, port=args.modbus_port, timeout=args.timeout, retries=0)
    thread = threading.Thread(target=broker_worker, args=(args, store, stop, logger, started, boot_id), daemon=True)
    logger.write("gateway_start", source_mode="simulated", boot_id=boot_id,
                 clock_assumption="single_host_system_UTC_assumed_synchronized_no_external_validation" if args.trust_system_clock else "unverified",
                 register_map="synthetic_FC03_0_1_not_Hailege")
    thread.start()
    seq = 0
    try:
        while not stop.is_set():
            poll_started = time.monotonic()
            values, error = read_values(client, args.slave_id)
            sample = telemetry(device_id=args.device_id, boot_id=boot_id, seq=seq, slave_id=args.slave_id,
                               started=started, values=values, error=error, trust_system_clock=args.trust_system_clock)
            store.offer(sample)
            logger.write("source_sample", payload=sample)
            seq += 1
            stop.wait(max(0, args.interval - (time.monotonic() - poll_started)))
    finally:
        stop.set()
        client.close()
        thread.join(timeout=6)
        logger.write("gateway_stop", **store.diagnostics(started, boot_id, args.device_id))
        logger.close()


if __name__ == "__main__":
    main()
