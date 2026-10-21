#!/usr/bin/env python3
"""Run disjoint Swift Testing batches and target-qualified XCTest processes."""
import json
import os
from pathlib import Path
import re
import subprocess

from test_plan import mac_filters


def main():
    swift = ["swift", "test", "-Xcc", os.environ["GRAFTTY_RENDERER_CONTEXT"], "--skip-build"]
    inventory = subprocess.check_output(
        ["swift", "test", "list", "-Xcc", os.environ["GRAFTTY_RENDERER_CONTEXT"],
         "--skip-build", "--disable-xctest"], text=True).splitlines()
    inventory = [line.strip() for line in inventory if line.strip()]
    filters = mac_filters(inventory)
    package = json.loads(subprocess.check_output(["swift", "package", "describe", "--type", "json"], text=True))
    targets = sorted(target["c99name"] for target in package["targets"]
                     if target["type"] == "test" and target["name"] != "OwnershipModelTests")
    evidence = Path(".ci-results/macos")
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / "test-plan.json").write_text(json.dumps(
        {"discoveredSwiftTests": inventory, "swiftFilters": filters, "xctestTargets": targets}, indent=2) + "\n")
    with open(os.devnull) as stdin:
        for index, pattern in enumerate(filters, 1):
            print(f"::group::Swift Testing batch {index}/{len(filters)}", flush=True)
            subprocess.run(["/usr/bin/script", "-q", str(evidence / f"swift-{index}.log"), *swift,
                            "--disable-xctest", "--no-parallel", "--filter", pattern,
                            "--xunit-output", str(evidence / f"swift-{index}.xml")],
                           stdin=stdin, check=True)
            print("::endgroup::", flush=True)
        for target in targets:
            print(f"::group::XCTest {target}", flush=True)
            subprocess.run(["/usr/bin/script", "-q", str(evidence / f"xctest-{target}.log"), *swift,
                            "--disable-swift-testing", "--filter", "^" + re.escape(target) + r"\."],
                           stdin=stdin, check=True)
            print("::endgroup::", flush=True)


if __name__ == "__main__":
    main()
