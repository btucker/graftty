#!/usr/bin/env python3
"""Prove hosted Quick Look retention against main, then the current implementation.

The baseline replaces RootView only, keeping current tests and representable
attachment tokens so baseline compilation cannot masquerade as regression RED.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sys
import uuid

from worktree_ui import REPO, capture, execute, read_result

SOURCE = 'Sources/GrafttyMobileKit/App/RootView.swift'
TESTS = ('GrafttyMobileBrowserTests/RemoteBrowserButtonTests/nativePreviewPreservesTerminalConnection(embedded:retained:)',
         'GrafttyMobileKitTests/TerminalPaneViewTests/focusRequestNotConsumedUntilTerminalCanFocus',
         'GrafttyMobileKitTests/TerminalPaneViewTests')
LIFECYCLE_ID = TESTS[0]
EXPECTED_CASES = {LIFECYCLE_ID + '[' + embedded + ', ' + retained + ']'
                  for embedded in ('false', 'true') for retained in ('false', 'true')}
FOCUS_ID = TESTS[1] + '()'
RETENTION_ASSERTION = re.compile(
    r'^Expectation failed:.*\b(?:socket\.closeCount|returnedContainer|client\.isOwner|container\.agentCompletion|container\.committedSoftwareInput)\b')


def adapt_baseline_source(source):
    """Accept the current fixture's initializer without changing old teardown."""
    transport = '((WorktreeManagementRequest, Host) async throws -> WorktreeManagementResponse)?'
    replacements = (
        ('stored fixture transport',
         '    private let remoteConnectionProvider: RemoteConnectionProvider?\n',
         '    private let remoteConnectionProvider: RemoteConnectionProvider?\n'
         '    private let previewManagementTransport: ' + transport + '\n'),
        ('optional fixture initializer parameter',
         '        remoteConnectionProvider: RemoteConnectionProvider? = nil\n',
         '        remoteConnectionProvider: RemoteConnectionProvider? = nil,\n'
         '        previewManagementTransport: ' + transport + ' = nil\n'),
        ('fixture transport initialization',
         '        self.remoteConnectionProvider = remoteConnectionProvider\n',
         '        self.remoteConnectionProvider = remoteConnectionProvider\n'
         '        self.previewManagementTransport = previewManagementTransport\n'),
        ('fixture transport forwarded to production preview controls',
         '                                     browserConnectionReady: connection == .live,\n',
         '                                     managementTransport: previewManagementTransport,\n'
         '                                     browserConnectionReady: connection == .live,\n'),
    )
    adjustments = []
    for description, old, new in replacements:
        if source.count(new) == 1:
            continue
        if source.count(old) != 1 or new in source:
            raise ValueError('Cannot safely adapt baseline ' + description)
        source = source.replace(old, new, 1)
        adjustments.append(description)
    return source, adjustments


def test_report_records(report):
    """Keep argument identities and failures that legacy xcresult nodes omit.

    Xcode's test-results tree names Arguments nodes "false, true" and nests
    each runtime assertion underneath its argument node. Do not count the
    parent Test Case summary as another execution.
    """
    records = []

    def messages(node):
        result = [node['name']] if node.get('nodeType') == 'Failure Message' else []
        for child in node.get('children', []):
            result.extend(messages(child))
        return result

    def walk(node, bundle=''):
        kind = node.get('nodeType')
        if kind in ('Unit test bundle', 'UI test bundle'):
            bundle = node['name']
        if kind == 'Test Case':
            identifier = bundle + '/' + node.get('nodeIdentifier', '')
            arguments = [child for child in node.get('children', [])
                         if child.get('nodeType') == 'Arguments']
            for case in arguments or [node]:
                suffix = '[' + case['name'] + ']' if arguments else ''
                result = case.get('result', 'unknown')
                records.append({'id': identifier + suffix,
                                'status': {'Passed': 'Success', 'Failed': 'Failure'}.get(result, result),
                                'failures': messages(case)})
            return
        for child in node.get('children', []):
            walk(child, bundle)

    for node in report.get('testNodes', []):
        walk(node)
    return records


def evaluate(records, errors, _failures, code, red):
    if errors or not records:
        return False, 'Build/runner failure or missing test records'
    cases = [r for r in records if r['id'].startswith(LIFECYCLE_ID)]
    if len(cases) != 4 or {r['id'] for r in cases} != EXPECTED_CASES:
        return False, 'Expected each of the four exact layout/retention argument cases once'
    if red:
        if len(records) != 4:
            return False, 'Unexpected tests ran in the focused baseline phase'
        if any(r['status'] != 'Failure' for r in cases):
            return False, 'Every baseline layout/retention case must fail'
        for case in cases:
            if not any(RETENTION_ASSERTION.search(message) for message in case.get('failures', [])):
                return False, 'Missing targeted retention assertion evidence for ' + case['id']
        return code != 0, ('Four baseline retention cases failed at runtime' if code
                           else 'Expected failing xcodebuild exit')
    if code or any(r['status'] != 'Success' or r.get('failures') for r in records):
        return False, 'Current tests failed, skipped, or runner failed'
    if sum(r['id'] == FOCUS_ID for r in records) != 1:
        return False, 'Expected exactly one executed stale focus regression'
    return True, 'Four retention cases and terminal regression suite passed'


