"""Run the real local host stack and record evidence. No ESP32/RS485 is involved."""
import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
from urllib.request import urlopen

PROJECT = Path(__file__).resolve().parents[1]


def utc():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-root", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=600)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    runtime, output = args.runtime_root.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if args.seconds < 10:
        parser.error("--seconds must be at least 10")
    for port in (1880, 1883, 1502):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", port))
    processes, handles, results = {}, [], []
    report = {"started_at_utc": utc(), "source_mode": "simulated", "validation_scope": "Host software only; no ESP32, UART, RTU or electrical RS485 validation.",
              "clock_assumption": "Publisher and receiver use the same OS UTC clock; no independent NTP validation.",
              "requested_normal_run_seconds": args.seconds, "results": results, "status": "running"}
    observations = (output / "observations.jsonl").open("w", encoding="utf-8")

    def note(event, **fields):
        item = {"event": event, "at_utc": utc(), **fields}
        print(json.dumps(item), flush=True)
        observations.write(json.dumps(item) + "\n")
        observations.flush()

    def start(name, command):
        out = (output / (name + ".stdout.log")).open("a", encoding="utf-8")
        err = (output / (name + ".stderr.log")).open("a", encoding="utf-8")
        handles.extend((out, err))
        processes[name] = subprocess.Popen([str(x) for x in command], cwd=PROJECT,
            stdout=out, stderr=err, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        note("component_started", component=name)

    def stop(name, *, force=False):
        p = processes.pop(name, None)
        if p is not None:
            if p.poll() is None:
                p.kill() if force else p.terminate()
            p.wait(timeout=8)
        note("component_stopped", component=name, forced=force)

    def state():
        with urlopen("http://127.0.0.1:1880/api/state", timeout=2) as response:
            return json.load(response)

    def wait_for(predicate, timeout=15):
        end, last = time.monotonic() + timeout, None
        while time.monotonic() < end:
            try:
                last = state()
                if predicate(last):
                    return last
            except (OSError, ValueError):
                pass
            time.sleep(.2)
        raise AssertionError("State condition timed out: " + json.dumps(last))

    def check(name, condition, **details):
        if not condition:
            raise AssertionError(name + ": " + json.dumps(details))
        results.append({"name": name, "status": "passed", **details})
        note("check_passed", name=name, **details)

    python = runtime / "python-env/Scripts/python.exe"
    broker = [runtime / "mosquitto/mosquitto.exe", "-c", PROJECT / "config/mosquitto.local.conf"]
    simulator = [python, "-u", "-m", "host.simulator"]
    gateway = [python, "-u", "-m", "host.gateway", "--trust-system-clock", "--log", output / "gateway.events.jsonl"]
    try:
        start("broker", broker)
        start("dashboard", [shutil.which("node"), runtime / "node-red/node_modules/node-red/red.js",
              "--userDir", runtime / "node-red", "--settings", PROJECT / "dashboard/settings.cjs"])
        start("simulator", simulator)
        time.sleep(1)
        start("gateway", gateway)
        healthy = lambda s: s["broker_state"] == "connected" and s["gateway_state"] == "online" and s["source_state"] == "healthy" and s["measurement_state"] == "fresh"
        s = wait_for(healthy, 30)
        check("full_stack_reaches_fresh_online", s["source_mode"] == "simulated")
        baseline_good = s["counters"]["good"]
        started, last_progress = time.monotonic(), 0
        observed, temperatures, humidities = 0, set(), set()
        max_age = 0
        while time.monotonic() - started < args.seconds:
            s = state()
            assert healthy(s), "Unexpected state during normal run: " + json.dumps(s)
            assert all(p.poll() is None for p in processes.values()), "A component exited"
            observed += 1
            max_age = max(max_age, s["sample_age_ms"])
            temperatures.add(s["values"]["temperature_c"])
            humidities.add(s["values"]["humidity_pct"])
            elapsed = time.monotonic() - started
            if elapsed - last_progress >= 30:
                note("normal_run_progress", elapsed_seconds=round(elapsed, 1), good=s["counters"]["good"], age_ms=s["sample_age_ms"])
                last_progress = elapsed
            time.sleep(1)
        duration = time.monotonic() - started
        check("normal_run", len(temperatures) > 2 and len(humidities) > 2,
              elapsed_seconds=round(duration, 3), snapshots=observed, new_good_samples=s["counters"]["good"]-baseline_good,
              distinct_temperatures=len(temperatures), distinct_humidities=len(humidities), maximum_sample_age_ms=max_age)
        (output / "normal-state.json").write_text(json.dumps(s, indent=2), encoding="utf-8")

        cut = time.monotonic()
        stop("simulator")
        failed = wait_for(lambda x: x["source_state"] == "error", 6)
        error_after = time.monotonic()-cut
        # A final in-flight good sample can arrive between the normal-loop
        # snapshot and source termination. Freeze the comparison only after
        # the receiver has observed the failed read.
        preserved, preserved_sample = failed["values"], failed["last_sample"]
        check("source_failure_separate_from_gateway", failed["gateway_state"] == "online" and preserved is not None and preserved_sample is not None,
              detection_seconds=round(error_after, 3))
        stale = wait_for(lambda x: x["measurement_state"] == "stale", 12)
        check("source_stale_without_new_good_data", stale["values"] == preserved and stale["last_sample"] == preserved_sample and stale["sample_age_ms"] > 10000,
              observed_age_ms=stale["sample_age_ms"], seconds_since_source_stop=round(time.monotonic()-cut, 3))
        restored = time.monotonic()
        start("simulator", simulator)
        recovered = wait_for(healthy, 10)
        check("source_recovers", True, recovery_seconds=round(time.monotonic()-restored, 3))

        # Known values cross the actual Modbus socket and MQTT path.
        stop("simulator")
        fixture = output / "source-state.json"
        def set_value(t, h):
            staging = fixture.with_suffix(".tmp")
            staging.write_text(json.dumps({"temperature_c": t, "humidity_pct": h}), encoding="utf-8")
            staging.replace(fixture)
        set_value(-5.2, 48.7)
        start("simulator", simulator + ["--state-file", fixture])
        for name, t, h in (("negative_value", -5.2, 48.7), ("zero_is_valid", 0, 0), ("positive_value", 23.4, 62.5)):
            before_seq = state()["last_sample"]["seq"]
            set_value(t, h)
            exact = wait_for(lambda x: healthy(x) and x["last_sample"]["seq"] > before_seq and x["values"] == {"temperature_c":t, "humidity_pct":h}, 10)
            check(name, exact["measurement_state"] == "fresh", values=exact["values"])

        # Restart broker; polling must continue while MQTT is absent.
        def reads():
            return sum(1 for line in (output / "gateway.events.jsonl").read_text(encoding="utf-8").splitlines() if '"event":"source_sample"' in line)
        stop("broker")
        disconnected = wait_for(lambda x: x["broker_state"] == "disconnected", 8)
        check("broker_loss_not_reported_online", disconnected["gateway_state"] == "unknown")
        before_reads = reads()
        time.sleep(7)
        during_reads = reads() - before_reads
        check("source_polling_continues_without_broker", during_reads >= 2, source_reads_during_outage=during_reads)
        restored = time.monotonic()
        before_good = disconnected["counters"]["good"]
        start("broker", broker)
        recovered = wait_for(lambda x: healthy(x) and x["counters"]["good"] > before_good, 30)
        check("broker_recovers_with_fresh_data", recovered["sample_age_ms"] < 10000,
              recovery_seconds=round(time.monotonic()-restored, 3), age_ms=recovered["sample_age_ms"])

        old_boot = recovered["last_sample"]["boot_id"]
        cut = time.monotonic()
        stop("gateway", force=True)
        wait_for(lambda x: x["gateway_state"] == "offline", 20)
        check("abrupt_gateway_stop_emits_lwt", True, detection_seconds=round(time.monotonic()-cut, 3))
        start("gateway", gateway)
        new = wait_for(lambda x: healthy(x) and x["last_sample"]["boot_id"] != old_boot, 15)
        check("gateway_restart_new_session", new["last_sample"]["boot_id"] != old_boot)
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["failure"] = type(error).__name__ + ": " + str(error)
        note("failure", error=report["failure"])
    finally:
        for name in list(processes)[::-1]:
            try:
                stop(name)
            except Exception as error:
                note("cleanup_error", component=name, error=str(error))
        report["finished_at_utc"] = utc()
        (output / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        observations.close()
        for handle in handles:
            handle.close()
    print(json.dumps({"status":report["status"], "report":str(output / "report.json")}), flush=True)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
