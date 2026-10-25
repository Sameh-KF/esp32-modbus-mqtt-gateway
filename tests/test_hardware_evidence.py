import copy
import unittest
from host.capture_hardware_evidence import EvidenceState, PREFIX, validate

NOW = 1792324800000.0
def payload(**changes):
    p = dict(schema_version=1,device_id="gw-01",source_mode="hardware",boot_id="a"*32,
             seq=1,slave_id=1,uptime_ms=2000,sample_ts_utc="2026-10-18T12:00:00.000Z",
             time_valid=True,sample_age_ms=0,quality="good",
             values={"temperature_c":26.0,"humidity_pct":54.4},error=None)
    p.update(changes)
    return p

class HardwareEvidenceTests(unittest.TestCase):
    def test_identity_and_required_types(self):
        self.assertIsNone(validate(payload()))
        for changes in ({"source_mode":"simulated"},{"boot_id":"fixture"},{"seq":True},
                        {"values":{"temperature_c":float("nan"),"humidity_pct":50}},
                        {"slave_id":0},{"sample_ts_utc":"2026-02-31T12:00:00.000Z"}):
            with self.subTest(changes=changes):
                self.assertIsNotNone(validate(payload(**changes)))

    def test_online_and_diagnostics_do_not_prove_hardware(self):
        s=EvidenceState()
        s.observe(PREFIX+"availability","online",True,NOW)
        s.observe(PREFIX+"diagnostics",{"source_mode":"hardware"},False,NOW)
        self.assertFalse(s.summary()["hardware_link_observed"])

    def test_fresh_good_duplicate_stale_and_retained(self):
        s=EvidenceState()
        self.assertTrue(s.observe(PREFIX+"telemetry",payload(),False,NOW)["accepted"])
        self.assertEqual(s.observe(PREFIX+"telemetry",payload(),False,NOW)["reason"],"duplicate_sequence")
        self.assertEqual(s.observe(PREFIX+"telemetry",payload(seq=2),True,NOW)["reason"],"retained_telemetry")
        self.assertEqual(s.observe(PREFIX+"telemetry",payload(seq=3),False,NOW+10001)["reason"],"sample_expired")
        self.assertEqual(s.summary()["counts"]["accepted_hardware_good"],1)

    def test_bad_and_unverified_never_count_good(self):
        s=EvidenceState()
        bad=payload(quality="bad",values=None,error="timeout",time_valid=False,
                    sample_ts_utc=None,sample_age_ms=None)
        self.assertTrue(s.observe(PREFIX+"telemetry",bad,False,NOW)["accepted"])
        self.assertFalse(s.observe(PREFIX+"telemetry",payload(seq=2,time_valid=False,
                         sample_ts_utc=None,sample_age_ms=None),False,NOW)["accepted"])
        self.assertFalse(s.summary()["hardware_link_observed"])
        self.assertEqual(s.summary()["counts"]["accepted_hardware_bad"],1)

    def test_future_and_reported_age_fail_conservatively(self):
        for p in (payload(sample_ts_utc="2026-10-18T12:00:03.000Z"),payload(sample_age_ms=10001)):
            s=EvidenceState()
            self.assertFalse(s.observe(PREFIX+"telemetry",p,False,NOW)["accepted"])
            self.assertFalse(s.summary()["hardware_link_observed"])

if __name__ == "__main__":
    unittest.main()
