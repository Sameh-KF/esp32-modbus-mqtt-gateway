"""Capture existing MQTT traffic only; never publish samples or control hardware."""
from __future__ import annotations
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import time
import uuid

PREFIX = "industrial/gw-01/"
REQUIRED = {"schema_version", "device_id", "source_mode", "boot_id", "seq", "slave_id",
            "uptime_ms", "sample_ts_utc", "time_valid", "sample_age_ms", "quality", "values", "error"}
UTC_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
BOOT_PATTERN = re.compile(r"^[0-9a-f]{32}$")
STALE_MS = 10_000
FUTURE_SKEW_MS = 2_000

def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")

def number(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False

def natural(value):
    return type(value) is int and 0 <= value <= 9_007_199_254_740_991

def validate(payload):
    if not isinstance(payload, dict) or not REQUIRED.issubset(payload):
        return "missing_schema_fields"
    p = payload
    if type(p["schema_version"]) is not int or p["schema_version"] != 1 or p["device_id"] != "gw-01":
        return "identity_or_schema"
    if p["source_mode"] != "hardware":
        return "non_hardware_source"
    if not isinstance(p["boot_id"], str) or not BOOT_PATTERN.fullmatch(p["boot_id"]):
        return "hardware_boot_id"
    if not natural(p["seq"]) or not natural(p["uptime_ms"]):
        return "sequence_or_uptime"
    if type(p["slave_id"]) is not int or p["slave_id"] != 1:
        return "slave_id"
    if type(p["time_valid"]) is not bool:
        return "time_valid"
    if p["sample_age_ms"] is not None and (not number(p["sample_age_ms"]) or p["sample_age_ms"] < 0):
        return "sample_age"
    stamp = p["sample_ts_utc"]
    if stamp is not None:
        if not isinstance(stamp, str) or not UTC_PATTERN.fullmatch(stamp):
            return "capture_timestamp"
        try:
            parsed = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
            if parsed.isoformat(timespec="milliseconds").replace("+00:00", "Z") != stamp:
                return "capture_timestamp"
        except ValueError:
            return "capture_timestamp"
    if p["quality"] == "good":
        values = p["values"]
        if not isinstance(values, dict) or set(values) != {"temperature_c", "humidity_pct"}:
            return "good_values"
        if not number(values["temperature_c"]) or not number(values["humidity_pct"]) or not 0 <= values["humidity_pct"] <= 100 or p["error"] is not None:
            return "good_values"
        if p["time_valid"] and (stamp is None or p["sample_age_ms"] is None):
            return "verified_time_missing"
    elif p["quality"] == "bad":
        if p["values"] is not None or not isinstance(p["error"], str) or not 1 <= len(p["error"]) <= 256:
            return "bad_values"
    else:
        return "quality"
    return None

class EvidenceState:
    def __init__(self):
        self.counts = Counter(mqtt_messages=0, telemetry_messages=0, accepted_hardware_good=0, accepted_hardware_bad=0, rejected_telemetry=0, availability_messages=0, diagnostic_messages=0)
        self.source_modes = Counter()
        self.reject_reasons = Counter()
        self.boots = {}
        self.active_boot = None
        self.retired_boots = set()
        self.max_seq = -1
        self.newest_capture_ms = None
        self.last_availability = None
        self.sample_ages_ms = []
        self.first_good = None
        self.last_good = None

    def reject(self, reason):
        self.counts["rejected_telemetry"] += 1
        self.reject_reasons[reason] += 1
        return {"accepted": False, "reason": reason}

    def observe(self, topic, payload, retained, received_ms):
        suffix = topic[len(PREFIX):] if topic.startswith(PREFIX) else ""
        self.counts["mqtt_messages"] += 1
        if suffix == "availability":
            self.counts["availability_messages"] += 1
            if payload in ("online", "offline"):
                self.last_availability = {"value": payload, "retained": retained, "received_ms": received_ms}
            return {"accepted": False, "reason": "availability_is_not_measurement"}
        if suffix == "diagnostics":
            self.counts["diagnostic_messages"] += 1
            return {"accepted": False, "reason": "diagnostics_are_not_measurements"}
        if suffix != "telemetry":
            return {"accepted": False, "reason": "unrelated_topic"}
        self.counts["telemetry_messages"] += 1
        if isinstance(payload, dict):
            self.source_modes[str(payload.get("source_mode", "missing"))] += 1
        if retained:
            return self.reject("retained_telemetry")
        issue = validate(payload)
        if issue:
            return self.reject(issue)
        p = payload
        capture_ms = None
        if p["time_valid"] and p["sample_ts_utc"] is not None:
            capture_ms = datetime.fromisoformat(p["sample_ts_utc"].replace("Z", "+00:00")).timestamp() * 1000
            if capture_ms - received_ms > FUTURE_SKEW_MS:
                return self.reject("capture_time_in_future")
        boot = p["boot_id"]
        if boot in self.retired_boots:
            return self.reject("retired_session")
        if self.active_boot is not None and boot != self.active_boot:
            if p["quality"] != "good" or capture_ms is None or (
                self.newest_capture_ms is not None and capture_ms <= self.newest_capture_ms
            ):
                return self.reject("unproven_new_session")
            self.retired_boots.add(self.active_boot)
            self.max_seq = -1
        if p["seq"] <= self.max_seq:
            return self.reject("duplicate_sequence" if p["seq"] == self.max_seq else "reordered_sequence")
        if p["quality"] == "good" and capture_ms is not None and self.newest_capture_ms is not None and capture_ms < self.newest_capture_ms:
            return self.reject("reordered_capture_time")
        self.active_boot = boot
        self.max_seq = p["seq"]
        stat = self.boots.setdefault(boot, {"first_seq": p["seq"], "last_seq": p["seq"], "messages": 0, "good": 0, "bad": 0})
        stat["last_seq"] = p["seq"]
        stat["messages"] += 1
        if p["quality"] == "bad":
            self.counts["accepted_hardware_bad"] += 1
            stat["bad"] += 1
            return {"accepted": True, "quality": "bad", "error": p["error"]}
        if capture_ms is None:
            return self.reject("time_unverified")
        effective_age = max(received_ms - capture_ms, p["sample_age_ms"], 0)
        self.newest_capture_ms = capture_ms
        if effective_age > STALE_MS:
            return self.reject("sample_expired")
        self.counts["accepted_hardware_good"] += 1
        stat["good"] += 1
        self.sample_ages_ms.append(effective_age)
        point = {"boot_id": boot, "seq": p["seq"], "sample_ts_utc": p["sample_ts_utc"],
                 "received_ms": received_ms, "effective_age_ms": effective_age, "values": p["values"]}
        if self.first_good is None:
            self.first_good = point
        self.last_good = point
        return {"accepted": True, "quality": "good", "effective_age_ms": effective_age}

    def summary(self):
        ages = self.sample_ages_ms
        return {
            "counts": dict(self.counts), "source_modes": dict(self.source_modes),
            "reject_reasons": dict(self.reject_reasons), "boots": self.boots,
            "last_availability": self.last_availability, "first_good": self.first_good, "last_good": self.last_good,
            "age_ms": {"min": min(ages), "max": max(ages), "mean": sum(ages) / len(ages)} if ages else None,
            "hardware_link_observed": self.counts["accepted_hardware_good"] > 0,
            "full_gateway_validation": "not_established_by_a_traffic_capture_alone",
            "clock_assumptions": "Receiver UTC is the PC system clock. Freshness checks publisher UTC and reported age against that clock; no independent clock-offset or NTP accuracy measurement.",
            "identity_scope": "Hardware source and 32-hex boot identity are payload declarations, not cryptographic device attestation. This subscriber cannot prove physical origin against a deliberate forged publisher.",
            "crc_scope": "Modbus CRC is checked by the ESP32 firmware; this capture observes MQTT JSON, not RS485 wire bytes.",
        }

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 600:
        parser.error("--seconds must be between 1 and 600")
    import paho.mqtt.client as mqtt
    run_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    directory = args.output_root.resolve() / run_id
    directory.mkdir(parents=True, exist_ok=False)
    state = EvidenceState()
    connected = False
    failure = None
    started = utc_now()
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="hardware-evidence-" + uuid.uuid4().hex[:12], protocol=mqtt.MQTTv311)
    client.connect_timeout = 5.0

    def on_connect(instance, _userdata, _flags, reason, _properties):
        nonlocal connected, failure
        connected = not reason.is_failure
        if connected:
            instance.subscribe(PREFIX + "+", qos=1)
        else:
            failure = "mqtt_connect_rejected"

    with (directory / "messages.jsonl").open("x", encoding="utf-8") as output:
        def on_message(_instance, _userdata, message):
            received = datetime.now(timezone.utc)
            text = message.payload.decode("utf-8", errors="replace")
            try:
                payload = json.loads(text) if message.topic != PREFIX + "availability" else text
            except (ValueError, TypeError):
                payload = None
            result = state.observe(message.topic, payload, bool(message.retain), received.timestamp() * 1000)
            output.write(json.dumps({
                "received_at_utc": received.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
                "topic": message.topic, "qos": message.qos, "retained": bool(message.retain),
                "payload_text": text, "payload_hex": message.payload.hex(), "validation": result,
            }, allow_nan=False) + "\n")
            output.flush()

        client.on_connect = on_connect
        client.on_message = on_message
        try:
            client.connect("127.0.0.1", 1883, keepalive=15)
            deadline = time.monotonic() + args.seconds
            while time.monotonic() < deadline:
                result = client.loop(timeout=min(0.25, max(0.01, deadline - time.monotonic())))
                if result != mqtt.MQTT_ERR_SUCCESS:
                    failure = "mqtt_loop_error_" + str(result)
                    break
        except KeyboardInterrupt:
            failure = "interrupted"
        except (OSError, ValueError) as error:
            failure = type(error).__name__
        finally:
            client.disconnect()

    summary = {"schema_version": 1, "capture_run_id": run_id, "started_at_utc": started,
               "finished_at_utc": utc_now(), "requested_seconds": args.seconds,
               "mqtt_endpoint": "127.0.0.1:1883", "connected": connected, "capture_error": failure, **state.summary()}
    (directory / "summary.json").write_text(json.dumps(summary, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps({"evidence_directory": str(directory), "counts": summary["counts"],
                      "hardware_link_observed": summary["hardware_link_observed"], "capture_error": failure}))
    return 0 if summary["hardware_link_observed"] and failure is None else 2

if __name__ == "__main__":
    raise SystemExit(main())
