#!/usr/bin/env python3
"""Run disjoint Swift Testing batches and target-qualified XCTest processes."""
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time

from test_plan import mac_filters, verify_swift_results, verify_xctest_results


def swift_testing_runners(test_ids):
    """Use the installed SwiftPM runner without reloading the graph per batch.

    CI already built these products in its dedicated directory. Keep discovery
    through SwiftPM and retain its macOS runtime library search paths.
    """
    products = Path(".build/debug").resolve(strict=True)
    modules = sorted({identifier.split(".", 1)[0] for identifier in test_ids
                      if not identifier.startswith("OwnershipModelTests.")})
    aggregate = "GrafttyPackageTests"
    # The Swift build engine emits a bundle per target. Prefer those products
    # over any cached aggregate, and require every discovered module's bundle.
    per_target = any(bundle.stem != aggregate for bundle in products.glob("*.xctest"))
    names = {module: module for module in modules} if per_target else {None: aggregate}
    binaries = {module: (products / f"{name}.xctest/Contents/MacOS/{name}").resolve(strict=True)
                for module, name in names.items()}
    swift = Path(subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip())
    helper = swift.parent.parent / "libexec/swift/pm/swiftpm-testing-helper"
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise FileNotFoundError(f"SwiftPM test helper is unavailable: {helper}")
    platform = Path(subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], text=True).strip())
    environment = {}
    for key, paths in (("DYLD_FRAMEWORK_PATH", (platform / "Developer/Library/Frameworks",
                                               platform / "Developer/Library/PrivateFrameworks")),
                       ("DYLD_LIBRARY_PATH", (products, platform / "Developer/usr/lib"))):
        value = ":".join(filter(None, (os.environ.get(key), *(str(path) for path in paths))))
        environment[key] = value
    # /usr/bin/script strips inherited DYLD_* under SIP. Set these in its
    # child, after creating the PTY, as SwiftPM does before starting the helper.
    return {module: [sys.executable, str(Path(__file__).resolve()), "--swift-testing-batch", json.dumps(environment),
                     str(helper), "--test-bundle-path", str(binary), "--testing-library", "swift-testing"]
            for module, binary in binaries.items()}


def capture_timeout_sample(pid, command):
    """Keep native stacks beside the batch's other uploaded diagnostics."""
    directory = Path(".ci-results/macos")
    if "--attachments-path" in command:
        directory = Path(command[command.index("--attachments-path") + 1])
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"runner-timeout-{pid}.sample.txt"
    try:
        subprocess.run(["/usr/bin/sample", str(pid), "1", "1", "-file", str(path)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, timeout=10, check=True)
    except (OSError, subprocess.SubprocessError) as error:
        if not path.exists():
            path.write_text(f"Could not sample timed-out helper: {error}\n")


def run_swift_testing_batch(command, environment, *, timeout_seconds=180):
    """Bound native hangs independently of Swift's cooperative test deadlines."""
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)

    process = None
    completed = False
    output_fd = sys.stdout.fileno()
    output_was_blocking = os.get_blocking(output_fd)
    previous_sigterm = signal.signal(signal.SIGTERM, terminate)
    try:
        process = subprocess.Popen(command, env={**os.environ, **environment},
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        process.stdin.close()
        os.set_blocking(output_fd, False)
        deadline = time.monotonic() + timeout_seconds
        pending = b""
        ended = False
        while pending or not ended:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, timeout_seconds)
            readable, writable, _ = select.select(
                [process.stdout] if not pending and not ended else [],
                [output_fd] if pending else [], [], remaining)
            if writable:
                try:
                    pending = pending[os.write(output_fd, pending):]
                except BlockingIOError:
                    pass
            if readable:
                pending = os.read(process.stdout.fileno(), 65536)
                ended = not pending
        status = process.wait(timeout=max(0, deadline - time.monotonic()))
        completed = True
        return status if status >= 0 else 128 - status
    except subprocess.TimeoutExpired:
        # stderr may share the same full PTY as stdout. Diagnostics must not
        # wait behind a blocked logger before sampling and killing the helper.
        error_fd = sys.stderr.fileno()
        error_was_blocking = os.get_blocking(error_fd)
        try:
            os.set_blocking(error_fd, False)
            os.write(error_fd, f"Swift test batch exceeded {timeout_seconds}s; capturing native stacks before termination\n".encode())
        except OSError:
            pass
        finally:
            os.set_blocking(error_fd, error_was_blocking)
        capture_timeout_sample(process.pid, command)
        return 124
    finally:
        if process is not None:
            # A helper may leave children holding stdout open after it exits.
            # Only this helper's fresh process group belongs to this launcher.
            if not completed:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait()
            process.stdout.close()
        signal.signal(signal.SIGTERM, previous_sigterm)
        os.set_blocking(output_fd, output_was_blocking)


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
    testing_runners = swift_testing_runners(inventory)
    result_paths = []
    with open(os.devnull) as stdin:
        for index, pattern in enumerate(filters, 1):
            print(f"::group::Swift Testing batch {index}/{len(filters)}", flush=True)
            for module, command in testing_runners.items():
                if module is not None and not any(identifier.startswith(module + ".") and re.search(pattern, identifier)
                                                  for identifier in inventory):
                    continue
                name = f"swift-{index}" + (f"-{module}" if module is not None else "")
                result = evidence / f"{name}.xml"
                attachments = evidence / "attachments" / name
                attachments.mkdir(parents=True, exist_ok=True)
                subprocess.run(["/usr/bin/script", "-q", str(evidence / f"{name}.log"), *command,
                                "--no-parallel", "--filter", pattern,
                                "--attachments-path", str(attachments),
                                "--xunit-output", str(result)], stdin=stdin, check=True)
                result_paths.append(result)
            print("::endgroup::", flush=True)
        verified = verify_swift_results(inventory, result_paths)
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
    if sys.argv[1:2] == ["--swift-testing-batch"]:
        sys.exit(run_swift_testing_batch(sys.argv[3:], json.loads(sys.argv[2])))
    main()