def run_phase(name, options, simulator):
    directory = options.output / name
    directory.mkdir()
    selections = TESTS[:1] if name == 'red' else (TESTS[0], TESTS[2])
    command = ['xcodebuild', '-project', 'Apps/GrafttyMobile/GrafttyMobile.xcodeproj',
               '-scheme', 'GrafttyMobile', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
               '-destination', f'platform=iOS Simulator,id={simulator}', '-destination-timeout', '90',
               '-derivedDataPath', str(options.derived_data), '-skipPackagePluginValidation',
               '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(directory / 'tests.xcresult'),
               'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES',
               'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG GRAFTTY_PAGED_HISTORY',
               'OTHER_SWIFT_FLAGS=$(inherited) -Xcc ' + os.environ['GRAFTTY_RENDERER_CONTEXT'],
               *('-only-testing:' + test for test in selections), 'test']
    if options.source_packages:
        command[1:1] = ['-clonedSourcePackagesDirPath', str(options.source_packages)]
    result = {'command': command, 'passed': False}
    try:
        result['exitCode'], _ = execute(command, timeout=options.timeout, log=directory / 'xcodebuild.log')
        _, errors, failures = read_result(directory / 'tests.xcresult', directory)
        report = json.loads(capture(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
                                     '--path', str(directory / 'tests.xcresult')]))
        (directory / 'xcresult-test-report.json').write_text(json.dumps(report, indent=2))
        records = test_report_records(report)
        result.update(tests=records, executedCount=len(records), infrastructureErrors=errors, assertionFailures=failures)
        result['passed'], result['reason'] = evaluate(records, errors, failures, result['exitCode'], name == 'red')
    except Exception as error:
        result['reason'] = str(error)
    (directory / 'result.json').write_text(json.dumps(result, indent=2))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--source-packages', type=Path)
    parser.add_argument('--baseline')
    parser.add_argument('--runtime')
    parser.add_argument('--timeout', type=int, default=1800)
    options = parser.parse_args()
    if options.baseline and os.environ.get('CI', '').lower() not in ('true', '1'):
        parser.error('Baseline source overlay requires an isolated CI checkout (CI=true)')
    for name in ('GRAFTTY_RENDERER_CONTEXT', 'GRAFTTY_GHOSTTY_PACKAGE_PATH'):
        if not os.environ.get(name):
            parser.error(name + ' is required')
    options.output = options.output.resolve()
    options.derived_data = options.derived_data.resolve()
    options.output.mkdir(parents=True, exist_ok=False)
    summary = {'result': 'failed', 'currentCommit': capture(['git', 'rev-parse', 'HEAD']),
               'workingTree': capture(['git', 'status', '--short']), 'baseline': options.baseline,
               'xcode': capture(['xcodebuild', '-version']),
               'rendererPackage': os.environ['GRAFTTY_GHOSTTY_PACKAGE_PATH'],
               'rendererContext': os.environ['GRAFTTY_RENDERER_CONTEXT']}
    (options.output / 'source.diff').write_text(capture(['git', 'diff', 'HEAD']))
    simulator = None
    original = (REPO / SOURCE).read_bytes()
    summary['currentSourceHashes'] = {SOURCE: hashlib.sha256(original).hexdigest()}
    try:
        runtimes = json.loads(capture(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
        available = [r for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier']
                     and (not options.runtime or options.runtime == r['identifier'])]
        runtime = max(available, key=lambda r: tuple(int(p) for p in r['version'].split('.')))
        summary['runtime'] = runtime
        simulator = capture(['xcrun', 'simctl', 'create', 'Graftty preview ' + uuid.uuid4().hex[:8],
                             'iPhone 17', runtime['identifier']])
        summary['simulator'] = simulator
        capture(['xcrun', 'simctl', 'boot', simulator])
        code, _ = execute(['xcrun', 'simctl', 'bootstatus', simulator, '-b'], timeout=600,
                          log=options.output / 'boot.log')
        if code:
            raise RuntimeError('Simulator boot failed')
        if options.baseline:
            (options.output / 'RootView.backup.swift').write_bytes(original)
            try:
                summary['baselineCommit'] = capture(['git', 'rev-parse', options.baseline + '^{commit}'])
                source = execute(['git', 'show', summary['baselineCommit'] + ':' + SOURCE])[1]
                summary['baselineOriginalSourceHash'] = hashlib.sha256(source.encode()).hexdigest()
                source, summary['baselineAdjustments'] = adapt_baseline_source(source)
                (REPO / SOURCE).write_text(source)
                (options.output / 'RootView.baseline.swift').write_text(source)
                summary['baselineSourceHash'] = hashlib.sha256((REPO / SOURCE).read_bytes()).hexdigest()
                summary['red'] = run_phase('red', options, simulator)
            finally:
                (REPO / SOURCE).write_bytes(original)
        summary['sourceRestored'] = (REPO / SOURCE).read_bytes() == original
        if not summary['sourceRestored']:
            raise RuntimeError('Source restoration failed')
        summary['green'] = run_phase('green', options, simulator)
        if summary['green']['passed'] and (not options.baseline or summary['red']['passed']):
            summary['result'] = 'passed'
    except Exception as error:
        summary['error'] = str(error)
    finally:
        if simulator:
            for action in ('shutdown', 'delete'):
                try:
                    capture(['xcrun', 'simctl', action, simulator])
                except Exception as error:
                    summary.setdefault('cleanupErrors', []).append(str(error))
        (options.output / 'result.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0 if summary['result'] == 'passed' else 1


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit('Interrupted by SIGTERM'))
    sys.exit(main())
