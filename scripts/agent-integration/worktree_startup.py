#!/usr/bin/env python3
"""Prove the headless wire prompt regression against an isolated CI baseline."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import signal
import sys

from worktree_ui import REPO, capture, execute

SOURCE = 'Sources/GrafttyKit/Host/HeadlessHostControl.swift'
FILTER = 'HeadlessHostRuntimeTests/headlessWireStagesStructuredAgentPrompt'
ASSERTION = 'Structured agent prompt must reach the provider argv'


def classify_red(code, log):
    return code != 0 and ASSERTION in log and 'Expectation failed' in log and 'REMOTE-22.39' in log


def classify_green(code, log):
    return code == 0 and all(re.search(r'✔ Test [^\n]*@spec ' + re.escape(spec)
                                      + r'[^\n]* passed after ', log)
                             for spec in ('REMOTE-22.38', 'REMOTE-22.39'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline', default='16287dce')
    options = parser.parse_args()
    if os.environ.get('CI', '').lower() not in ('true', '1'):
        parser.error('Baseline overlays require an isolated CI checkout (CI=true)')
    options.output.mkdir(parents=True, exist_ok=False)
    source = REPO / SOURCE
    original = source.read_bytes()
    summary = {'result': 'failed', 'currentCommit': capture(['git', 'rev-parse', 'HEAD']),
               'baselineCommit': capture(['git', 'rev-parse', options.baseline + '^{commit}']),
               'source': SOURCE, 'currentSourceSHA256': hashlib.sha256(original).hexdigest()}
    (options.output / 'source-backup.swift').write_bytes(original)
    try:
        try:
            source.write_text(capture(['git', 'show', summary['baselineCommit'] + ':' + SOURCE]) + '\n')
            summary['baselineSourceSHA256'] = hashlib.sha256(source.read_bytes()).hexdigest()
            command = ['scripts/swiftpm', 'test', '--build-system', 'native', '--filter', FILTER]
            code, _ = execute(command, timeout=1800, log=options.output / 'red.log')
            log = (options.output / 'red.log').read_text(errors='replace')
            summary['red'] = {'command': command, 'exitCode': code,
                              'passed': classify_red(code, log)}
        finally:
            source.write_bytes(original)
            summary['sourceRestored'] = source.read_bytes() == original
        if not summary['sourceRestored']:
            raise RuntimeError('Source restoration failed; refusing GREEN')
        command = ['scripts/swiftpm', 'test', '--build-system', 'native', '--filter', 'HeadlessHostRuntimeTests']
        code, _ = execute(command, timeout=1800, log=options.output / 'green.log')
        log = (options.output / 'green.log').read_text(errors='replace')
        summary['green'] = {'command': command, 'exitCode': code,
                            'passed': classify_green(code, log)}
        if summary['red']['passed'] and summary['green']['passed']:
            summary['result'] = 'passed'
    except Exception as error:
        summary['error'] = str(error)
    finally:
        (options.output / 'result.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    return 0 if summary['result'] == 'passed' else 1


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit('Interrupted by SIGTERM'))
    sys.exit(main())
