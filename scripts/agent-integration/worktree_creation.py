"""Background CLI creation and sustained mobile viewport checks for both providers."""
import json
import re
import time
from urllib.parse import urlsplit

from harness import Action, InvariantFailure, assert_buffer_matches
from model import reentry_scenario_text
from run import Run


def claude_auto_mode_notice_ready(text, endpoint):
    # Claude 2.1.296 pauses its first tool on this gateway billing notice.
    # Match the complete active footer and this fixture's exact endpoint;
    # this must never acknowledge an unrelated tool approval or old transcript.
    host = urlsplit(endpoint).netloc
    notice = f"""We're changing auto mode to no longer charge for classifier requests in Claude Code.
        However, this session isn't eligible because your requests go through {host}, which isn't compatible with this
        update.
        Nothing breaks: auto mode keeps working, and its classifier requests are billed as before.
        To fix it and access the new version of auto mode, ask your gateway to implement:
        https://code.claude.com/docs/en/auto-mode-classifier-billing
        Enter to continue · Esc to cancel"""
    return bool(host) and ' '.join(text.split()).endswith(' '.join(notice.split()))


def provider_hooks_registered(roster, agent, path, session):
    # Codex's wrapper registers a live PID before its TUI or hooks run.
    # Require the native identity that SessionStart binds to that transport.
    return any(row.get('path') == path and row.get('runtime') == agent
               and row.get('paneSessionName') == session
               and row.get('reachable') == 'true' and row.get('transport') == agent
               and bool(row.get('runtimeSessionID'))
               and (agent != 'codex' or row.get('transportThreadID') == row['runtimeSessionID'])
               for row in roster)


def assert_history_rows(visible, authoritative):
    # Physical clipping can truncate the first and last visible rows. Require
    # at least one complete row between them and compare against daemon history.
    markers = list(re.finditer(r'ROW-[0-9]{6}', visible))
    if len(markers) < 3:
        raise InvariantFailure('scroll gesture exposed no complete numbered history rows')
    first, last = markers[1], markers[-1]
    start, end = authoritative.find(first[0]), authoritative.find(last[0])
    if start < 0 or end <= start:
        raise InvariantFailure('historical viewport rows are absent or reordered in daemon output')
    assert_buffer_matches(visible[first.start():last.start()], authoritative[start:end])


def authoritative_history_viewport(visible, authoritative):
    """Select a complete ASCII fixture suffix, never an arbitrary history subset.

    The first physical row may continue a wrapped line whose marker is above
    the viewport. Compare from its first complete marker through the fixture's
    end instead. Require multiple markers and the daemon's final numbered row;
    the caller still compares every numbered row's content, parser grid and
    input footer. This deliberately does not claim a complex-grapheme oracle.
    Historical scrolling has its separate, unchanged assert_history_rows check.
    """
    native = list(re.finditer(r'ROW-[0-9]{6}', visible))
    daemon = list(re.finditer(r'ROW-[0-9]{6}', authoritative))
    if len(native) < 2 or len(native) > len(daemon):
        raise InvariantFailure('viewport must expose at least two complete numbered fixture rows')
    suffix = daemon[-len(native):]
    if [marker[0] for marker in native] != [marker[0] for marker in suffix]:
        raise InvariantFailure('viewport is not the complete contiguous suffix of daemon fixture rows')
    sentinel = 'END-GRAFTTY-FIXTURE'
    native_end = visible.find(sentinel, native[-1].end())
    daemon_end = authoritative.find(sentinel, daemon[-1].end())
    if native_end < 0 or daemon_end < 0:
        raise InvariantFailure('viewport and daemon must contain the complete fixture end sentinel')
    expected = authoritative[suffix[0].start():daemon_end + len(sentinel)]
    actual = visible[native[0].start():native_end + len(sentinel)]
    if not expected.isascii() or not actual.isascii():
        raise InvariantFailure('history viewport oracle requires the ASCII numbered fixture')
    return expected


def assert_stable_grid(samples):
    if len(samples) < 3:
        raise InvariantFailure('not enough native observations to establish grid stability')
    first = None
    first_requests = None
    for sample in samples:
        phone, mac = sample['mobile'], sample['mac']
        shared = ('grid', 'revision', 'epoch', 'ownerIdentity')
        if any(not phone.get(key) or not mac.get(key) for key in (*shared, 'owner')):
            raise InvariantFailure('missing native owner/grid observations')
        if phone.get('isOwner') != 'true':
            raise InvariantFailure('mobile lost display ownership after settling')
        # The native host pairs and authenticates this fixture's phone under
        # this device ID; matching some other owner on both ends is insufficient.
        if phone['ownerIdentity'] != 'ssh-device:integration-phone':
            raise InvariantFailure('display owner is not the authenticated fixture phone')
        canonical = tuple(phone[key] for key in shared)
        if canonical != tuple(mac[key] for key in shared) or phone.get('nativeGrid') != phone['grid']:
            raise InvariantFailure('host and physical mobile grid or ownership observations disagree')
        # TerminalAttachCoordinator localizes ownerClientID to the protocol ID
        # on Mobile. Compare authenticated identity across endpoints, while
        # requiring each endpoint's raw owner to stay unchanged in this window.
        state = (canonical, phone['owner'], mac['owner'])
        if phone.get('pagedGridMismatches'):
            raise InvariantFailure('output parsed at the wrong source grid')
        requests = phone.get('ownerResizeRequests', '')
        if not requests.isdigit():
            raise InvariantFailure('missing native resize-request observations')
        if first_requests is not None and requests != first_requests:
            raise InvariantFailure('owner resize requests continued after settling')
        first_requests = requests
        if first is not None and state != first:
            raise InvariantFailure('viewport, ownership identity, epoch, revision, or endpoint owner changed after settling')
        first = state


