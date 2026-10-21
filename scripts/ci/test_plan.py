#!/usr/bin/env python3
"""Build complete, disjoint test selections from discovered identifiers."""
import argparse
import re


IOS_INTEGRATION_SUITES = (
    "GrafttyMobileKitTests/RemoteConnectionCoordinatorTests",
    "GrafttyMobileKitTests/RemoteConnectionReconnectTests",
    "GrafttyRemoteClientTests/RemoteHostConnectionLoopbackTests",
    "GrafttyRemoteClientTests/SSHAuthLoopbackTests",
    "GrafttyRemoteClientTests/SSHOverWebRTCLoopbackTests",
    "GrafttyRemoteClientTests/SSHPanesAndControlLoopbackTests",
    "GrafttyRemoteClientTests/SSHTerminalLoopbackTests",
)


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
    print(" ".join(ios_arguments(args.group)))
