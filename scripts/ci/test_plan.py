#!/usr/bin/env python3
"""Build complete, disjoint test selections from discovered identifiers."""
import argparse
from collections import Counter
import re
import xml.etree.ElementTree as ET


# Keep the existing integration process boundaries when sharing one runner.
IOS_INTEGRATION_GROUPS = (
    ("GrafttyMobileKitTests/RemoteConnectionCoordinatorTests",),
    ("GrafttyRemoteClientTests/SSHAuthLoopbackTests",
     "GrafttyRemoteClientTests/SSHTerminalLoopbackTests"),
    ("GrafttyMobileKitTests/RemoteConnectionReconnectTests",
     "GrafttyRemoteClientTests/RemoteHostConnectionLoopbackTests",
     "GrafttyRemoteClientTests/SSHOverWebRTCLoopbackTests",
     "GrafttyRemoteClientTests/SSHPanesAndControlLoopbackTests"),
)
IOS_INTEGRATION_SUITES = tuple(suite for group in IOS_INTEGRATION_GROUPS for suite in group)



def mac_filters(test_ids, batch_size=20):
    suites = set()
    modules = set()
    for identifier in test_ids:
        module, separator, name = identifier.partition(".")
        if not separator or not re.fullmatch(r"\w+", module) or not name:
            raise ValueError(f"Invalid discovered test identifier: {identifier!r}")
        if module != "OwnershipModelTests":
            modules.add(module)
            suites.add(name.split("/", 1)[0])
    if not suites:
        raise ValueError("No non-ownership tests were discovered")
    names = sorted(suites)
    # SwiftPM lists module-qualified names; Swift Testing can match names with
    # the module removed. Anchor both forms, including the suite boundary.
    # Group globally so a suite shared by modules is selected only once.
    module_prefix = "|".join(re.escape(n) for n in sorted(modules))
    patterns = ["^(?:(?:" + module_prefix + r")\.)?(" +
                "|".join(re.escape(n) for n in names[i:i + batch_size]) + r")(/|$)"
                for i in range(0, len(names), batch_size)]
    compiled = [re.compile(pattern) for pattern in patterns]
    for identifier in test_ids:
        expected = 0 if identifier.startswith("OwnershipModelTests.") else 1
        for spelling in (identifier, identifier.split(".", 1)[1]):
            if sum(bool(pattern.search(spelling)) for pattern in compiled) != expected:
                raise ValueError(f"Ambiguous test selection: {identifier}")
    return patterns


def verify_swift_results(test_ids, result_paths):
    """Require one result (including disabled tests) for every discovered ID."""
    actual = Counter()
    for path in result_paths:
        try:
            result = ET.parse(path)
        except (ET.ParseError, OSError) as error:
            raise ValueError(f"Incomplete Swift test results in {path}; inspect the matching batch transcript") from error
        for test in result.iter("testcase"):
            module, separator, suite = test.attrib["classname"].partition(".")
            # Swift Testing lists nested suites with '/', but xUnit uses '.'.
            prefix = module + "." + suite.replace(".", "/") + "/" if separator else module + "."
            actual[prefix + test.attrib["name"]] += 1
    return verify_inventory(test_ids, actual)


def verify_xctest_results(test_ids, transcript_paths):
    """Serial XCTest emits completion records but no SwiftPM xUnit report."""
    completion = re.compile(r"^Test Case '-\[(\S+) (\S+)\]' (passed|skipped|failed) \(")
    actual = Counter()
    for path in transcript_paths:
        for line in path.read_text().splitlines():
            match = completion.match(line)
            if match:
                classname, name, status = match.groups()
                if status == "failed":
                    raise ValueError(f"Failed XCTest {classname}/{name} in {path}")
                actual[classname + "/" + name] += 1
    return verify_inventory(test_ids, actual)


def verify_inventory(test_ids, actual):
    expected = Counter(identifier for identifier in test_ids
                       if not identifier.startswith("OwnershipModelTests."))
    missing, unexpected = expected - actual, actual - expected
    if missing or unexpected:
        raise ValueError(f"Test inventory mismatch: missing={dict(missing)}, unexpected={dict(unexpected)}")
    return sorted(actual)


def ios_selects(group, identifier):
    integration = any(identifier == suite or identifier.startswith(suite + "/")
                      for suite in IOS_INTEGRATION_SUITES)
    if group not in ("unit", "integration"):
        raise ValueError(f"Unknown iOS test group: {group}")
    return integration if group == "integration" else not integration


def ios_arguments(group):
    ios_selects(group, "")  # Validate before constructing xcodebuild arguments.
    prefix = "-only-testing:" if group == "integration" else "-skip-testing:"
    return [prefix + suite for suite in IOS_INTEGRATION_SUITES]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", choices=("unit", "integration"))
    args = parser.parse_args()
    if args.group == "unit":
        print(" ".join(ios_arguments(args.group)))
    else:
        for group in IOS_INTEGRATION_GROUPS:
            print(" ".join("-only-testing:" + suite for suite in group))
