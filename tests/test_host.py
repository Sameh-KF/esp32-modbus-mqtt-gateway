"""Meaningful host model/transport tests; no hardware is involved."""

from datetime import datetime, timezone
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host.model import LatestSample, decode_registers, encode_registers, telemetry
from host.gateway import read_values


class FakeResponse:
    def __init__(self, registers, error=False):
        self.registers, self.error = registers, error

    def isError(self):
        return self.error


class FakeClient:
    connected = True

    def __init__(self, response):
        self.response = response

    def read_holding_registers(self, address, *, count, device_id):
        assert (address, count, device_id) == (0, 2, 1)
        return self.response


class HostTests(unittest.TestCase):
    def test_zero_and_negative_are_valid(self):
        for temperature in (-3276.8, -40, -5.2, 0, 23.7, 3276.7):
            self.assertEqual(decode_registers(encode_registers(temperature, 48.7)),
                             {"temperature_c": temperature, "humidity_pct": 48.7})

    def test_invalid_registers_and_humidity_are_rejected(self):
        for values in (None, {0: 10, 1: 20}, [0], [0, 1001], [True, 10], [0.0, 10], [-1, 10], [65536, 10]):
            with self.subTest(values=values), self.assertRaises(ValueError):
                decode_registers(values)
        for values in ((float("nan"), 50), (0, 101), (0, -1), (True, 50), (3276.8, 50)):
            with self.subTest(values=values), self.assertRaises(ValueError):
                encode_registers(*values)

    def test_read_exception_never_becomes_zero_measurement(self):
        self.assertEqual(read_values(FakeClient(FakeResponse([0, 0], error=True)), 1), (None, "modbus_exception"))
        self.assertEqual(read_values(FakeClient(FakeResponse([0])), 1), (None, "modbus_invalid_response"))
        self.assertEqual(read_values(FakeClient(FakeResponse([0, 0])), 1), ({"temperature_c": 0.0, "humidity_pct": 0.0}, None))

    def test_payload_truth_and_explicit_clock_assumption(self):
        args = dict(device_id="gw-01", boot_id="test", seq=2, slave_id=1, started=10,
                    now_monotonic=12, now_utc=datetime(2026, 10, 19, tzinfo=timezone.utc))
        good = telemetry(**args, values={"temperature_c": 0, "humidity_pct": 0})
        self.assertEqual(good["source_mode"], "simulated")
        self.assertEqual(good["quality"], "good")
        self.assertFalse(good["time_valid"])
        self.assertIsNone(good["sample_ts_utc"])
        trusted = telemetry(**args, values=good["values"], trust_system_clock=True)
        self.assertTrue(trusted["time_valid"])
        self.assertEqual(trusted["sample_ts_utc"], "2026-10-19T00:00:00.000Z")
        bad = telemetry(**args, values=good["values"], error="modbus_timeout", trust_system_clock=True)
        self.assertIsNone(bad["values"])
        self.assertIsNone(bad["sample_ts_utc"])
        self.assertFalse(bad["time_valid"])
        self.assertEqual(bad["error"], "modbus_timeout")

    def test_latest_slot_is_bounded_and_counts_drops(self):
        slot = LatestSample()
        for seq in range(100):
            slot.offer({"seq": seq, "quality": "good"})
        self.assertEqual(slot.snapshot()["seq"], 99)
        self.assertEqual(slot.counts["dropped_messages_count"], 99)
        slot.consumed(99)
        slot.offer({"seq": 100, "quality": "bad"})
        self.assertEqual(slot.counts["dropped_messages_count"], 99)
        self.assertEqual(slot.counts["read_error_count"], 1)


if __name__ == "__main__":
    unittest.main()
