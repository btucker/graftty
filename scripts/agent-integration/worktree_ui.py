#!/usr/bin/env python3
"""Run focused Mobile worktree UI regressions, optionally proving RED first.

Requires the paging-renderer action's GRAFTTY_GHOSTTY_PACKAGE_PATH and
GRAFTTY_RENDERER_CONTEXT. Uses its existing renderer without rebuilding it.
Only BASELINE_FILES are temporarily replaced; current tests remain.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import uuid


REPO = Path(__file__).resolve().parents[2]
# Types moved out of WorktreeListContent after older baselines. A baseline
# WorktreeListContent still declares them, so files the baseline lacks are emptied.
SPLIT_FILES = (
    'Sources/GrafttyMobileKit/UI/RemoteMacConnectionRow.swift',
    'Sources/GrafttyMobileKit/UI/WorktreeBlock.swift',
    'Sources/GrafttyMobileKit/UI/WorktreeLoadingView.swift',
)
BASELINE_FILES = (
    'Sources/GrafttyMobileKit/UI/WorktreeListContent.swift',
    'Sources/GrafttyMobileKit/Terminal/MobilePagedTerminalRenderer.swift',
    'Sources/GrafttyMobileKit/UI/RemoteOpenButton.swift',
    'Sources/GrafttyMobileKit/UI/MobileWorktreeContextDrawer.swift',
) + SPLIT_FILES
TESTS = (
    'GrafttyMobileBrowserTests/WorktreeRowAlignmentTests',
    'GrafttyMobileBrowserTests/RemoteBrowserButtonTests',
    'GrafttyMobileKitTests/PagedSourceGridTests',
)
RED_CASES = (
    ('WorktreeRowAlignmentTests', 'progressAlignsWithTitle'),
    ('RemoteBrowserButtonTests', 'drawerPreservesMountedTerminal'),
    ('PagedSourceGridTests', 'sourceGridAcknowledgementKeepsOwnerViewportStable'),
)
RED_ASSERTIONS = {
    'progressAlignsWithTitle': ('Spinner center',),
    'drawerPreservesMountedTerminal': ('Context must occupy a glyph target', 'open.accessibilityFrame'),
    'sourceGridAcknowledgementKeepsOwnerViewportStable': ('authoritativeGrid', 'preparedGrids',
                                                        'Source-grid acknowledgements'),
}
GREEN_CASES = RED_CASES + (
    ('RemoteBrowserButtonTests', 'contextRemainsAccessibleAfterLastPaneCloses'),
    ('PagedSourceGridTests', 'sourceParserGridSurvivesPhysicalResizeAndFontChanges'),
    ('PagedSourceGridTests', 'sourceGridWaitsForFirstSurfaceMount'),
)
RENDER_DIRS = ('graftty-worktree-ui-renders', 'graftty-browser-control-renders')


def execute(command, *, timeout=120, log=None):
    """Preserve command output and stop its children before restoring source."""
    with (log.open('wb') if log else open(os.devnull, 'wb')) as sink:
        process = subprocess.Popen(command, cwd=REPO, stdout=sink if log else subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            output, _ = process.communicate(timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
    text = (output or b'').decode(errors='replace')
    if process.returncode and log is None:
        raise RuntimeError(f'Command failed ({process.returncode}): {command}\n{text}')
    return process.returncode, text


def capture(command):
    return execute(command)[1].strip()


def scalar(node, key):
    value = node.get(key, {})
    return value.get('_value') if isinstance(value, dict) else value


def test_records(node, ancestors=()):
    """Read legacy xcresult test nodes, including Swift Testing arguments."""
    records = []
    if isinstance(node, dict):
        identifier = scalar(node, 'testIdentifier') or scalar(node, 'identifier')
        path = ancestors + ((identifier,) if identifier else ())
        status = scalar(node, 'testStatus')
        if status and identifier:
            records.append({'id': '/'.join(path), 'status': status})
        for key, value in node.items():
            if key not in ('testIdentifier', 'identifier', 'testStatus'):
                records.extend(test_records(value, path))
    elif isinstance(node, list):
        for value in node:
            records.extend(test_records(value, ancestors))
    return records


def read_result(bundle, directory):
    command = ['xcrun', 'xcresulttool', 'get', 'object', '--legacy', '--format', 'json', '--path', str(bundle)]
    root = json.loads(capture(command))
    (directory / 'xcresult-root.json').write_text(json.dumps(root, indent=2))
    records, errors, failures = [], [], []
    errors.extend(root.get('issues', {}).get('errorSummaries', {}).get('_values', []))
    failures.extend(root.get('issues', {}).get('testFailureSummaries', {}).get('_values', []))
    for index, action in enumerate(root.get('actions', {}).get('_values', [])):
        result = action.get('actionResult', {})
        errors.extend(result.get('issues', {}).get('errorSummaries', {}).get('_values', []))
        failures.extend(result.get('issues', {}).get('testFailureSummaries', {}).get('_values', []))
        errors.extend(action.get('buildResult', {}).get('issues', {}).get('errorSummaries', {}).get('_values', []))
        reference = scalar(result.get('testsRef', {}), 'id')
        if reference:
            tests = json.loads(capture(command + ['--id', reference]))
            (directory / f'xcresult-tests-{index}.json').write_text(json.dumps(tests, indent=2))
            records.extend(test_records(tests))
    return records, errors, failures


def evaluate(records, errors, returncode, red, failures=()):
    if errors or not records:
        return False, 'Build/runner failure or no XCTest records; no regression result established'
    expected = RED_CASES if red else GREEN_CASES
    for suite, method in expected:
        matching = [record for record in records if suite in record['id'] and method in record['id']]
        if not matching:
            return False, f'Targeted case did not run: {suite}/{method}'
        if red:
            if not any(record['status'] == 'Failure' for record in matching):
                return False, f'Baseline did not fail targeted case: {suite}/{method}'
            if not any(method in (scalar(failure, 'testCaseName') or '')
                       and any(text in (scalar(failure, 'message') or '') for text in RED_ASSERTIONS[method])
                       for failure in failures):
                return False, f'No targeted assertion evidence in xcresult: {suite}/{method}'
        elif any(record['status'] != 'Success' for record in matching):
            return False, f'Targeted case failed or skipped: {suite}/{method}'
    if red:
        return (returncode != 0, 'Targeted XCTest failures establish RED' if returncode else 'Expected failing xcodebuild exit')
    if returncode or any(record['status'] != 'Success' for record in records):
        return False, 'Current tests failed, skipped, or runner exited unsuccessfully'
    return True, 'All required targeted cases passed'


def collect_renders(simulator, directory):
    try:
        container = Path(capture(['xcrun', 'simctl', 'get_app_container', simulator,
                                  'net.graftty.GrafttyMobileTestHost', 'data']))
    except RuntimeError as error:
        return {'error': str(error)}
    copied = []
    for name in RENDER_DIRS:
        source = container / 'tmp' / name
        if source.is_dir():
            shutil.copytree(source, directory / name)
            copied.extend(str(path.relative_to(directory)) for path in (directory / name).rglob('*.png'))
            # This simulator belongs to this run; do not let RED images count as GREEN evidence.
            shutil.rmtree(source)
    return {'images': copied}


def run_phase(name, options, simulator):
    directory = options.output / name
    directory.mkdir()
    command = ['xcodebuild', '-project', 'Apps/GrafttyMobile/GrafttyMobile.xcodeproj',
               '-scheme', 'GrafttyMobile', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
               '-destination', f'platform=iOS Simulator,id={simulator}', '-destination-timeout', '90',
               '-derivedDataPath', str(options.derived_data), '-skipPackagePluginValidation',
               '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(directory / 'tests.xcresult'),
               'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES',
               'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG GRAFTTY_PAGED_HISTORY',
               'OTHER_SWIFT_FLAGS=$(inherited) -Xcc ' + os.environ['GRAFTTY_RENDERER_CONTEXT'],
               *('-only-testing:' + test for test in TESTS), 'test']
    if options.source_packages:
        command[1:1] = ['-clonedSourcePackagesDirPath', str(options.source_packages)]
    result = {'command': command, 'passed': False}
    (directory / 'command.json').write_text(json.dumps(command, indent=2))
    try:
        result['exitCode'], _ = execute(command, timeout=options.timeout, log=directory / 'xcodebuild.log')
        records, errors, failures = read_result(directory / 'tests.xcresult', directory)
        result.update(tests=records, infrastructureErrors=errors, assertionFailures=failures)
        result['passed'], result['reason'] = evaluate(records, errors, result['exitCode'], name == 'red', failures)
    except Exception as error:
        result['reason'] = str(error)
    finally:
        try:
            result['renders'] = collect_renders(simulator, directory)
        except Exception as error:
            result['renders'] = {'error': str(error)}
        images = result['renders'].get('images', [])
        if result['passed'] and (not any(Path(path).name.startswith('row-') for path in images)
                                or (name == 'green' and not any(Path(path).name == 'context-browser-group.png' for path in images))):
            result.update(passed=False, reason='Required row/control PNG evidence was not produced')
        (directory / 'result.json').write_text(json.dumps(result, indent=2))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New directory for evidence')
    parser.add_argument('--derived-data', type=Path, required=True, help='Existing build tree to reuse')
    parser.add_argument('--source-packages', type=Path)
    parser.add_argument('--baseline', help='Git ref for the production files listed in BASELINE_FILES')
    parser.add_argument('--device-type', default='iPhone 17')
    parser.add_argument('--runtime', help='Available iOS runtime identifier; default newest available')
    parser.add_argument('--timeout', type=int, default=1800, help='Seconds per xcodebuild phase')
    options = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Requires macOS and Xcode with an iOS Simulator runtime')
    if options.baseline and os.environ.get('CI', '').lower() not in ('true', '1'):
        parser.error('--baseline temporarily overlays sources and is restricted to an isolated CI checkout (CI=true)')
    for name in ('GRAFTTY_RENDERER_CONTEXT', 'GRAFTTY_GHOSTTY_PACKAGE_PATH'):
        if not os.environ.get(name):
            parser.error(f'{name} is required; prepare the shared paging renderer first')
    os.environ['GRAFTTY_REQUIRE_PAGED_HISTORY'] = '1'
    options.output = options.output.resolve()
    options.derived_data = options.derived_data.resolve()
    if options.source_packages:
        options.source_packages = options.source_packages.resolve()
    options.output.mkdir(parents=True, exist_ok=False)
    summary = {'result': 'failed', 'currentCommit': capture(['git', 'rev-parse', 'HEAD']),
               'workingTree': capture(['git', 'status', '--short']), 'baseline': options.baseline,
               'scope': 'Current tests/build configuration; optional baseline replaces only baselineFiles',
               'baselineFiles': list(BASELINE_FILES),
               'rendererContext': os.environ['GRAFTTY_RENDERER_CONTEXT'],
               'rendererPackage': os.environ['GRAFTTY_GHOSTTY_PACKAGE_PATH'],
               'derivedData': str(options.derived_data), 'xcode': capture(['xcodebuild', '-version'])}
    simulator = None
    try:
        runtimes = json.loads(capture(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
        available = [runtime for runtime in runtimes if runtime.get('isAvailable')
                     and '.iOS-' in runtime['identifier']
                     and (not options.runtime or runtime['identifier'] == options.runtime)]
        runtime = max(available, key=lambda value: tuple(int(part) for part in value['version'].split('.')))
        summary['runtime'] = runtime
        simulator = capture(['xcrun', 'simctl', 'create', 'Graftty worktree UI ' + uuid.uuid4().hex[:8],
                             options.device_type, runtime['identifier']])
        summary['simulator'] = simulator
        capture(['xcrun', 'simctl', 'boot', simulator])
        code, _ = execute(['xcrun', 'simctl', 'bootstatus', simulator, '-b'], timeout=600,
                          log=options.output / 'boot.log')
        if code:
            raise RuntimeError(f'Simulator bootstatus failed ({code}); see boot.log')
        originals = {name: (REPO / name).read_bytes() for name in BASELINE_FILES}
        summary['currentSourceHashes'] = {name: hashlib.sha256(data).hexdigest() for name, data in originals.items()}
        if options.baseline:
            backup = options.output / 'source-backup'
            backup.mkdir()
            for name, data in originals.items():
                (backup / Path(name).name).write_bytes(data)
            try:
                summary['baselineCommit'] = capture(['git', 'rev-parse', options.baseline + '^{commit}'])
                for name in BASELINE_FILES:
                    absent = name in SPLIT_FILES and not capture(['git', 'ls-tree', summary['baselineCommit'], '--', name])
                    source = '' if absent else execute(['git', 'show', summary['baselineCommit'] + ':' + name])[1]
                    if name.endswith('/WorktreeListContent.swift'):
                        source = source.replace('private struct WorktreeRowContent: View', 'struct WorktreeRowContent: View')
                    if name.endswith('/MobileWorktreeContextDrawer.swift'):
                        source = source.replace('    let context: SidebarWorktreeContext?',
                            '    let context: SidebarWorktreeContext?\n    var showsStandaloneControl = false')
                    (REPO / name).write_text(source)
                summary['baselineSourceHashes'] = {name: hashlib.sha256((REPO / name).read_bytes()).hexdigest()
                                                   for name in BASELINE_FILES}
                summary['baselineAdjustments'] = ['WorktreeRowContent remains internal for current test access',
                    'Old drawer accepts the new standalone-control argument without changing baseline rendering']
                summary['red'] = run_phase('red', options, simulator)
            except Exception as error:
                summary['red'] = {'passed': False, 'reason': str(error)}
            finally:
                restore_errors = []
                for name, data in originals.items():
                    try:
                        (REPO / name).write_bytes(data)
                    except OSError as error:
                        restore_errors.append(f'{name}: {error}')
                if restore_errors:
                    summary['sourceRestoreErrors'] = restore_errors
                    raise RuntimeError('Source restoration failed; GREEN will not run; recover source-backup bytes')
                summary['sourceRestored'] = all((REPO / name).read_bytes() == data for name, data in originals.items())
                if not summary['sourceRestored']:
                    raise RuntimeError('Source restoration verification failed; GREEN will not run')
            # A baseline build/runner failure still gets a current-source run,
            # but cannot be presented as successful RED/GREEN validation.
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
