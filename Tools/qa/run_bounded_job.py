#!/usr/bin/env python3
"""Run one owned QA job with a disk log, timeout, and cleanup evidence."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--resource", type=Path, required=True)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    args.log.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    with args.log.open("w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        resource = {"name": args.name, "pid": process.pid, "runner_pid": os.getpid(), "project": str(Path.cwd()), "command": command,
                    "log": str(args.log), "stop_condition": f"completion or {args.timeout:g} seconds", "status": "running"}
        args.resource.write_text(json.dumps(resource, indent=2) + "\n")
        print(json.dumps({"pid": process.pid, "resource": str(args.resource)}), flush=True)
        try:
            code = process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            # All descendants belong to the new group created for this job.
            listing = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
            parents = {int(row.split()[0]): int(row.split()[1]) for row in listing.splitlines()}
            children = []
            def collect(parent):
                for child, owner in parents.items():
                    if owner == parent:
                        collect(child)
                        children.append(child)
            collect(process.pid)
            for pid in [*children, process.pid]:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
            code = 124
        resource.update(status="exited", exit_code=code, elapsed_seconds=round(time.monotonic() - started, 3))
        args.resource.write_text(json.dumps(resource, indent=2) + "\n")
    print(json.dumps({"exit_code": code, "elapsed_seconds": resource["elapsed_seconds"], "log": str(args.log)}), flush=True)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
