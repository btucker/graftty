"""Dense provider output through bounded native history paging."""
import json
import re
import time

from harness import Action, InvariantFailure


HISTORY_ROWS_END = 'GRAFTTY-HISTORY-ROWS-END'
ROW_PAYLOAD = '🧪 src/components/HistoryPanel.swift:100 ' * 6


def history_text(rows=600):
    # Put a wide cell in each physical row, including wraps. Snapshot rows
    # containing wide cells use eight-byte words; plain ASCII misses this bug.
    body = '\n'.join(
        f'ROW-{i:06d} ' + ROW_PAYLOAD
        for i in range(rows))
    return f'BEGIN-GRAFTTY-FIXTURE\n\n{body}\n{HISTORY_ROWS_END}\n\nEND-GRAFTTY-FIXTURE'


def row_ids(text):
    return [int(value) for value in re.findall(r'ROW-(\d{6})', re.sub(r'\s+', '', text))]


def row_records(text):
    compact = re.sub(r'\s+', '', text)
    # The explicit model-output delimiter excludes only provider UI after the
    # fixture. Never clip a row to its expected length: that hides extra wraps.
    markers = list(re.finditer(r'ROW-(\d{6})|' + HISTORY_ROWS_END, compact))
    return [(int(marker[1]), compact[marker.end():markers[index + 1].start()
             if index + 1 < len(markers) else len(compact)])
            for index, marker in enumerate(markers) if marker[1] is not None]


def require_original_content(text, rows):
    payload = re.sub(r'\s+', '', ROW_PAYLOAD)
    intact = {number for number, content in row_records(text) if content.startswith(payload)}
    if not set(range(rows)).issubset(intact):
        raise InvariantFailure('source lost original fixture row content')


def load_history(run, agent, stage):
    expected = list(range(run.options.rows))
    expected_records = row_records(history_text(run.options.rows))
    source = None
    if stage == 'resized':
        # A classic TUI can redraw transcript rows after a real PTY resize.
        # Preserve that exact source sequence; never deduplicate imported rows.
        source = run.act(Action('verify', agent))
        if HISTORY_ROWS_END not in source['authoritativeText']:
            raise InvariantFailure(f'{agent} {stage}: source fixture end marker missing')
        require_original_content(source['authoritativeText'], run.options.rows)
        expected_records = row_records(source['authoritativeText'])
        expected = row_ids(source['authoritativeText'])
        remaining = iter(expected)
        if not all(any(value == wanted for value in remaining) for wanted in range(run.options.rows)):
            raise InvariantFailure(f'{agent} {stage}: source lost original fixture rows')
    deadline = time.monotonic() + 45
    observations = []
    while time.monotonic() < deadline:
        # Exhaustive backfill uses the native binding; a short touch drag
        # advances only part of a viewport and cannot traverse this fixture.
        run.server.broker.command(Action('scroll', agent, {'position': 'top'}, client='mobile'))
        value = run.snapshot(agent, 'mobile')
        observations.append({key: value.get(key) for key in ('paging', 'total', 'offset', 'anchor')})
        if value.get('paging') in ('limit', 'pageTooLarge', 'unavailable', 'requiresRecovery'):
            raise InvariantFailure(f'{agent} {stage}: history stopped at {value["paging"]}')
        if value.get('paging') == 'complete':
            break
        time.sleep(.05)
    else:
        raise InvariantFailure(f'{agent} {stage}: history never completed: {observations[-1:]}')
    selected = run.act(Action('select', agent, client='mobile'))
    actual = row_ids(selected['selected'])
    if source is not None:
        after = run.act(Action('verify', agent))
        if row_records(after['authoritativeText']) != expected_records:
            raise InvariantFailure(f'{agent} {stage}: source changed during history verification')
    evidence = {'observations': observations, 'selected': selected, 'expectedRows': expected,
                'actualRows': actual, 'source': source, 'barrier': 'end'}
    (run.root / f'history-{agent}-{stage}.json').write_text(json.dumps(evidence, indent=2))
    if actual != expected:
        raise InvariantFailure(f'{agent} {stage}: missing, duplicate, or reordered history rows')
    if HISTORY_ROWS_END not in selected['selected']:
        raise InvariantFailure(f'{agent} {stage}: imported fixture end marker missing')
    if row_records(selected['selected']) != expected_records:
        raise InvariantFailure(f'{agent} {stage}: imported fixture row content differs from source')
    run.summary['assertions'].append({'agent': agent, 'stage': stage,
                                     'contiguousHistoryRows': len(actual), 'preservedFixtureRows': run.options.rows,
                                     'sourceSequenceMatches': True, 'paging': 'complete'})
    run.server.broker.command(Action('scroll', agent, {'position': 'bottom'}, client='mobile'))


def verify_source_history(run, agent):
    value = run.act(Action('verify', agent))
    (run.root / f'history-{agent}-source.json').write_text(json.dumps(value, indent=2))
    if row_ids(value['authoritativeText']) != list(range(run.options.rows)):
        raise InvariantFailure(f'{agent}: daemon has missing, duplicate, or reordered source history')
    if HISTORY_ROWS_END not in value['authoritativeText']:
        raise InvariantFailure(f'{agent}: daemon fixture end marker missing')
    require_original_content(value['authoritativeText'], run.options.rows)
    if int(value['total']) <= int(value['len']):
        raise InvariantFailure(f'{agent}: provider has no native terminal scrollback')
    run.summary['assertions'].append({'agent': agent, 'sourceHistoryRows': run.options.rows})


