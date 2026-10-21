#!/usr/bin/env python3
"""Run disjoint Swift Testing batches and target-qualified XCTest processes."""
import json
import os
from pathlib import Path
import re
import subprocess

from test_plan import mac_filters, verify_swift_results, verify_xctest_results


def main():
    swift = ["swift", "test", "-Xcc", os.environ["GRAFTTY_RENDERER_CONTEXT"], "--skip-build"]
    inventory = subprocess.check_output(
        ["swift", "test", "list", "-Xcc", os.environ["GRAFTTY_RENDERER_CONTEXT"],
         "--skip-build", "--disable-xctest"], text=True).splitlines()
    inventory = [line.strip() for line in inventory if line.strip()]
    filters = mac_filters(inventory)
    xctest_inventory = subprocess.check_output(
        ["swift", "test", "list", "-Xcc", os.environ["GRAFTTY_RENDERER_CONTEXT"],
         "--skip-build", "--disable-swift-testing"], text=True).splitlines()
    xctest_inventory = [line.strip() for line in xctest_inventory if line.strip()]
    package = json.loads(subprocess.check_output(["swift", "package", "describe", "--type", "json"], text=True))
    targets = sorted(target["c99name"] for target in package["targets"]
                     if target["type"] == "test" and target["name"] != "OwnershipModelTests")
    evidence = Path(".ci-results/macos")
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / "test-plan.json").write_text(json.dumps(
        {"discoveredSwiftTests": inventory, "swiftFilters": filters,
         "discoveredXCTests": xctest_inventory, "xctestTargets": targets}, indent=2) + "\n")
    with open(os.devnull) as stdin:
        for index, pattern in enumerate(filters, 1):
            print(f"::group::Swift Testing batch {index}/{len(filters)}", flush=True)
            subprocess.run(["/usr/bin/script", "-q", str(evidence / f"swift-{index}.log"), *swift,
                            "--disable-xctest", "--no-parallel", "--filter", pattern,
                            "--xunit-output", str(evidence / f"swift-{index}.xml")],
                           stdin=stdin, check=True)
            print("::endgroup::", flush=True)
        verified = verify_swift_results(inventory, [evidence / f"swift-{i}.xml" for i in range(1, len(filters) + 1)])
        (evidence / "verified-swift-tests.json").write_text(json.dumps(verified, indent=2) + "\n")
        for target in targets:
            print(f"::group::XCTest {target}", flush=True)
            subprocess.run(["/usr/bin/script", "-q", str(evidence / f"xctest-{target}.log"), *swift,
                            "--disable-swift-testing", "--filter", "^" + re.escape(target) + r"\."],
                           stdin=stdin, check=True)
            print("::endgroup::", flush=True)
        verified_xctests = verify_xctest_results(
            xctest_inventory, [evidence / f"xctest-{target}.log" for target in targets])
        (evidence / "verified-xctests.json").write_text(json.dumps(verified_xctests, indent=2) + "\n")


if __name__ == "__main__":
    main()
