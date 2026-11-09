#!/usr/bin/env python3
"""Run one CI preparation command with a wall-clock deadline.

The child keeps stdout/stderr so callers can save JSON separately from logs.
Only this command's new process group is terminated on timeout.
"""
import argparse
import os
import signal
import subprocess
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("seconds", type=float)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.seconds <= 0 or not args.command:
        parser.error("provide a positive timeout and a command")
    started = time.monotonic()
    print(f"Starting preparation command (deadline {args.seconds:g}s): {' '.join(args.command)}", file=sys.stderr, flush=True)
    process = subprocess.Popen(args.command, start_new_session=True)
    try:
        code = process.wait(timeout=args.seconds)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        code = 124 if isinstance(error, subprocess.TimeoutExpired) else 130
        print(f"Preparation command stopped after {time.monotonic() - started:.1f}s (exit {code}).", file=sys.stderr, flush=True)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        return code
    print(f"Preparation command finished in {time.monotonic() - started:.1f}s (exit {code}).", file=sys.stderr, flush=True)
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    sys.exit(main())