def gesture_backfill(run, agent):
    # Let initial prefetch settle before measuring page loading caused by a
    # touch drag. The held provider stream cannot add live rows in this phase.
    baseline = run.wait_snapshot(agent, lambda value: value['paging'] == 'available', 'mobile')
    stable = 0
    settle_deadline = time.monotonic() + 30
    while stable < 3:
        if time.monotonic() >= settle_deadline:
            raise InvariantFailure(f'{agent}: initial history prefetch did not settle')
        time.sleep(.35)  # More than three 100ms paging polls.
        current = run.snapshot(agent, 'mobile')
        stable = stable + 1 if current['paging'] == 'available' and current['total'] == baseline['total'] else 0
        baseline = current
    # Read the complete loaded buffer without moving the viewport. A live
    # spinner can add rows while the model is held, so total growth plus an
    # older visible row is insufficient: cross the oldest *loaded* marker.
    loaded = run.act(Action('loadedHistory', agent, client='mobile'))
    after_read = run.snapshot(agent, 'mobile')
    keys = ('historyGeneration', 'issuedHistoryRequests', 'importedHistoryPages')
    if (any(after_read[key] != baseline[key] for key in keys)
            or int(after_read['offset']) < int(baseline['offset'])):
        raise InvariantFailure(f'{agent}: reading loaded history changed the page boundary or viewport')
    baseline = after_read
    initial_total = int(baseline['total'])
    initial_rows = row_ids(loaded['loadedHistory'])
    if int(baseline['total']) <= int(baseline['len']) or not initial_rows or min(initial_rows) == 0:
        raise InvariantFailure(f'{agent}: no unloaded older-row boundary for the gesture')
    observations = [baseline]
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        run.act(Action('scroll', agent, {'position': 'top'}, client='gestures'))
        value = run.snapshot(agent, 'mobile')
        observations.append(value)
        if value['paging'] in ('limit', 'pageTooLarge', 'unavailable', 'requiresRecovery'):
            raise InvariantFailure(f'{agent}: gesture backfill stopped at {value["paging"]}')
        older_rows = row_ids(value['text'])
        if value['historyGeneration'] != baseline['historyGeneration']:
            raise InvariantFailure(f'{agent}: checkpoint changed during gesture evidence')
        if (int(value['total']) > initial_total and older_rows
                and min(older_rows) < min(initial_rows)
                and int(value['issuedHistoryRequests']) > int(baseline['issuedHistoryRequests'])
                and int(value['importedHistoryPages']) > int(baseline['importedHistoryPages'])):
            break
    else:
        raise InvariantFailure(f'{agent}: touch scrolling did not load and reveal older history')
    (run.root / f'history-{agent}-gesture.json').write_text(json.dumps(observations, indent=2))
    run.summary['assertions'].append({'agent': agent, 'gestureLoadedOlderHistory': True,
        'totalBefore': initial_total, 'totalAfter': int(value['total']),
        'oldestLoadedRowBefore': min(initial_rows), 'firstRowAfter': min(older_rows),
        'requestsBefore': int(baseline['issuedHistoryRequests']), 'requestsAfter': int(value['issuedHistoryRequests']),
        'importsBefore': int(baseline['importedHistoryPages']), 'importsAfter': int(value['importedHistoryPages'])})


def run_history(run):
    run.start_mobile()
    run.phase = 'history'
    run.summary['providerModes'] = {'claude': 'classic (CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1)',
        'codex': 'inline (--no-alt-screen; tui.terminal_resize_reflow_max_rows=10000)'}
    run.summary['scope'] = 'Codex inline and Claude classic native scrollback; mobile backfill, touch scrolling, reconnect and resize'
    models = run.server.models
    models.fixture_text = history_text
    for agent in ('claude', 'codex'):
        run.paths[agent] = run.act(Action('start', agent, {'history': 'true'}))
        deadline = time.monotonic() + 90
        reviewed = False
        while (agent, 'begin') not in models.arrived:
            if time.monotonic() >= deadline:
                raise InvariantFailure(f'{agent} did not start its model stream')
            value = run.snapshot(agent)
            if 'Hooks need review' in value['text'] and not reviewed:
                run.act(Action('input', agent, {'text': '2'}))
                reviewed = True
            time.sleep(.05)
        for barrier, following in (('begin', 'middle'), ('middle', 'end')):
            models.release(agent, barrier)
            run.wait_model(lambda: (agent, following) in models.arrived)
        run.wait_snapshot(agent, lambda value: HISTORY_ROWS_END in value['text']
                          and run.options.rows - 1 in row_ids(value['text']))
        verify_source_history(run, agent)
        # Connect after output exists: attaching before streaming would parse
        # VT locally and never exercise the failing host history-page export.
        run.act(Action('connect', agent, {'session': run.paths[agent]['session']}, client='mobile'))
        run.converge(agent)
        gesture_backfill(run, agent)
        load_history(run, agent, 'attach')
        before = run.snapshot(agent, 'mobile')
        run.act(Action('scroll', agent, {'position': 'middle'}, client='gestures'))
        after = run.wait_snapshot(agent, lambda value: value['offset'] != before['offset'], 'mobile')
        run.summary['assertions'].append({'agent': agent, 'gestureScrollOffsets': [before['offset'], after['offset']]})
        run.act(Action('reconnect', agent, client='mobile'))
        run.converge(agent)
        load_history(run, agent, 'reconnect')
        run.act(Action('takeControl', agent, client='mobile'))
        run.act(Action('resize', agent, {'width': '852', 'height': '393'}, client='mobile'))
        run.converge(agent)
        run.act(Action('reconnect', agent, client='mobile'))
        run.converge(agent)
        load_history(run, agent, 'resized')
        models.release(agent, 'end')
        run.wait_model(lambda: (agent, 'recap') in models.arrived)
        models.release(agent, 'recap')
        run.act(Action('takeControl', agent))
        run.wait_model(lambda: agent in models.recaps_done)
