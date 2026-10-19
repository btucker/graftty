"""Quick Look lifecycle against genuine provider TUIs and authenticated SSH panes."""
import hashlib
import json
import re
import time
import uuid

from harness import Action, InvariantFailure
from model import reentry_scenario_text

IDENTITIES = ('session', 'clientID', 'containerID', 'surfaceID', 'channelID', 'channelOpens',
              'ownerIdentity', 'owner', 'epoch', 'revision', 'grid', 'nativeGrid',
              'attachmentID', 'navigationID', 'channelCloses')


def require_continuity(before, after, *, covered=False):
    for key in IDENTITIES:
        if not before.get(key) or not after.get(key) or before[key] != after[key]:
            raise InvariantFailure(f'Quick Look changed or lost {key}: {before.get(key)} -> {after.get(key)}')
    if after.get('connection') != 'live' or after.get('terminalContained') != 'true' or after.get('sourceControllerAttached') != 'true':
        raise InvariantFailure('Quick Look detached or disconnected the source terminal')
    if before.get('terminalMounted') != 'true' or after.get('terminalMounted') not in ('true', 'false'):
        raise InvariantFailure('Source terminal window evidence missing')
    if not covered and after.get('terminalMounted') != 'true':
        raise InvariantFailure('Source terminal is not visible after Quick Look dismissal')
    if covered and after.get('quickLook') != 'true':
        raise InvariantFailure('Quick Look did not cover the attached source controller')
    if after.get('previewOwnerIdentity') != after.get('ownerIdentity'):
        raise InvariantFailure('Preview offer scope differs from authenticated terminal owner')
    if after.get('grid') != after.get('nativeGrid') or after.get('parserGridMatches') != 'true':
        raise InvariantFailure('Quick Look native/parser grid does not match the authoritative grid')
    if after.get('pagedGridMismatches') != '' or after.get('channelCloses') != '0':
        raise InvariantFailure('Quick Look damaged the parser grid or closed the SSH channel')
    if after.get('quickLook') not in ('true', 'false'):
        raise InvariantFailure('Quick Look presentation diagnostic missing')


def require_matrix(cases):
    expected = {(provider, retained, embedded) for provider in ('claude', 'codex')
                for retained in (False, True) for embedded in (False, True)}
    actual = [(case['provider'], case['retained'], case['embedded']) for case in cases]
    if len(actual) != len(expected) or set(actual) != expected or not all(case.get('passed') for case in cases):
        raise InvariantFailure('Quick Look requires eight passing provider/retention/presentation cases')


def require_tracked_preview_sources():
    from run import execute
    untracked = execute(['git', 'ls-files', '--others', '--exclude-standard', '--',
                         'Sources', 'Tests', 'Apps', 'scripts/agent-integration'])
    if untracked.strip():
        raise InvariantFailure('Stage new integration source files before running preview validation: ' + untracked)


