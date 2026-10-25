"""Local synthetic Modbus TCP source. Its map MUST NOT be used for Hailege."""

import argparse
import asyncio
import json
import math
from pathlib import Path
import time

from pymodbus.constants import ExcCodes
from pymodbus.simulator import DataType, SimData, SimDevice
from pymodbus.server import StartAsyncTcpServer

try:
    from .model import encode_registers
except ImportError:
    from model import encode_registers


async def run(args):
    started = time.monotonic()
    last_error = None

    async def update(function_code, start_address, address, count, current_registers, set_values):
        nonlocal last_error
        if function_code != 3 or set_values is not None:
            return ExcCodes.ILLEGAL_FUNCTION
        if address < 0 or address + count > 2:
            return ExcCodes.ILLEGAL_ADDRESS
        try:
            if args.state_file:
                state = json.loads(Path(args.state_file).read_text(encoding="utf-8-sig"))
                values = encode_registers(state["temperature_c"], state["humidity_pct"])
            else:
                elapsed = time.monotonic() - started
                values = encode_registers(25, 60)
            current_registers[-start_address:2 - start_address] = values
            last_error = None
        except (OSError, ValueError, KeyError, TypeError) as error:
            reason = f"{type(error).__name__}: {error}"
            if reason != last_error:
                print(json.dumps({"event": "state_error", "error": reason, "behavior": "return_device_failure", "source_mode": "simulated"}), flush=True)
            last_error = reason
            return ExcCodes.DEVICE_FAILURE
        return None

    context = SimDevice(args.device_id, SimData(0, values=[0, 500], datatype=DataType.REGISTERS, readonly=True), action=update)
    print(json.dumps({"event": "simulator_start", "source_mode": "simulated", "host": args.host, "port": args.port,
                      "device_id": args.device_id, "map": "SYNTHETIC ONLY: FC03, address0 signed16 x0.1 C, address1 unsigned16 x0.1 %; NOT Hailege"}), flush=True)
    await StartAsyncTcpServer(context=context, address=(args.host, args.port))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=1502)
    parser.add_argument("--device-id", type=int, default=1)
    parser.add_argument("--state-file", help='Optional JSON: {"temperature_c": -5.2, "humidity_pct": 48.7}')
    args = parser.parse_args()
    if not 1 <= args.device_id <= 247 or not 0 < args.port <= 65535:
        parser.error("invalid device id or port")
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
