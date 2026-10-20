"""Real provider Stop hooks, isolated native delivery, and notification activation."""
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
import time
import uuid

from harness import Action, InvariantFailure
from model import user_text
from run import REPO, Run, execute


def notification_scenario_text(rows=100):
    # Keep enough transcript to distinguish provider virtualization from
    # terminal history. No classic-mode override is used by this scenario.
    from history_scenario import history_text
    return history_text(max(rows, 600))


def verify_attention_isolation(root, cli, env, command=execute):
    expected = (root / 'attention').resolve()
    env['GRAFTTY_ATTENTION_DIR'] = str(expected)
    # An older CLI silently ignores unknown environment variables. Require its
    # read-only diagnostic before any provider hook can write a handoff file.
    actual = command([str(cli), 'attention', 'directory'], env=env)
    if not actual.startswith('/') or Path(actual).resolve() != expected:
        raise InvariantFailure(f'CLI attention isolation mismatch: expected={expected}, actual={actual!r}')


def assert_notification_evidence(observation, provider, worktree, expected):
    try:
        events = json.loads(observation['events'])
        attempts = json.loads(observation['attempts'])
        if len(events) != expected or len(attempts) != expected or int(observation['postedCount']) != expected:
            raise InvariantFailure(f'{provider} stop/delivery count differs from {expected}: {observation}')
        occurrences = set()
        for event, attempt in zip(events, attempts):
            if event['runtime'] != provider or event['worktree'] != worktree:
                raise InvariantFailure('captured stop belongs to another provider/worktree')
            if not all(event.get(key) for key in ('agentID', 'sessionID', 'paneSessionName', 'recap')):
                raise InvariantFailure('provider stop lacks real session, pane, or recap evidence')
            identity = (event['runtime'], event['sessionID'], event['stoppedAt'])
            if identity in occurrences:
                raise InvariantFailure('two captured files represent the same stop occurrence')
            occurrences.add(identity)
            info = attempt['userInfo']
            if (info.get('runtime') != provider or info.get('worktree_path') != worktree
                    or info.get('session_id') != event['sessionID']
                    or info.get('pane_session_name') != event['paneSessionName']):
                raise InvariantFailure('native request lost its provider/worktree/session/pane route')
            recap = event['recap']
            if (not attempt['identifier'] or attempt['title'] != recap['title']
                    or attempt['body'] != (recap.get('need') or recap.get('completed'))):
                raise InvariantFailure('native request lost its useful purpose or recap')
        return events
    except (KeyError, ValueError, TypeError) as error:
        raise InvariantFailure('native notification evidence is missing or malformed') from error


