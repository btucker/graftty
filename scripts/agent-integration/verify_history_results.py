"""Fail closed on missing or incomplete focused history validation evidence."""
import argparse
import json
from pathlib import Path
import re


def verify_swift(directory):
    red = (directory / 'red.log').read_text()
    green = (directory / 'green.log').read_text()
    if not re.search(r'Test run with 1 test in 1 suite failed .* with 1 issue', red):
        raise ValueError('RED must execute exactly one test with one intended issue')
    if 'Dense history must arrive as a bounded page, not a host limit refusal' not in red:
        raise ValueError('RED did not reproduce the host page refusal')
    match = re.search(r'Test run with (\d+) tests in 2 suites passed', green)
    if not match or int(match[1]) < 18:
        raise ValueError('GREEN did not execute the required focused suites')
    for spec in ('TERM-12.43', 'TERM-12.44', 'TERM-12.45'):
        if not re.search(r'✔ Test "@spec ' + re.escape(spec) + r':[^\n]+ passed after', green):
            raise ValueError(f'GREEN did not execute and pass {spec}')


def verify_provider_result(path):
    result = json.loads(path.read_text())
    if result.get('result') != 'passed':
        raise ValueError(f'Provider scenario did not pass: {path}')
    assertions = result.get('assertions', [])
    for agent in ('claude', 'codex'):
        values = [value for value in assertions if value.get('agent') == agent]
        if not any(value.get('sourceHistoryRows') == 600 for value in values):
            raise ValueError(f'{agent}: missing authoritative source history')
        if not any(value.get('gestureLoadedOlderHistory') is True for value in values):
            raise ValueError(f'{agent}: missing real gesture backfill')
        for stage in ('attach', 'reconnect', 'resized'):
            if not any(value.get('stage') == stage and value.get('contiguousHistoryRows') == 600
                       and value.get('paging') == 'complete' for value in values):
                raise ValueError(f'{agent}: missing contiguous history at {stage}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift', type=Path)
    parser.add_argument('--results', nargs='+', type=Path)
    options = parser.parse_args()
    if not options.swift and not options.results:
        parser.error('provide --swift or --results')
    if options.swift:
        verify_swift(options.swift)
    for path in options.results or []:
        verify_provider_result(path)
