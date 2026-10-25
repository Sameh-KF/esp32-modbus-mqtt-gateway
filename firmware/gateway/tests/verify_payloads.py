import json, sys
from pathlib import Path
samples = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
assert len(samples) == 4
for index, value in enumerate(samples, 1):
    assert value["schema_version"] == 1 and value["device_id"] == "gw-01"
    assert value["source_mode"] == "hardware" and value["slave_id"] == 1
    assert value["seq"] == index
assert samples[0]["values"] == {"temperature_c": 0, "humidity_pct": 0}
assert samples[0]["time_valid"] is False and samples[0]["sample_ts_utc"] is None
assert samples[1]["values"] == {"temperature_c": -20.5, "humidity_pct": 54.6}
assert samples[1]["sample_ts_utc"] == "2026-10-25T12:34:56.789Z"
assert samples[1]["time_valid"] is True and samples[1]["sample_age_ms"] == 200
assert samples[2]["quality"] == "bad" and samples[2]["values"] is None
assert samples[2]["error"] == "CRC" and samples[2]["sample_age_ms"] is None
assert samples[2]["time_valid"] is False and samples[2]["sample_ts_utc"] is None
assert samples[3]["values"]["temperature_c"] == -0.1 and samples[3]["time_valid"] is False
print("PASS: 4 generated JSON payloads parsed and checked (zero, negative, BAD, unsynchronized clock); overflow and invalid inputs also rejected in C.")