class NotificationRun(Run):
    def __init__(self, options, actions=None):
        super().__init__(options, actions)
        self.summary['scope'] = ('Real Claude and Codex Stop hooks and isolated Mac delivery attempts'
            if options.mac_only else 'Real Claude and Codex Stop hooks, Mac delivery attempts, and native iOS notification activation')
        self.notification_actions = []
        self.summary['notificationCase'] = options.notification_case
        self.server.models.fixture_text = notification_scenario_text
        nonce = uuid.uuid4().hex[:8]
        self.markers = {provider: f'NOTIFY_{provider.upper()}_{nonce}' for provider in ('claude', 'codex')}
        self.server.models.completion_text = lambda provider: self.markers[provider]
        self.summary['sessionMarkers'] = self.markers

    def spawn(self, command, env, name):
        self.summary.setdefault('effectiveNativeCommands', []).append({'name': name, 'arguments': list(map(str, command))})
        return super().spawn(command, env, name)

    def record_simulator(self, device, runtime):
        runtimes = json.loads(execute(['xcrun', 'simctl', 'list', 'runtimes', '--json']))
        selected = next((item for item in runtimes['runtimes'] if item['identifier'] == runtime), None)
        if not selected or not selected.get('version') or not device.get('deviceTypeIdentifier'):
            raise InvariantFailure('selected Simulator lacks runtime version or device type provenance')
        self.summary['simulator'] = {'udid': device['udid'], 'name': device['name'],
            'deviceTypeIdentifier': device['deviceTypeIdentifier'], 'runtimeIdentifier': runtime,
            'runtimeVersion': selected['version'], 'runtimeBuild': selected.get('buildversion')}

    def record_executable_provenance(self):
        binaries = {}
        for name in ('cli', 'zmx'):
            path = getattr(self.options, name)
            with path.open('rb') as binary:
                digest = hashlib.file_digest(binary, 'sha256').hexdigest()
            binaries[name] = {'path': str(path), 'sha256': digest}
        self.summary['executables'] = binaries

    def configure_fixture(self, manifest):
        verify_attention_isolation(self.root, self.options.cli, self.env)
        manifest['scenario'] = 'notifications'
        self.summary['testedCommit'] = execute(['git', 'rev-parse', 'HEAD'])
        patch = execute(['git', 'diff', '--binary', 'HEAD'])
        (self.root / 'tested.patch').write_text(patch)
        self.summary['testedDiffSHA256'] = hashlib.sha256(patch.encode()).hexdigest()
        untracked = execute(['git', 'ls-files', '--others', '--exclude-standard']).splitlines()
        # New fixture files are not in git diff until committed. Record their
        # exact bytes too, without traversing build caches or unrelated files.
        source_hashes = {}
        for relative in untracked:
            if relative.startswith(('Sources/', 'Tests/', 'Apps/', 'scripts/')):
                path = REPO / relative
                if path.is_file() and not path.is_symlink():
                    source_hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.summary['untrackedSourceSHA256'] = source_hashes
        self.summary['attentionDirectory'] = self.env['GRAFTTY_ATTENTION_DIR']

    def act(self, action):
        self.notification_actions.append(asdict(action))
        (self.root / 'actions.json').write_text(json.dumps(self.notification_actions, indent=2))
        return super().act(action)

    def evidence(self, provider, stage, operation='notificationsSnapshot', parameters=None):
        value = self.act(Action(operation, provider, parameters or {}))
        (self.root / f'notifications-{provider}-{stage}.json').write_text(json.dumps(value, indent=2))
        return value

    def wait_stops(self, provider, count, timeout=60):
        deadline = time.monotonic() + timeout
        settle_at = None
        while time.monotonic() < deadline:
            self.approve_known_tools()
            value = self.evidence(provider, f'stop-{count}')
            if len(json.loads(value['events'])) >= count:
                now = time.monotonic()
                if settle_at is None:
                    settle_at = now + 1
                if now >= settle_at:
                    return value
            time.sleep(.1)
        raise InvariantFailure(f'{provider} did not emit {count} genuine Stop handoff files')

    def assert_stops(self, provider, value, count, stage):
        events = assert_notification_evidence(value, provider, self.paths[provider]['path'], count)
        self.summary['assertions'].append({'provider': provider, 'stage': stage,
            'providerStopFiles': len(events), 'nativeDeliveryAttempts': int(value['postedCount'])})
        return events

    def replay(self, provider, events, count, stage):
        parameters = {'events': json.dumps(events), 'copies': '3'}
        value = self.evidence(provider, stage, 'notificationsReplay', parameters)
        self.assert_stops(provider, value, count, stage)

    def model_prompt_receipt(self, provider, prompt):
        receipt = None
        with self.server.broker.lock:
            for event in self.server.broker.events:
                if event.get('kind') != 'model-request' or event.get('agent') != provider:
                    continue
                occurrences = user_text(event['body'], markers_only=True).count(prompt)
                if occurrences > 1:
                    raise InvariantFailure(f'{provider} received the next-stop prompt more than once')
                if occurrences == 1 and receipt is None:
                    receipt = {'requestID': event['requestID'], 'occurrences': occurrences}
        return receipt

    def submit_next_stop(self, provider):
        prompt = f'GRAFTTY_TEST_NEXT_STOP {provider} {uuid.uuid4().hex}'
        self.act(Action('input', provider, {'text': prompt, 'submit': 'false'}))
        self.wait_snapshot(provider, lambda value: prompt in value['text'])
        # Codex 0.162.1 treats Enter within 120 ms of a paste burst as a
        # newline. Let the observed text settle before one separate Return.
        time.sleep(.25)
        self.act(Action('input', provider))
        self.wait_model(lambda: self.model_prompt_receipt(provider, prompt) is not None)
        self.summary['assertions'].append({'provider': provider, 'nextStopPrompt': prompt,
            'nextStopSubmission': self.model_prompt_receipt(provider, prompt)})
        return prompt

    def scenarios(self):
        self.phase = 'notifications'
        # The native test build has completed now; fingerprint the executables
        # the provider commands actually use, after any SwiftPM rebuild.
        self.record_executable_provenance()
        if not self.options.mac_only:
            self.start_mobile()
        models = self.server.models
        provider_events = self.provider_events = {}
        next_stop_prompts = {}
        for provider in ('claude', 'codex'):
            self.paths[provider] = self.act(Action('start', provider,
                {'history': 'true'} if self.options.notification_case == 'scrollback-classic' else {}))
            deadline = time.monotonic() + 60
            reviewed = False
            while (provider, 'begin') not in models.arrived:
                if time.monotonic() >= deadline:
                    raise InvariantFailure(f'{provider} notification fixture did not start')
                if 'Hooks need review' in self.snapshot(provider)['text'] and not reviewed:
                    self.act(Action('input', provider, {'text': '2'}))
                    reviewed = True
                time.sleep(.1)
            for phase in ('begin', 'middle', 'end'):
                self.wait_model(lambda: (provider, phase) in models.arrived)
                models.release(provider, phase)
            self.wait_model(lambda: (provider, 'recap') in models.arrived)
            models.release(provider, 'recap')
            self.wait_model(lambda: provider in models.recaps_done)
            first = self.assert_stops(provider, self.wait_stops(provider, 1), 1, 'genuine-first-stop')
            self.record_provider_screen(provider, 1)
            self.replay(provider, first, 1, 'repeated-first-stop')
            next_stop_prompts[provider] = self.submit_next_stop(provider)
            events = self.assert_stops(provider, self.wait_stops(provider, 2), 2, 'genuine-second-stop')
            self.record_provider_screen(provider, 2)
            self.replay(provider, events, 2, 'repeated-both-stops')
            (self.root / f'provider-stops-{provider}.json').write_text(json.dumps(events, indent=2))
            provider_events[provider] = events
        # Capture both real providers before entering lifecycle gestures, so a
        # mobile failure retains useful evidence from each provider.
        if not self.options.mac_only:
            for provider, events in provider_events.items():
                if self.options.notification_case.startswith('scrollback'):
                    self.scrollback_scenarios(provider, events)
                else:
                    if self.options.notification_case == 'all':
                        self.mobile_scenarios(provider, events)
                    self.active_retry_scenario(provider, events)
        # Catch delayed files that arrived while the native mobile scenarios
        # were running, including files from the earlier provider.
        for provider in ('claude', 'codex'):
            self.assert_stops(provider, self.evidence(provider, 'final'), 2, 'final-provider-count')
            self.model_prompt_receipt(provider, next_stop_prompts[provider])

    def scrollback_scenarios(self, provider, events):
        from history_scenario import gesture_backfill, load_history, row_ids
        classic = self.options.notification_case == 'scrollback-classic'
        self.summary['providerModes'] = ({'claude': 'classic (CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1)',
            'codex': 'inline (--no-alt-screen)'} if classic else {'claude': 'default', 'codex': 'default'})
        prepared = self.prepare_mobile_notifications(provider, events, 'warm')
        self.deliver_mobile_stop(provider, 0, 1)
        self.tap_mobile_notification(provider, prepared)
        selected = self.wait_mobile_route(provider, prepared)
        source = self.act(Action('verify', provider))
        (self.root / f'notifications-{provider}-source-history.json').write_text(json.dumps(source, indent=2))
        if classic:
            gesture_backfill(self, provider)
            load_history(self, provider, 'notification-attach', contemporaneous=True)
            self.act(Action('reconnect', provider, client='mobile'))
            self.wait_mobile_notification(provider, lambda value: value['live'] == 'true'
                and value['historyGeneration'] != selected['historyGeneration']
                and value['paging'] not in ('inactive', 'installing'))
            load_history(self, provider, 'notification-reconnect', contemporaneous=True)
        else:
            before = self.snapshot(provider, 'mobile')
            for _ in range(3):
                self.act(Action('scroll', provider, {'position': 'top'}, client='gestures'))
            after = self.snapshot(provider, 'mobile')
            self.summary['assertions'].append({'provider': provider, 'defaultModeScroll': {
                'sourceRows': row_ids(source['authoritativeText']), 'before': before, 'after': after}})
        self.summary['assertions'].append({'provider': provider, 'notificationEntry': True,
            'historyCoverage': 'classic history verified' if classic else 'default diagnostic only', 'selection': selected})

    def record_provider_screen(self, provider, stop):
        value = self.act(Action('verify', provider))
        (self.root / f'notifications-{provider}-native-stop-{stop}.json').write_text(json.dumps(value, indent=2))

    def mobile_scenarios(self, provider, events):
        # The app fixture consumes these captured production events, including
        # their original provider/session identity and timestamps.
        # Input requests use controlled prompt snapshots with captured pane and
        # occurrence identities; they are not provider permission-hook evidence.
        prepared = self.prepare_mobile_notifications(provider, events, 'input')
        self.deliver_mobile_stop(provider, 0, 1)
        self.tap_mobile_notification(provider, prepared)
        selected = self.wait_mobile_route(provider, prepared)
        before = self.act(Action('notificationsState', provider, client='mobile'))
        source = self.act(Action('verify', provider))
        for _ in range(3):
            self.act(Action('scroll', provider, {'position': 'top'}, client='gestures'))
        after = self.act(Action('notificationsState', provider, client='mobile'))
        (self.root / f'notifications-{provider}-scroll-probe.json').write_text(json.dumps(
            {'before': before, 'after': after, 'source': source}, indent=2))
        self.deliver_mobile_stop(provider, 1, 2)
        self.summary['assertions'].append({'provider': provider, 'mobileControlledInputActivation': selected,
            'mobileControlledInputRequestCount': 2})

        prepared = self.prepare_mobile_notifications(provider, events, 'warm', hold=True)
        self.deliver_mobile_stop(provider, 0, 1)
        self.tap_mobile_notification(provider, prepared)
        pending = self.wait_mobile_notification(provider, lambda value: value['pending'] == 'true')
        if int(pending['fetchCount']) != 1:
            raise InvariantFailure('notification tap started repeated host fetches')
        self.act(Action('notificationsRelease', provider, client='mobile'))
        selected = self.wait_mobile_route(provider, prepared)
        self.deliver_mobile_stop(provider, 1, 2)
        self.summary['assertions'].append({'provider': provider, 'mobileWarmActivation': selected,
            'mobileDistinctStopCount': 2})

        for lifecycle in ('background', 'cold'):
            prepared = self.prepare_mobile_notifications(provider, events, lifecycle)
            self.deliver_mobile_stop(provider, 0, 1)
            self.tap_mobile_notification(provider, prepared, lifecycle)
            selected = self.wait_mobile_route(provider, prepared)
            self.summary['assertions'].append({'provider': provider, 'mobileLifecycle': lifecycle, 'selection': selected})

        prepared = self.prepare_mobile_notifications(provider, events, 'warm', hold=True)
        self.deliver_mobile_stop(provider, 0, 1)
        self.tap_mobile_notification(provider, prepared)
        self.wait_mobile_notification(provider, lambda value: value['pending'] == 'true')
        self.act(Action('notificationsNavigate', provider, client='gestures'))
        self.act(Action('notificationsRelease', provider, client='mobile'))
        selected = self.wait_mobile_notification(provider, lambda value: value['pending'] == 'false'
            and value['pane'] == prepared['unrelatedPane'])
        # Recheck after another native command-loop turn so an already queued
        # activation completion cannot hide behind the first selection sample.
        time.sleep(.5)
        selected = self.act(Action('notificationsState', provider, client='mobile'))
        if selected['pane'] != prepared['unrelatedPane'] or selected['pending'] != 'false':
            raise InvariantFailure('delayed notification navigation overwrote a later user selection')
        self.summary['assertions'].append({'provider': provider, 'mobileUserSelectionPreserved': selected,
            'scope': 'route-state cancellation only; sibling navigation is not mounted by this control'})

        for mode in ('ambiguous', 'disconnected'):
            prepared = self.prepare_mobile_notifications(provider, events, mode)
            self.deliver_mobile_stop(provider, 0, 1)
            self.tap_mobile_notification(provider, prepared)
            error = self.act(Action('notificationsDismissError', provider, client='gestures'))
            if error.get('errorTitle') != 'Could not open notification' or not error.get('errorMessage'):
                raise InvariantFailure(f'{mode} notification did not show a useful native error: {error}')
            state = self.act(Action('notificationsState', provider, client='mobile'))
            if state['pane']:
                raise InvariantFailure(f'{mode} notification silently opened an arbitrary pane')
            if mode == 'disconnected':
                self.act(Action('notificationsRelease', provider, client='mobile'))
                # iOS removes an alert after its default action. A second real
                # stop supplies a new native alert for retrying the same route.
                prepared = self.deliver_mobile_stop(provider, 1, 2)
                self.tap_mobile_notification(provider, prepared)
                state = self.wait_mobile_route(provider, prepared)
            self.summary['assertions'].append({'provider': provider, 'mobileFailureMode': mode,
                'nativeError': error, 'state': state})

    def active_retry_scenario(self, provider, events):
        prepared = self.prepare_mobile_notifications(provider, events, 'active-retry')
        self.deliver_mobile_stop(provider, 0, 1)
        self.tap_mobile_notification(provider, prepared)
        error = self.act(Action('notificationsDismissError', provider, client='gestures'))
        if error.get('errorTitle') != 'Could not open notification' or not error.get('errorMessage'):
            raise InvariantFailure(f'active retry did not report its first fetch failure: {error}')
        first = self.act(Action('notificationsState', provider, client='mobile'))
        (self.root / f'notifications-{provider}-active-retry-first.json').write_text(json.dumps(first, indent=2))
        self.assert_active_retry(first, responses=1, fetches=1)
        if first['pane']:
            raise InvariantFailure('failed fetch opened an unrelated pane')
        self.act(Action('notificationsRelease', provider, client='mobile'))
        prepared = self.deliver_mobile_stop(provider, 1, 2)
        self.tap_mobile_notification(provider, prepared)
        second = self.wait_mobile_notification(provider, lambda value: int(value['responseCount']) >= 2)
        (self.root / f'notifications-{provider}-active-retry-response.json').write_text(json.dumps(second, indent=2))
        self.assert_active_retry(second, responses=2)
        if first['sceneProbeIDs'] != second['sceneProbeIDs']:
            raise InvariantFailure('active retry remounted its production RootView')
        # A second real OS response, without any production scene transition,
        # must cause a fresh fetch. A foreground retry cannot satisfy this gate.
        attempted = self.wait_mobile_notification(provider, lambda value: int(value['fetchCount']) >= 2)
        self.assert_active_retry(attempted, responses=2, fetches=2)
        selected = self.wait_mobile_route(provider, prepared)
        self.assert_active_retry(selected, responses=2, fetches=2)
        self.summary['assertions'].append({'provider': provider, 'mobileEffectiveActiveRetry': selected,
            'firstFailure': first, 'secondResponse': second})

    @staticmethod
    def assert_active_retry(value, responses, fetches=None):
        routes = json.loads(value.get('responseRoutes', '[]'))
        identifiers = json.loads(value.get('responseIDs', '[]'))
        probes = json.loads(value.get('sceneProbeIDs', '[]'))
        if (value.get('mode') != 'active-retry'
                or value.get('observedScenePhase') != 'active' or value.get('sceneTransitions') != '0'
                or int(value.get('responseCount', 0)) != responses
                or int(value.get('requestCount', 0)) != responses
                or len(routes) != responses or any(route != routes[0] for route in routes)
                or len(identifiers) != responses or not all(identifiers) or len(probes) != 1
                or (fetches is not None and int(value.get('fetchCount', 0)) != fetches)):
            raise InvariantFailure(f'active retry lacks response-caused attempts without lifecycle rescue: {value}')

    def prepare_mobile_notifications(self, provider, events, mode, hold=False):
        prepared = self.act(Action('notificationsPrepare', provider,
            {'events': json.dumps(events), 'mode': mode, 'holdFetch': str(hold).lower(),
             'unrelatedPane': self.provider_events['codex' if provider == 'claude' else 'claude'][0]['paneSessionName']},
            client='mobile'))
        self.act(Action('notificationsAuthorize', provider, client='gestures'))
        return prepared

    def deliver_mobile_stop(self, provider, index, count):
        value = self.act(Action('notificationsDeliver', provider,
            {'eventIndex': str(index), 'copies': '3', 'source': 'alternating'}, client='mobile'))
        if int(value['requestCount']) != count:
            raise InvariantFailure(f'mobile direct/relay replay count differs from {count}: {value}')
        return value

    def tap_mobile_notification(self, provider, prepared, lifecycle='warm'):
        try:
            value = self.act(Action('notificationsTap', provider,
                {'title': prepared['title'], 'lifecycle': lifecycle}, client='gestures'))
            if value.get('foreground') != 'true' or value.get('rootVisible') != 'true':
                raise InvariantFailure(f'{provider} {lifecycle} tap lacks observed foreground/RootView: {value}')
            return value
        except Exception:
            self.capture_delivery_diagnostic(provider)
            raise

    def capture_delivery_diagnostic(self, provider):
        # Read before finish removes OS notifications. A suspended test host may
        # not respond; preserve the original failure and never resend its alert.
        try:
            state = self.server.broker.command(Action('notificationsState', provider, client='mobile'), timeout=5)
            (self.root / f'notifications-{provider}-tap-failure.json').write_text(json.dumps(state, indent=2))
        except Exception as error:
            self.summary.setdefault('diagnosticErrors', []).append(str(error))

    def wait_mobile_route(self, provider, prepared):
        wrong_marker = self.markers['codex' if provider == 'claude' else 'claude']
        selected = self.wait_mobile_notification(provider, lambda value: value['pending'] == 'false'
            and value['selectedHost'] == prepared['expectedHost']
            and value['worktree'] == prepared['expectedWorktree'] and value['pane'] == prepared['expectedPane']
            and int(value['fetchCount']) > 0
            and value.get('session') == prepared['expectedPane']
            and all(value.get(key) == 'true' for key in ('live', 'mounted', 'surfaceReady'))
            and bool(value.get('nativeGrid'))
            and int(value.get('observationSequence', 0)) > 0
            and float(value.get('observedAt', 0)) > float(prepared['observedAt'])
            and self.markers[provider] in value.get('physicalRows', '')
            and wrong_marker not in value.get('physicalRows', ''))
        # Capture after the selected native container has fresh target rows,
        # rather than the earlier tap screenshot while it may be reconnecting.
        self.act(Action('notificationsCapture', provider, client='gestures'))
        return selected

    def wait_mobile_notification(self, provider, predicate, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = self.act(Action('notificationsState', provider, client='mobile'))
            if predicate(value):
                return value
            time.sleep(.1)
        raise InvariantFailure(f'mobile notification state did not settle: {value}')
