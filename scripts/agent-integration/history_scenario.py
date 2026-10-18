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
        value = run.act(Action('scroll', agent, {'position': 'top'}, client='mobile'))
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
    run.act(Action('scroll', agent, {'position': 'bottom'}, client='mobile'))


def run_history(run):
    run.start_mobile()
    run.phase = 'history'
    run.summary['scope'] = 'Codex and Claude dense wide output; native mobile backfill, scrolling, reconnect and resize'
    models = run.server.models
    models.fixture_text = history_text
    for agent in ('claude', 'codex'):
        run.paths[agent] = run.act(Action('start', agent))
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
        # Connect after output exists: attaching before streaming would parse
        # VT locally and never exercise the failing host history-page export.
        run.act(Action('connect', agent, {'session': run.paths[agent]['session']}, client='mobile'))
        run.converge(agent)
        load_history(run, agent, 'attach')
        run.act(Action('scroll', agent, {'position': 'middle'}, client='gestures'))
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
