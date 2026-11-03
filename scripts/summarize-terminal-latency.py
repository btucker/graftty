#!/usr/bin/env python3
"""Extract numeric WebRTC echo measurements from an xcodebuild test log."""

import argparse
import json
import math
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--output", type=Path, help="Write a JSON report instead of stdout")
    args = parser.parse_args()
    cases = []
    completed = False
    expected = {"idle", "sharedConnection", "separateDataChannel", "separateConnection"}
    try:
        with args.log.open(encoding="utf-8", errors="replace") as log:
            for line in log:
                if "** TEST SUCCEEDED **" in line or "** TEST EXECUTE SUCCEEDED **" in line:
                    completed = True
                marker = "[terminal-latency] "
                if marker not in line:
                    continue
                record = json.loads(line.split(marker, 1)[1])
                if record["scenario"] not in expected:
                    raise ValueError("Unknown latency scenario")
                echo = record["echo"]
                values = [echo[key] for key in (
                    "p50Milliseconds", "p95Milliseconds", "p99Milliseconds", "maxMilliseconds"
                )]
                if echo["sampleCount"] < 1 or any(not math.isfinite(value) or value < 0 for value in values) or values != sorted(values):
                    raise ValueError("Invalid latency summary")
                cases.append(record)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    if not cases:
        parser.error("No JSON terminal-latency measurements found; check that the probe actually ran")
    if not completed or {case["scenario"] for case in cases} != expected:
        parser.error("Expected a successful xcodebuild run with all four latency scenarios")
    report = {"schemaVersion": 1, "measurement": "ssh-webrtc-transport-echo", "cases": cases}
    try:
        encoded = json.dumps(report, indent=2, allow_nan=False) + "\n"
        if args.output:
            args.output.write_text(encoded, encoding="utf-8")
            print(f"Wrote {len(cases)} scenario measurements to {args.output}")
        else:
            print(encoded, end="")
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
