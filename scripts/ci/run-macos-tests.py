#!/usr/bin/env python3
"""Run disjoint Swift Testing batches and target-qualified XCTest processes."""
import json
import os
from pathlib import Path
import re
import subprocess

from test_plan import mac_filters, verify_swift_results, verify_xctest_results


def swift_testing_runner():
    """Use the installed SwiftPM runner without reloading the graph per batch.

    CI already built these products in its dedicated directory. Keep discovery
    through SwiftPM and retain its macOS runtime library search paths.
    """
    products = Path(".build/debug").resolve(strict=True)
    binary = (products / "GrafttyPackageTests.xctest/Contents/MacOS/GrafttyPackageTests").resolve(strict=True)
    swift = Path(subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip())
    helper = swift.parent.parent / "libexec/swift/pm/swiftpm-testing-helper"
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise FileNotFoundError(f"SwiftPM test helper is unavailable: {helper}")
    platform = Path(subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], text=True).strip())
    environment = []
    for key, paths in (("DYLD_FRAMEWORK_PATH", (platform / "Developer/Library/Frameworks",
                                               platform / "Developer/Library/PrivateFrameworks")),
                       ("DYLD_LIBRARY_PATH", (products, platform / "Developer/usr/lib"))):
        value = ":".join(filter(None, (os.environ.get(key), *(str(path) for path in paths))))
        environment.append(f"{key}={value}")
    # /usr/bin/script strips inherited DYLD_* under SIP. Set these in its
    # child, after creating the PTY, as SwiftPM does before starting the helper.
    return ["/usr/bin/env", *environment, str(helper), "--test-bundle-path", str(binary),
            "--testing-library", "swift-testing"]


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
    targets = sorted({identifier.split(".", 1)[0] for identifier in xctest_inventory
                      if not identifier.startswith("OwnershipModelTests.")})
    evidence = Path(".ci-results/macos")
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / "test-plan.json").write_text(json.dumps(
        {"discoveredSwiftTests": inventory, "swiftFilters": filters,
         "discoveredXCTests": xctest_inventory, "xctestTargets": targets}, indent=2) + "\n")
    testing_runner = swift_testing_runner()
    with open(os.devnull) as stdin:
        for index, pattern in enumerate(filters, 1):
            print(f"::group::Swift Testing batch {index}/{len(filters)}", flush=True)
            subprocess.run(["/usr/bin/script", "-q", str(evidence / f"swift-{index}.log"), *testing_runner,
                            "--no-parallel", "--filter", pattern,
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
