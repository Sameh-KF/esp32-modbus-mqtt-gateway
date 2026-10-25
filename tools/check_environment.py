"""Report common local tools without installing software or modifying settings."""

from __future__ import annotations

import importlib.util
import json
import os
import platform
import shutil
import subprocess
import sys


def command_status(names: tuple[str, ...], version_args: tuple[str, ...]) -> dict:
    executable = next((path for name in names if (path := shutil.which(name))), None)
    if executable is None:
        return {"found_on_path": False}
    result = {"found_on_path": True}
    try:
        completed = subprocess.run(
            [executable, *version_args], capture_output=True, text=True,
            timeout=8, check=False,
        )
        lines = (completed.stdout or completed.stderr).strip().splitlines()
        result["version_output"] = lines[0][:200] if lines else None
        result["version_probe_exit_code"] = completed.returncode
    except (OSError, subprocess.TimeoutExpired) as exc:
        result["version_probe_error"] = type(exc).__name__
    return result


def module_present(name: str) -> bool:
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ModuleNotFoundError, ValueError):
        return False


def main() -> None:
    report = {
        "scope": "Read-only PATH and current-Python checks; not a full disk inventory",
        "operating_system": platform.system(),
        "python_version": platform.python_version(),
        "tools": {
            "node": command_status(("node",), ("--version",)),
            "npm": command_status(("npm.cmd", "npm"), ("--version",)),
            "git": command_status(("git",), ("--version",)),
            "vscode": command_status(("code.cmd", "code"), ("--version",)),
            "esp_idf": command_status(("idf.py",), ("--version",)),
            "mosquitto": command_status(("mosquitto",), ("-h",)),
            "node_red": command_status(("node-red.cmd", "node-red"), ("--version",)),
        },
        "idf_path_variable_set": bool(os.environ.get("IDF_PATH")),
        "python_packages": {
            "pymodbus": module_present("pymodbus"),
            "paho_mqtt": module_present("paho.mqtt"),
        },
    }
    json.dump(report, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
