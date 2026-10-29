#!/usr/bin/env python3
"""Measure macOS blocked dispatch threads at synchronous Swift Testing boundaries.

Select the same pinned renderer as .github/actions/paging-renderer first:
  export GRAFTTY_REQUIRE_PAGED_HISTORY=1
  python3 -B scripts/ci/gcd_probe.py run --output /tmp/gcd-evidence
All builds and test launches use timeout -k 15 1500 scripts/swiftpm. The
batch filters come from the CI test plan. Each batch keeps one test process;
its in-process ABI callback waits for sampling before the next suite runs.
Use --self-check first to prove sample access with one deliberately blocked
worker, then --batch N to narrow a repeated investigation. XCTest targets
retain their separate CI process boundaries after the Swift Testing batches.
The final ownership gate retains CI parallel execution; its suite counts can
overlap, so use its final sample to check residual work.

Counts are observations, not proof of a leak. Compare thread IDs and stacks
at later boundaries. Dedicated NIO threads and idle workqueue threads cannot
saturate GCD's constrained pool and are reported separately. Anonymous sample
stacks are counted separately because their thread cardinality is unknown. Raw samples,
JSON events, full transcripts, and the exact test plan remain in --output.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from test_plan import mac_filters, verify_swift_results, verify_xctest_results


HARNESS = r'^(?:GrafttyKitTests\.)?DispatchWorkProbeTests/runBatch\(\)(/|$)'
FIXTURE = 'GrafttyKitTests.DispatchWorkProbeFixture'
XCTEST_HARNESS = 'DispatchWorkProbeXCTestTests'
# Match leaf frames, not a wait function elsewhere in an active stack.
WAIT = re.compile(r'\b(?:__psynch_\w+wait|__ulock_wait\w*|semaphore_wait_trap|'
                  r'semaphore_timedwait_trap|__semwait_signal|__workq_kernreturn|'
                  r'__psynch_mutexwait|__ulock_wait2|read|__read_nocancel|'
                  r'kevent\w*|mach_msg\w*|poll|select|__select|__sigsuspend|wait4|__wait4)\b')
THREAD = re.compile(r'^\s+\d+ Thread_([^\s:]+)[^\n]*\n', re.MULTILINE)


def require_ci_renderer(environment):
    renderer = environment.get('GRAFTTY_GHOSTTY_PACKAGE_PATH')
    if environment.get('GRAFTTY_REQUIRE_PAGED_HISTORY') != '1':
        raise ValueError('CI capture requires GRAFTTY_REQUIRE_PAGED_HISTORY=1; '
                         'Use --self-check only for sensor calibration.')
    return renderer


def ci_environment(environment):
    return {**environment, 'CI': 'true', 'GITHUB_ACTIONS': 'true'}


def ci_processes(filters, classes):
    targets = sorted({name.split('.', 1)[0] for name in classes})
    return (list(enumerate(filters, 1)) +
            [('xctest-' + target, sorted(name for name in classes if name.startswith(target + '.')))
             for target in targets] + [('ownership', 'OwnershipModel')])


def parse_sample(text):
    if 'Call graph:' not in text or 'Total number in stack' not in text:
        raise ValueError('Missing or incomplete sample call graph')
    graph = text.split('Call graph:', 1)[1].split('Total number in stack', 1)[0]
    matches = list(THREAD.finditer(graph))
    if not matches:
        raise ValueError('Sample contains no thread stacks')
    report = dict(dispatchWorkers=0, blockedDispatchWorkers=0, blockedCooperativeWorkers=0,
                  unclassifiedDispatchWorkers=0, idleWorkers=0,
                  otherThreads=0, diagnosticThreads=0, blocked=[], unclassified=[],
                  anonymousStacks=0, anonymousDispatchStacks=0, blockedAnonymousDispatchStacks=0,
                  unclassifiedAnonymousDispatchStacks=0, anonymous=[])
    for index, match in enumerate(matches):
        stack = graph[match.end():matches[index + 1].start() if index + 1 < len(matches) else len(graph)].strip()
        diagnostic = 'DispatchWorkProbeState.' in stack
        worker = ('com.apple.root.' in match[0] or '_dispatch_root_queue_drain' in stack
                  or '_dispatch_lane_serial_drain' in stack)
        blocked = bool(WAIT.search(stack.splitlines()[-1]))
        idle = '_pthread_wqthread' in stack and '__workq_kernreturn' in stack
        if not match[1].isdigit():
            # sample can coalesce a workloop into Thread_<multiple>. Neither
            # its thread count nor its identity can be inferred from that label.
            kind = ('diagnostic' if diagnostic else 'blocked' if worker and blocked else
                    'unclassified' if worker else 'idle' if idle else 'other')
            report['anonymousStacks'] += 1
            report['anonymous'].append({'header': match[0].strip(), 'stack': stack, 'classification': kind})
            if worker and not diagnostic:
                report['anonymousDispatchStacks'] += 1
                report['blockedAnonymousDispatchStacks' if blocked else 'unclassifiedAnonymousDispatchStacks'] += 1
            continue
        if diagnostic:
            report['diagnosticThreads'] += 1
        elif worker:
            report['dispatchWorkers'] += 1
            thread = {'id': match[1], 'header': match[0].split('Thread_', 1)[1].strip(), 'stack': stack,
                      'cooperative': '.cooperative' in match[0]}
            if blocked:
                report['blockedDispatchWorkers'] += 1
                report['blockedCooperativeWorkers'] += int(thread['cooperative'])
                report['blocked'].append(thread)
            else:
                # A finite wait-symbol list cannot establish that this worker
                # is active. Keep unknown waits visible for stack inspection.
                report['unclassifiedDispatchWorkers'] += 1
                report['unclassified'].append(thread)
        elif idle:
            report['idleWorkers'] += 1
        else:
            report['otherThreads'] += 1
    return report


def summarize(root, records):
    previous = {}
    rows = []
    for record in records:
        report = parse_sample((root / record['sample']).read_text())
        blocked = {thread['id'] for thread in report['blocked']}
        rows.append({**record, **report, 'newBlockedThreadIDs': sorted(blocked - previous.get(record['pid'], set())),
                     'retainedBlockedThreadIDs': sorted(blocked & previous.get(record['pid'], set()))})
        previous[record['pid']] = blocked
    return rows


def verify_boundaries(events, records):
    suites = {event['payload']['id'] for event in events
              if event['kind'] == 'test' and event['payload']['kind'] == 'suite'}
    expected = [event['payload']['testID'] for event in events
                if event['kind'] == 'event' and event['payload']['kind'] == 'testEnded'
                and event['payload'].get('testID') in suites]
    actual = [record['suite'] for record in records if record['phase'] == 'after']
    if not expected or expected != actual or sum(record['phase'] == 'before' for record in records) != 1:
        raise ValueError(f'Incomplete suite boundary evidence: expected={expected}, sampled={actual}')


def snapshot(pid, output, suite, phase, sequence):
    output.mkdir(parents=True, exist_ok=True)
    name = f'{sequence:04d}-{phase}.sample.txt'
    # Zero duration takes one complete thread snapshot, avoiding a weighted
    # call tree whose branches cannot be counted as separate blocked threads.
    result = subprocess.run(['/usr/bin/sample', str(pid), '0', '1', '-file', str(output / name)],
                            capture_output=True, text=True, timeout=25)
    (output / f'{sequence:04d}-sample.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    report = parse_sample((output / name).read_text())
    record = dict(pid=pid, suite=suite, phase=phase, sample=name, sequence=sequence, time=time.time())
    with (output / 'samples.jsonl').open('a') as stream:
        stream.write(json.dumps(record) + '\n')
    print(f'GCD probe {suite}: {report["blockedDispatchWorkers"]} blocked dispatch workers, '
          f'{report["unclassifiedDispatchWorkers"]} unclassified, '
          f'{report["blockedAnonymousDispatchStacks"]} blocked anonymous stacks', flush=True)


def run(args):
    if sys.platform != 'darwin':
        raise SystemExit('The dispatch diagnostic requires macOS sample')
    renderer = os.environ.get('GRAFTTY_GHOSTTY_PACKAGE_PATH') if args.self_check else require_ci_renderer(os.environ)
    capture_environment = ci_environment(os.environ)
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    # Refuse to combine stale evidence with another run.
    output.mkdir(parents=True, exist_ok=False)
    command = ['timeout', '-k', '15', '1500', 'scripts/swiftpm', 'test', '--build-system', 'native']
    with (output / 'discovery-build.log').open('w') as log:
        inventory = subprocess.check_output([*command, 'list', '--disable-xctest'], cwd=root,
                                            env=capture_environment, stderr=log, text=True)
    discovered = [line.strip() for line in inventory.splitlines() if line.strip()]
    filters = mac_filters(discovered)
    tests = [test for test in discovered if not test.startswith('GrafttyKitTests.DispatchWorkProbe')]
    plan = dict(head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
                discovered=discovered, inventory=tests, filters=filters, command=command, selfCheck=args.self_check,
                cpuCount=os.cpu_count(), swiftVersion=subprocess.check_output(['xcrun', 'swift', '--version'], text=True),
                worktreeStatus=subprocess.check_output(['git', 'status', '--short'], cwd=root, text=True),
                sharedBuildDirectory=os.environ.get('GRAFTTY_SWIFTPM_SHARED_DIR', 'default'),
                ciEnvironment={key: capture_environment[key] for key in ['CI', 'GITHUB_ACTIONS']})
    if renderer:
        renderer_path = Path(renderer)
        if not renderer_path.is_absolute():
            renderer_path = root / renderer_path
        stamp = (renderer_path / 'PAGING-BUILD.json').read_text()
        plan['pagingRenderer'] = dict(path=str(renderer_path), stamp=stamp,
                                     stampSHA256=hashlib.sha256(stamp.encode()).hexdigest())
    else:
        plan['pagingRenderer'] = dict(published=json.loads((root / 'Package.resolved').read_text())['pins'])
    sources = [Path(__file__).resolve(), root / 'Tests/GrafttyKitTests/Support/DispatchWorkProbeTests.swift',
               root / 'Tests/GrafttyKitTests/Support/DispatchWorkProbe.swift',
               root / 'scripts/ci/test_plan.py', root / 'scripts/ci/test_gcd_probe.py']
    plan['probeSourceSHA256'] = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                               for path in sources}
    (output / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    if args.reference_plan:
        reference = json.loads(args.reference_plan.read_text())
        if reference['filters'] != filters or sorted(reference['discovered']) != sorted(discovered):
            raise ValueError('Discovery differs from the reference CI plan; do not resume by batch number')
        (output / 'reference-plan.json').write_text(json.dumps(reference, indent=2) + '\n')
    classes = []
    plan['ownershipGate'] = dict(filter='OwnershipModel', parallel=True, position='after XCTest targets')
    if not args.self_check and not args.ownership_only and args.batch is None:
        with (output / 'xctest-discovery-build.log').open('w') as log:
            xctest_inventory = subprocess.check_output([*command, 'list', '--disable-swift-testing'], cwd=root,
                                                       env=capture_environment, stderr=log, text=True).splitlines()
        classes = sorted({test.split('/', 1)[0] for test in xctest_inventory
                          if test and not test.startswith(('OwnershipModelTests.', 'GrafttyKitTests.DispatchWorkProbe'))})
        targets = sorted({name.split('.', 1)[0] for name in classes})
        if args.xctest_target:
            if args.xctest_target not in targets:
                raise ValueError(f'Unknown XCTest target: {args.xctest_target}')
        plan['xctestClasses'] = classes
        plan['xctestTargets'] = targets
    (output / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    if args.self_check:
        selected = [(0, r'^(?:GrafttyKitTests\.)?DispatchWorkProbeFixture(/|$)')]
    elif args.ownership_only:
        selected = [('ownership', 'OwnershipModel')]
    elif args.xctest_target:
        selected = [(index, pattern) for index, pattern in ci_processes(filters, classes)
                    if index == 'xctest-' + args.xctest_target]
    elif args.batch is not None:
        selected = [(i, pattern) for i, pattern in enumerate(filters, 1) if args.batch == i]
    else:
        selected = [(index, pattern) for index, pattern in ci_processes(filters, classes)
                    if not isinstance(index, int) or args.from_batch is None or index >= args.from_batch]
    if not selected:
        raise ValueError('No selected batches')
    status = 0
    all_rows = []
    for index, pattern in selected:
        is_xctest = isinstance(index, str) and index.startswith('xctest-')
        parallel = index == 'ownership'
        batch = output / (index if isinstance(index, str) else f'batch-{index:02d}')
        batch.mkdir()
        environment = {**capture_environment, 'GRAFTTY_GCD_PROBE_FILTER': '' if is_xctest else pattern,
                       'GRAFTTY_GCD_PROBE_OUTPUT': str(batch),
                       'GRAFTTY_GCD_PROBE_PARALLEL': '1' if parallel else '0',
                       'GRAFTTY_GCD_PROBE_SELF_CHECK': '1' if args.self_check else '0'}
        if is_xctest:
            environment['GRAFTTY_GCD_PROBE_XCTEST_CLASSES'] = json.dumps(pattern)
        print(f'GCD probe batch {index}: {pattern}', flush=True)
        with (batch / 'tests.log').open('w') as log:
            result = subprocess.run([*command, '--disable-swift-testing' if is_xctest else '--disable-xctest',
                                     *([] if parallel else ['--no-parallel']),
                                     '--filter', XCTEST_HARNESS if is_xctest else HARNESS],
                                    cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT)
        records_path = batch / 'samples.jsonl'
        records = [json.loads(line) for line in records_path.read_text().splitlines()] if records_path.exists() else []
        rows = summarize(batch, records)
        events_path = batch / 'events.jsonl'
        events = [json.loads(line) for line in events_path.read_text().splitlines()] if events_path.exists() else []
        verify_boundaries(events, records)
        if not rows or not any(row['phase'] == 'after' for row in rows):
            raise ValueError(f'No completed-suite evidence in {batch}; inspect tests.log')
        (batch / 'summary.json').write_text(json.dumps(rows, indent=2) + '\n')
        all_rows.extend({**row, 'batch': index} for row in rows)
        (output / 'summary.json').write_text(json.dumps(all_rows, indent=2) + '\n')
        if not is_xctest and not result.returncode and not args.self_check:
            expected = [test for test in tests if re.search(pattern, test)]
            verify_swift_results(expected, [batch / 'results.xml'], include_ownership=parallel)
            if parallel and sum(row['phase'] == 'finished' for row in rows) != 1:
                raise ValueError('The parallel ownership gate requires one final run-ended sample')
        if is_xctest and not result.returncode:
            transcript = batch / 'xctest-results.log'
            transcript.write_text('\n'.join(line for line in (batch / 'tests.log').read_text().splitlines()
                                            if 'DispatchWorkProbeXCTestTests testRunTarget' not in line) + '\n')
            expected = [test for test in xctest_inventory if test.split('/', 1)[0] in pattern]
            verify_xctest_results(expected, [transcript])
        status = status or result.returncode
        if args.self_check:
            completed = [row for row in rows if row['phase'] == 'after' and row['suite'] == FIXTURE]
            released = [row for row in rows if row['phase'] == 'released']
            if (len(completed) != 1 or len(completed[0]['newBlockedThreadIDs']) != 1
                    or completed[0]['blockedDispatchWorkers'] != 1
                    or not any('DispatchWorkProbeFixture' in thread['stack'] for thread in completed[0]['blocked'])
                    or len(released) != 1 or released[0]['blockedDispatchWorkers'] != 0):
                raise ValueError('Self-check failed to detect the deliberately blocked worker')
        print(f'Batch {index}: exit {result.returncode}, {len(rows)} snapshots', flush=True)
        if result.returncode:
            break
    return status


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='mode', required=True)
    runner = commands.add_parser('run')
    runner.add_argument('--output', type=Path, required=True)
    selection = runner.add_mutually_exclusive_group()
    selection.add_argument('--batch', type=int)
    selection.add_argument('--from-batch', type=int)
    selection.add_argument('--self-check', action='store_true')
    selection.add_argument('--xctest-target')
    selection.add_argument('--ownership-only', action='store_true')
    runner.add_argument('--reference-plan', type=Path)
    sampler = commands.add_parser('snapshot')
    sampler.add_argument('pid', type=int)
    sampler.add_argument('output', type=Path)
    sampler.add_argument('suite')
    sampler.add_argument('phase')
    sampler.add_argument('sequence', type=int)
    args = parser.parse_args()
    if args.mode == 'snapshot':
        snapshot(args.pid, args.output, args.suite, args.phase, args.sequence)
    else:
        sys.exit(run(args))
