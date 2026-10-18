"""Background CLI creation and sustained mobile viewport checks for both providers."""
import json
import re
import time

from harness import Action, InvariantFailure, assert_buffer_matches
from model import reentry_scenario_text
from run import Run


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


def assert_stable_grid(samples):
    if len(samples) < 3:
        raise InvariantFailure('not enough native observations to establish grid stability')
    first = None
    first_requests = None
    for sample in samples:
        phone, mac = sample['mobile'], sample['mac']
        required = ('grid', 'revision', 'owner')
        if any(not phone.get(key) or not mac.get(key) for key in required):
            raise InvariantFailure('missing native owner/grid observations')
        state = tuple(phone[key] for key in required)
        if state != tuple(mac[key] for key in required) or phone.get('nativeGrid') != phone['grid']:
            raise InvariantFailure('host and physical mobile grids disagree')
        if phone.get('pagedGridMismatches'):
            raise InvariantFailure('output parsed at the wrong source grid')
        requests = phone.get('ownerResizeRequests', '')
        if not requests.isdigit():
            raise InvariantFailure('missing native resize-request observations')
        if first_requests is not None and requests != first_requests:
            raise InvariantFailure('owner resize requests continued after settling')
        first_requests = requests
        if first is not None and state != first:
            raise InvariantFailure('viewport or ownership revision changed after settling')
        first = state


class WorktreeCreationRun(Run):
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
        self.summary['scope'] = (('Supported worktree-add CLI through isolated headless host' if source == 'cli'
            else 'Production AddWorktreeFlow and TerminalManager with isolated headless control handling')
            + '; production SingleSessionView in iOS Simulator. This does not construct AppServices; '
            'Mobile row/control geometry uses separate native view tests.')
        self.start_mobile()
        self.summary['nativeHosts'] = {name: {key: value for key, value in
            self.server.broker.registrations[name].items() if key not in ('fingerprint', 'clientKey')}
            for name in ('mac', 'mobile')}
        self.phase = 'fixed'
        models = self.server.models
        models.fixture_text = reentry_scenario_text
        for agent in ('claude', 'codex'):
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
            self.summary['assertions'].append({'agent': agent, 'launchedWithoutSelection': True})
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
            self.check_mobile_reentry(agent, 'created-pane-output')
            self.check_history(agent)
            self.act(Action('reconnect', agent, client='mobile'))
            self.record_stability(agent, 'reconnected')
            self.check_mobile_reentry(agent, 'created-pane-reconnected-output')
            models.release(agent, 'end')
            self.wait_model(lambda: (agent, 'recap') in models.arrived)
            models.release(agent, 'recap')
            self.act(Action('visibility', agent, {'visible': 'true'}))
            self.act(Action('takeControl', agent))
            self.wait_model(lambda: agent in models.recaps_done)
        if self.invariant_failures:
            raise InvariantFailure('created mobile pane failed output checks')
