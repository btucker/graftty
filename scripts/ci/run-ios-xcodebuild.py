#!/usr/bin/env python3
"""Bound a silent xcodebuild startup without timing out a running test."""

import os
import select
import signal
import subprocess
import sys


def run(command, startup_timeout):
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          start_new_session=True) as process:
        try:
            output = process.stdout.fileno()
            if not select.select([output], [], [], startup_timeout)[0]:
                print(f"::warning::xcodebuild produced no startup output within {startup_timeout} seconds",
                      flush=True)
                return 124

            while chunk := os.read(output, 65536):
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
            status = process.wait()
            return status if status >= 0 else 128 - status
        finally:
            if process.returncode is None:
                # A descendant that inherited the pipe can also stall startup.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    # On hosted runners the cold unit batch can take nearly three minutes
    # to emit its first line even when it completes successfully.
    timeout = int(os.environ.get("IOS_XCODEBUILD_STARTUP_TIMEOUT_SECONDS", "300"))
    sys.exit(run(sys.argv[1:], timeout))
