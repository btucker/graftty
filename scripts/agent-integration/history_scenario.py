"""Dense provider output through bounded native history paging."""
import json
import re
import time

from harness import Action, InvariantFailure


def history_text(rows=600):
    # Put a wide cell in each physical row, including wraps. Snapshot rows
    # containing wide cells use eight-byte words; plain ASCII misses this bug.
    body = '\n'.join(
        f'ROW-{i:06d} ' + '🧪 src/components/HistoryPanel.swift:100 ' * 6
        for i in range(rows))
    return f'BEGIN-GRAFTTY-FIXTURE\n\n{body}\n\nEND-GRAFTTY-FIXTURE'


def row_ids(text):
    return [int(value) for value in re.findall(r'ROW-(\d{6})', re.sub(r'\s+', '', text))]


def load_history(run, agent, stage):
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
    expected = list(range(run.options.rows))
    actual = row_ids(selected['selected'])
    evidence = {'observations': observations, 'selected': selected, 'expectedRows': expected,
                'actualRows': actual}
    (run.root / f'history-{agent}-{stage}.json').write_text(json.dumps(evidence, indent=2))
    if actual != expected:
        raise InvariantFailure(f'{agent} {stage}: missing, duplicate, or reordered history rows')
    run.summary['assertions'].append({'agent': agent, 'stage': stage,
                                     'contiguousHistoryRows': len(actual), 'paging': 'complete'})
    run.server.broker.command(Action('scroll', agent, {'position': 'bottom'}, client='mobile'))


def verify_source_history(run, agent):
    value = run.act(Action('verify', agent))
    (run.root / f'history-{agent}-source.json').write_text(json.dumps(value, indent=2))
    if row_ids(value['authoritativeText']) != list(range(run.options.rows)):
        raise InvariantFailure(f'{agent}: daemon has missing, duplicate, or reordered source history')
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
    initial_total = int(baseline['total'])
    initial_rows = row_ids(baseline['text'])
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
        if (int(value['total']) > initial_total and initial_rows and older_rows
                and min(older_rows) < min(initial_rows)):
            break
    else:
        raise InvariantFailure(f'{agent}: touch scrolling did not load and reveal older history')
    (run.root / f'history-{agent}-gesture.json').write_text(json.dumps(observations, indent=2))
    run.summary['assertions'].append({'agent': agent, 'gestureLoadedOlderHistory': True,
        'totalBefore': initial_total, 'totalAfter': int(value['total']),
        'firstRowBefore': min(initial_rows), 'firstRowAfter': min(older_rows)})


def run_history(run):
    run.start_mobile()
    run.phase = 'history'
    run.summary['providerModes'] = {'claude': 'classic (CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1)', 'codex': 'default'}
    run.summary['scope'] = 'Codex default and Claude classic native scrollback; mobile backfill, touch scrolling, reconnect and resize'
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
        run.wait_snapshot(agent, lambda value: run.options.rows - 1 in row_ids(value['text']))
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