def run_preview(run):
    from run import execute
    run.start_mobile()
    run.phase = 'preview'
    run.summary['scope'] = 'Production mobile Quick Look with real provider input and SSH terminal continuity'
    run.summary['providerModes'] = {'claude': 'classic; manual approvals (--permission-mode manual, permissions.defaultMode=default; CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1)',
                                  'codex': 'inline (--no-alt-screen; tui.terminal_resize_reflow_max_rows=10000)'}
    run.summary['previewCases'] = cases = []
    models = run.server.models
    models.fixture_text = reentry_scenario_text
    for agent in ('claude', 'codex'):
        run.paths[agent] = run.act(Action('start', agent, {'history': 'true'}))
        deadline, reviewed = time.monotonic() + 90, False
        while (agent, 'begin') not in models.arrived:
            if time.monotonic() >= deadline:
                raise InvariantFailure(f'{agent} never requested its scripted endpoint')
            value = run.snapshot(agent)
            if 'Hooks need review' in value['text'] and not reviewed:
                run.act(Action('input', agent, {'text': '2'}))
                reviewed = True
            time.sleep(.05)
        for barrier, following in (('begin', 'middle'), ('middle', 'end')):
            models.release(agent, barrier)
            run.wait_model(lambda: (agent, following) in models.arrived)
        models.release(agent, 'end')
        run.wait_model(lambda: agent in models.completed)
        models.release(agent, 'recap')
        run.wait_model(lambda: agent in models.recaps_done)
        for retained in (False, True):
            for embedded in (False, True):
                nonce = uuid.uuid4().hex
                case = {'provider': agent, 'retained': retained, 'embedded': embedded,
                        'nonce': nonce, 'passed': False}
                cases.append(case)
                args = {'session': run.paths[agent]['session'], 'worktree': run.paths[agent]['path'],
                        'retained': str(retained).lower(), 'embedded': str(embedded).lower()}
                run.act(Action('previewPrepare', agent, args, client='mobile'))
                # Input passes through XCUITest and the production terminal keyboard.
                run.act(Action('previewInput', agent, {'text': 'GRAFTTY_TEST_PREVIEW ' + nonce}, client='gestures'))
                phase = 'preview:' + nonce
                run.wait_model(lambda: (agent, phase + ':begin') in models.arrived)
                run.act(Action('previewHideKeyboard', agent, client='gestures'))
                before = run.act(Action('previewSnapshot', agent, client='mobile'))
                run.act(Action('previewOpen', agent, client='gestures'))
                during = run.act(Action('previewSnapshot', agent, client='mobile'))
                require_continuity(before, during, covered=True)
                if during['quickLook'] != 'true' or int(during.get('previewReads', 0)) < 1:
                    raise InvariantFailure('Production Quick Look did not download and mount its native preview')
                for barrier, following in (('begin', 'middle'), ('middle', 'end')):
                    models.release(agent, phase + ':' + barrier)
                    run.wait_model(lambda: (agent, phase + ':' + following) in models.arrived)
                deadline = time.monotonic() + 30
                marker = 'PREVIEW-OUTPUT-' + nonce
                while True:
                    output = run.act(Action('previewSnapshot', agent, client='mobile'))
                    require_continuity(before, output, covered=True)
                    if marker in output.get('loadedHistory', ''):
                        break
                    if time.monotonic() >= deadline:
                        raise InvariantFailure('Provider output did not reach the original renderer during Quick Look')
                    time.sleep(.1)
                run.act(Action('previewCapture', agent, client='gestures'))
                image_prefix = f'preview-{agent}-{retained}-{embedded}'
                execute(['xcrun', 'simctl', 'io', run.simulator, 'screenshot', str(run.root / (image_prefix + '-open.png'))])
                run.act(Action('previewDismiss', agent, client='gestures'))
                after = run.act(Action('previewSnapshot', agent, client='mobile'))
                require_continuity(before, after)
                execute(['xcrun', 'simctl', 'io', run.simulator, 'screenshot', str(run.root / (image_prefix + '-dismissed.png'))])
                if after['quickLook'] != 'false' or marker not in after.get('loadedHistory', ''):
                    raise InvariantFailure('Quick Look dismissal lost native terminal output or retained the preview')
                if any(marker not in re.sub(r'\s+', '', after.get(key, '')) for key in ('physicalRows', 'text')):
                    raise InvariantFailure('Fresh provider output is not visible in native rows after Quick Look dismissal')
                before_rows = set(before.get('loadedHistory', '').splitlines())
                prior_markers = {row for row in before_rows if 'ROW-' in row or 'PREVIEW-OUTPUT-' in row}
                if not prior_markers or not prior_markers.issubset(set(after['loadedHistory'].splitlines())):
                    raise InvariantFailure('Quick Look lost previously loaded native history rows')
                post_nonce = uuid.uuid4().hex
                run.act(Action('previewInput', agent, {'text': 'GRAFTTY_TEST_PREVIEW_ACK ' + post_nonce}, client='gestures'))
                run.act(Action('previewHideKeyboard', agent, client='gestures'))
                models.release(agent, phase + ':end')
                run.wait_model(lambda: (agent, phase) in models.completed_streams)
                if (agent, nonce, 'preview') not in models.receipts:
                    raise InvariantFailure('Native prompt receipt missing')
                # All Quick Look continuity assertions are complete. Return
                # ownership to the native Mac approval driver before the real
                # provider Stop hook asks it to run the recap tool.
                run.act(Action('takeControl', agent))
                run.wait_model(lambda: (agent, 'preview-ack:' + post_nonce) in models.completed_streams)
                run.wait_model(lambda: (agent, post_nonce) in models.completed_preview_recaps)
                case.update(before=before, during=during, output=output, after=after,
                            inputReceiptBefore=models.receipts[(agent, nonce, 'preview')],
                            inputReceiptAfter=models.receipts[(agent, post_nonce, 'preview-ack')])
                # Native Back removes the production route; retained and transient
                # panes must both lose input controls after the real navigation.
                run.act(Action('previewBack', agent, client='gestures'))
                removed = run.act(Action('previewRemoved', agent, client='mobile'))
                if removed.get('navigationRemoved') != 'true' or removed.get('terminalMounted') != 'false':
                    raise InvariantFailure('Back navigation did not remove the production terminal')
                if retained:
                    if removed.get('controlsDetached') != 'true' or removed.get('channelCloses') != '0':
                        raise InvariantFailure('Retained pane lost its channel or retained stale controls after Back')
                elif removed.get('channelCloses') != '1' or removed.get('ownershipCleared') != 'true' or removed.get('browserDetached') != 'true':
                    raise InvariantFailure('Transient pane did not close its real channel and release browser ownership after Back')
                case.update(removed=removed, passed=True)
                (run.root / f'preview-{agent}-{retained}-{embedded}.json').write_text(json.dumps(case, indent=2))
                run.summary['assertions'].append({'provider': agent, 'previewCase': nonce,
                    'nativeInputReceipt': True, 'activeOutputDuringQuickLook': True, 'retained': retained,
                    'embedded': embedded, 'continuity': list(IDENTITIES)})
    require_matrix(cases)


