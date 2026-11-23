"""Create a simulator that the active Xcode can launch tests on."""

import json
import os
import subprocess
import sys


def version_parts(version):
    return tuple(int(part) for part in version.split("."))


def main(name, device):
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True
    ).strip()
    runtimes = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "runtimes", "--json"]
    ))["runtimes"]
    # simctl's default can come from a newer Xcode installed on the same runner.
    ceiling = version_parts(sdk)[:2]
    candidates = [
        runtime for runtime in runtimes
        if runtime["platform"] == "iOS" and runtime["isAvailable"]
        and version_parts(runtime["version"])[:2] <= ceiling
        and any(device in (model["name"], model.get("identifier"))
                for model in runtime["supportedDeviceTypes"])
    ]
    if not candidates:
        sys.exit(f"No available iOS runtime at or below SDK {sdk} supports {device}")
    runtime = max(candidates, key=lambda item: version_parts(item["version"]))
    print(f"Using {runtime['identifier']} for {device} with SDK {sdk}", file=sys.stderr)
    os.execlp("xcrun", "xcrun", "simctl", "create", name, device, runtime["identifier"])


if __name__ == "__main__":
    main(*sys.argv[1:])