class WorktreeCreationRun(Run):
    def complete_provider_recap(self, agent):
        models = self.server.models
        self.act(Action('visibility', agent, {'visible': 'true'}))
        self.act(Action('takeControl', agent))
        models.release(agent, 'recap')
        notice_candidate = None
        notice_dismissed = False
        notice_evidence = None
        provider_version = self.summary.get('providerVersions', {}).get(agent)
        notice_path = self.root / f'{agent}-creation-completion-notice.json'

        def tick():
            nonlocal notice_candidate, notice_dismissed, notice_evidence
            token = models.pending_tools.get(agent, '')
            if (agent == 'claude' and provider_version == '2.1.296 (Claude Code)'
                    and token.startswith('recap:') and not notice_dismissed):
                value = self.snapshot(agent)
                text = value.get('nativeText', value.get('text', ''))
                if claude_auto_mode_notice_ready(text, self.server.endpoint):
                    if notice_candidate != token:
                        notice_candidate = token
                        return
                    notice_evidence = {'pendingTool': token, 'endpoint': self.server.endpoint,
                                       'providerVersion': provider_version, 'observation': value}
                    notice_path.write_text(json.dumps(notice_evidence, indent=2))
                    self.act(Action('input', agent, {'text': ''}))
                    notice_dismissed = True
                    self.summary['assertions'].append({'agent': agent,
                        'nativeInformationalNoticeDismissed': 'claude-auto-mode-gateway-billing'})
                    return
                notice_candidate = None
            self.approve_known_tools()

        # Only a successful real recap tool result can satisfy this wait.
        try:
            models.wait(lambda: agent in models.recaps_done, timeout=60, tick=tick)
        finally:
            if notice_evidence is not None:
                notice_evidence['authenticRecapReceived'] = agent in models.recaps_done
                try:
                    notice_evidence['afterObservation'] = self.snapshot(agent)
                except Exception as error:
                    # A failed observation must not replace the original missing
                    # tool receipt or transport failure from the completion wait.
                    notice_evidence['afterObservationError'] = f'{type(error).__name__}: {error}'
                notice_path.write_text(json.dumps(notice_evidence, indent=2))

    def wait_provider_hooks(self, agent, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            roster = json.loads(self.act(Action('roster'))['agents'])
            # Preserve the actual last observation on success and on timeout.
            (self.root / f'{agent}-creation-hooks.json').write_text(json.dumps(roster, indent=2))
            if provider_hooks_registered(roster, agent, self.paths[agent]['path'], self.paths[agent]['session']):
                return
            if time.monotonic() >= deadline:
                raise InvariantFailure(f'{agent} provider hooks did not bind a live native session: {roster}')
            time.sleep(.1)

    def check_mobile_reentry(self, agent, stage):
        oracle = None if self.options.worktree_creation_viewport_only else authoritative_history_viewport
        super().check_mobile_reentry(agent, stage, authoritative_viewport=oracle)

    def converge(self, agent, timeout=20):
        # The Mac surface deliberately stays unmounted during background startup;
        # only the owning phone has a physical viewport that must match the host.
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            phone, mac = self.snapshot(agent, 'mobile'), self.snapshot(agent)
            if (phone['ownerIdentity'] == mac['ownerIdentity'] and phone['isOwner'] == 'true'
                    and phone['grid'] == mac['grid'] == phone['nativeGrid']
                    and phone['revision'] == mac['revision'] and phone['epoch'] == mac['epoch']):
                return mac, phone
            time.sleep(.05)
        raise InvariantFailure(f'created pane did not converge: mac={mac}, phone={phone}')

    def record_stability(self, agent, stage):
        self.converge(agent)
        time.sleep(.3)  # Let an already pending owner-transition send settle.
        samples = []
        # Observe actual traffic across multiple owner-resize quiet windows:
        # same-grid requests need not advance ownership revision.
        for _ in range(12):
            samples.append({'mobile': self.snapshot(agent, 'mobile'), 'mac': self.snapshot(agent)})
            time.sleep(.15)
        (self.root / f'{agent}-{stage}-stability.json').write_text(json.dumps(samples, indent=2))
        assert_stable_grid(samples)
        self.summary['assertions'].append({'agent': agent, 'stage': stage, 'stableSamples': len(samples)})

    def check_history(self, agent):
        bottom = self.snapshot(agent, 'mobile')
        self.act(Action('scroll', agent, {'position': 'top'}, client='mobile'))
        top = self.wait_snapshot(agent, lambda value: value['anchor']
            and value['anchor'] != bottom['anchor'], client='mobile')
        authoritative = self.act(Action('verify', agent))
        assert_history_rows(top['text'], authoritative['authoritativeText'])
        (self.root / f'{agent}-created-pane-history.json').write_text(json.dumps(
            {'bottom': bottom, 'top': top, 'authoritative': authoritative}, indent=2))
        self.act(Action('scroll', agent, {'position': 'bottom'}, client='mobile'))
        self.check_mobile_reentry(agent, 'created-pane-history-return')

    def scenarios(self):
        source = self.options.worktree_creation_source
        viewport_only = self.options.worktree_creation_viewport_only
        if viewport_only:
            self.summary['providerModes'] = {'claude': 'default (fresh isolated home, no TUI mode overrides)'}
        self.summary['scope'] = (('Supported worktree-add CLI through isolated headless host' if source == 'cli'
            else 'Production AddWorktreeFlow and TerminalManager with isolated headless control handling')
            + '; production SingleSessionView in iOS Simulator. This does not construct AppServices; '
            'Mobile row/control geometry uses separate native view tests.')
        if viewport_only:
            self.summary['scope'] += ' Default Claude viewport lifecycle only; no full-transcript terminal history assertion.'
        self.start_mobile()
        self.summary['nativeHosts'] = {name: {key: value for key, value in
            self.server.broker.registrations[name].items() if key not in ('fingerprint', 'clientKey')}
            for name in ('mac', 'mobile')}
        self.phase = 'fixed'
        models = self.server.models
        models.fixture_text = reentry_scenario_text
        models.pause_after_output = True
        for agent in (('claude',) if viewport_only else ('claude', 'codex')):
            self.paths[agent] = self.server.broker.command(
                Action('start', agent, {'background': 'true', 'backgroundFlow': source}), timeout=120)
            if self.paths[agent].get('viewMounted') != 'false':
                raise InvariantFailure('background CLI startup mounted a Mac terminal view')
            deadline = time.monotonic() + 90
            last_review = 0
            while (agent, 'begin') not in models.arrived:
                if time.monotonic() >= deadline:
                    raise InvariantFailure(f'{agent} did not reach its model endpoint without selecting a worktree')
                value = self.snapshot(agent)
                if value.get('viewMounted') != 'false':
                    raise InvariantFailure('startup observation mounted the background pane')
                if 'Hooks need review' in value['text'] and time.monotonic() - last_review > 2:
                    self.act(Action('input', agent, {'text': '2'}))
                    last_review = time.monotonic()
                time.sleep(.1)
            self.wait_provider_hooks(agent)
            self.summary['assertions'].append({'agent': agent, 'launchedWithoutSelection': True,
                                               'providerHooksRegistered': True})
            # Only after provider startup do we open the actual mobile route.
            self.act(Action('connect', agent, {'session': self.paths[agent]['session'],
                'presentation': 'route'}, client='mobile'))
            self.act(Action('takeControl', agent, client='mobile'))
            self.record_stability(agent, 'open-pane')
            models.release(agent, 'begin')
            self.wait_model(lambda: (agent, 'middle') in models.arrived)
            self.wait_mobile_keyboard(agent, True)
            self.record_stability(agent, 'keyboard-visible')
            self.wait_mobile_keyboard(agent, False)
            self.record_stability(agent, 'keyboard-hidden')
            before = self.snapshot(agent, 'mobile')['grid']
            self.act(Action('resize', agent, {'width': '852', 'height': '393'}, client='mobile'))
            self.record_stability(agent, 'landscape')
            if self.snapshot(agent, 'mobile')['grid'] == before:
                raise InvariantFailure('rotation did not resize the owning terminal')
            self.act(Action('resize', agent, {'width': '393', 'height': '852'}, client='mobile'))
            self.record_stability(agent, 'portrait')
            models.release(agent, 'middle')
            self.wait_model(lambda: (agent, 'end') in models.arrived)
            models.release(agent, 'end')
            self.wait_model(lambda: (agent, 'output') in models.arrived)
            self.check_mobile_reentry(agent, 'created-pane-output')
            if not viewport_only:
                self.check_history(agent)
            self.act(Action('reconnect', agent, client='mobile'))
            self.record_stability(agent, 'reconnected')
            self.check_mobile_reentry(agent, 'created-pane-reconnected-output')
            # All text is rendered before end-turn Stop-hook UI can replace it.
            # Still require genuine provider completion and its real recap tool.
            models.release(agent, 'output')
            self.wait_model(lambda: agent in models.completed)
            self.wait_model(lambda: (agent, 'recap') in models.arrived)
            self.complete_provider_recap(agent)
        if self.invariant_failures:
            raise InvariantFailure('created mobile pane failed output checks')