def validate_native_results(run):
    """Require actual XCTest execution and durable native evidence, not exit 0."""
    from worktree_ui import read_result
    from run import execute
    directory = run.root / 'preview-native-results'
    directory.mkdir(exist_ok=True)
    bundle = run.root / 'mobile.xcresult'
    records, errors, failures = read_result(bundle, directory)
    run.summary['nativeTestResults'] = {'executed': len(records), 'records': records,
                                       'errors': errors, 'failures': failures}
    required = [record for record in records if 'AgentNativeInteractionTests/testNativeQuickLookRetention' in record['id']]
    if len(required) != 1 or required[0]['status'] != 'Success' or errors or failures:
        raise InvariantFailure('Quick Look XCUITest missing, skipped, duplicated or failed')
    require_matrix(run.summary.get('previewCases', []))
    attachments = directory / 'attachments'
    execute(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(bundle), '--output-path', str(attachments)])
    screenshots = sorted(attachments.rglob('*.png'))
    if len(screenshots) < 48:
        raise InvariantFailure('Quick Look XCUITest screenshot evidence incomplete')
    run.summary['nativeScreenshots'] = [str(path.relative_to(run.root)) for path in screenshots]
    for case in run.summary['previewCases']:
        prefix = f"preview-{case['provider']}-{case['retained']}-{case['embedded']}"
        for suffix in ('open', 'dismissed'):
            path = run.root / f'{prefix}-{suffix}.png'
            if not path.is_file() or not path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'):
                raise InvariantFailure('Missing native Quick Look visual evidence: ' + path.name)
