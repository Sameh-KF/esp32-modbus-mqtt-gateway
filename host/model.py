"""Synthetic fixture conversion and telemetry; not the Hailege register map."""

from datetime import datetime, timezone
import math
import threading
import time


def encode_registers(temperature_c, humidity_pct):
    """Synthetic FC03 map: register 0 signed tenths C, register 1 tenths %."""
    for value in (temperature_c, humidity_pct):
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError("values must be finite numbers")
    temperature = round(temperature_c * 10)
    humidity = round(humidity_pct * 10)
    if not -32768 <= temperature <= 32767 or not 0 <= humidity <= 1000:
        raise ValueError("value outside synthetic register range")
    return [temperature & 0xFFFF, humidity]


def decode_registers(registers):
    if not isinstance(registers, (list, tuple)) or len(registers) != 2 or any(isinstance(v, bool) or not isinstance(v, int) or not 0 <= v <= 0xFFFF for v in registers):
        raise ValueError("invalid synthetic registers")
    temperature, humidity = registers
    if humidity > 1000:
        raise ValueError("humidity outside synthetic range")
    if temperature & 0x8000:
        temperature -= 0x10000
    return {"temperature_c": temperature / 10, "humidity_pct": humidity / 10}


def telemetry(*, device_id, boot_id, seq, slave_id, started, values=None,
              error=None, trust_system_clock=False, now_monotonic=None, now_utc=None):
    now_monotonic = time.monotonic() if now_monotonic is None else now_monotonic
    good = error is None and values is not None
    capture_time = (now_utc or datetime.now(timezone.utc)).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    return {
        "schema_version": 1, "device_id": device_id, "source_mode": "simulated",
        "boot_id": boot_id, "seq": seq, "slave_id": slave_id,
        "uptime_ms": max(0, round((now_monotonic - started) * 1000)),
        "sample_ts_utc": capture_time if good and trust_system_clock else None,
        "time_valid": bool(good and trust_system_clock),
        "sample_age_ms": 0 if good else None,
        "quality": "good" if good else "bad",
        "values": values if good else None,
        "error": None if good else (error or "modbus_invalid_response"),
    }


class LatestSample:
    """One application slot, shared by source polling and broker worker."""

    def __init__(self):
        self.lock = threading.Lock()
        self.latest = None
        self.consumed_seq = -1
        self.last_good_monotonic = None
        self.counts = {"read_success_count": 0, "read_error_count": 0,
                       "mqtt_connection_attempts": 0, "mqtt_connection_count": 0,
                       "mqtt_disconnect_count": 0, "dropped_messages_count": 0,
                       "expired_messages_count": 0}

    def offer(self, sample):
        with self.lock:
            if self.latest is not None and self.latest["seq"] > self.consumed_seq:
                self.counts["dropped_messages_count"] += 1
            self.latest = sample
            if sample["quality"] == "good":
                self.counts["read_success_count"] += 1
                self.last_good_monotonic = time.monotonic()
            else:
                self.counts["read_error_count"] += 1

    def snapshot(self):
        with self.lock:
            return None if self.latest is None else dict(self.latest)

    def consumed(self, seq):
        with self.lock:
            self.consumed_seq = max(seq, self.consumed_seq)

    def increment(self, key):
        with self.lock:
            self.counts[key] += 1

    def diagnostics(self, started, boot_id, device_id):
        with self.lock:
            return {"schema_version": 1, "source_mode": "simulated",
                    "device_id": device_id, "boot_id": boot_id,
                    "uptime_ms": round((time.monotonic() - started) * 1000),
                    "last_successful_sample_age_ms": None if self.last_good_monotonic is None else round((time.monotonic() - self.last_good_monotonic) * 1000),
                    **self.counts}
