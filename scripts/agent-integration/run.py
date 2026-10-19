#!/usr/bin/env python3
"""Run isolated real-agent native Mac/mobile scenarios and preserve failure traces."""
import argparse
import fcntl
import hashlib
from dataclasses import asdict
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from harness import Action, InvariantFailure, assert_observation, seeded_actions, shrink, patch_xctestrun, assert_buffer_matches, approval_ready, assert_reentry_viewport
from server import IntegrationServer
from model import reentry_scenario_text

REPO = Path(__file__).resolve().parents[2]
AGENTS = ('claude', 'codex', 'claude-peer', 'codex-peer')


def execute(command, *, env=None, timeout=180, log=None, strip=True):
    if log:
        with Path(log).open('wb') as output:
            result = subprocess.run(command, cwd=REPO, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    else:
        result = subprocess.run(command, cwd=REPO, env=env, capture_output=True, timeout=timeout)
    if result.returncode:
        raise InvariantFailure(f'command failed ({result.returncode}): {command}; log={log or result.stderr.decode(errors="replace")}')
    output = result.stdout.decode() if not log else ''
    return output.strip() if strip else output


def prepare_home(root, endpoint, codex, claude):
    home = root / 'home'
    for folder in (home / '.codex', home / '.claude', root / 'bin', root / 'run'):
        folder.mkdir(parents=True, exist_ok=True)
    (root / 'bin' / 'codex').symlink_to(codex)
    (root / 'bin' / 'claude').symlink_to(claude)
    config = ('model="gpt-5.4"\nmodel_provider="fixture"\ncli_auth_credentials_store="file"\n'
              'check_for_update_on_startup=false\napproval_policy="on-request"\n'
              '[model_providers.fixture]\nname="fixture"\nwire_api="responses"\n'
              f'base_url="{endpoint}/model/codex/v1"\nrequires_openai_auth=false\n'
              'request_max_retries=0\nstream_max_retries=0\n'
              'env_http_headers={"X-Graftty-Test-Agent"="GRAFTTY_TEST_AGENT"}\n')
    projects = {}
    for agent in AGENTS:
        path = str(root / 'repository' / '.worktrees' / agent)
        config += '[projects.' + json.dumps(path) + ']\ntrust_level="trusted"\n'
        projects[path] = {'hasTrustDialogAccepted': True}
    (home / '.codex' / 'config.toml').write_text(config)
    (home / '.claude' / '.claude.json').write_text(json.dumps({'hasCompletedOnboarding': True,
        'theme': 'dark', 'customApiKeyResponses': {'approved': ['fixture-only'], 'rejected': []}, 'projects': projects}))
    (home / '.claude' / 'settings.json').write_text(json.dumps({'autoUpdatesChannel': 'stable'}))
    # Keep build tools on PATH, excluding the running agent's managed wrappers.
    paths = [str(root / 'bin')]
    paths.extend(path for path in os.environ.get('PATH', '').split(':') if 'agent-hooks' not in path)
    env = {key: os.environ[key] for key in ('LANG', 'LC_ALL', 'DEVELOPER_DIR', 'SDKROOT') if key in os.environ}
    env.update(PATH=':'.join(dict.fromkeys(paths)), HOME=str(home), CFFIXED_USER_HOME=str(home),
        TMPDIR=str(root / 'run'), USER='graftty-fixture',
        SHELL='/bin/zsh', GRAFTTY_STATE_DIR=str(home / 'Library/Application Support/Graftty'), CODEX_HOME=str(home / '.codex'),
        CLAUDE_CONFIG_DIR=str(home / '.claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR=str(home / '.claude'),
        ANTHROPIC_API_KEY='fixture-only', ANTHROPIC_BASE_URL=endpoint + '/model/claude', OPENAI_API_KEY='fixture-only',
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1')
    return env


class Run:
    def __init__(self, options, actions=None):
        self.options = options
        self.root = Path(tempfile.mkdtemp(prefix='graftty-ai-', dir='/private/tmp'))
        self.server = IntegrationServer(self.root, str(options.cli), options.rows)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.children = []
        self.logs = []
        self.actions = actions
        self.simulator = None
        self.owns_simulator = False
        self.ios_lock = None
        self.paths = {}
        self.invariant_failures = []
        self.approved_tokens = set()
        self.approval_candidates = set()
        self.phase = 'setup'
        self.summary = {'seed': options.seed, 'result': 'failed', 'root': str(self.root), 'assertions': [],
                        'scope': ('Mac renderer and messaging only' if options.mac_only else
                                  'Mac and UIKit renderers; real zmx, provider plugins, and SSH-over-WebRTC')}

    def spawn(self, command, env, name):
        log = (self.root / (name + '.log')).open('wb')
        child = subprocess.Popen(command, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        self.children.append((name, child))
        self.logs.append(log)
        return child

    def wait_registered(self, client, timeout=240):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.server.broker.lock:
                if client in self.server.broker.registrations:
                    return self.server.broker.registrations[client]
            for name, child in self.children:
                if child.poll() is not None:
                    raise InvariantFailure(f'{name} exited before {client} registered; see {self.root}/{name}.log')
            time.sleep(.1)
        raise InvariantFailure(f'{client} registration timed out; logs in {self.root}')

    def snapshot(self, agent, client='mac'):
        return self.server.broker.command(Action('snapshot', agent, client=client))

    def wait_snapshot(self, agent, predicate, client='mac', timeout=30):
        deadline = time.monotonic() + timeout
        value = {}
        while time.monotonic() < deadline:
            self.approve_known_tools()
            value = self.snapshot(agent, client)
            if predicate(value):
                return value
        raise InvariantFailure(f'native condition did not settle for {agent}/{client}: {value}')

    def act(self, action):
        if action.client == 'mobile' and action.operation == 'scroll':
            self.snapshot(action.provider, 'mobile')
            self.server.broker.command(Action('scroll', action.provider, action.parameters, client='gestures'))
            return self.snapshot(action.provider, 'mobile')
        if action.client == 'mobile' and action.operation == 'resize':
            self.server.broker.command(Action('snapshot', action.provider, client='mobile'))  # Focus the requested pane.
            result = self.server.broker.command(Action('resize', action.provider, action.parameters, client='gestures'))
            wide = int(action.parameters['width']) > int(action.parameters['height'])
            return self.wait_snapshot(action.provider, lambda v: (int(v['width']) > int(v['height'])) == wide, 'mobile')
        return self.server.broker.command(action)

    def converge(self, agent, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            phone = self.snapshot(agent, 'mobile')
            mac = self.snapshot(agent)
            identity = mac.get('ownerIdentity')
            same_owner = (identity == phone.get('ownerIdentity') if identity else mac['owner'] == phone['owner'])
            if (same_owner and mac['grid'] == phone['grid'] and mac['revision'] == phone['revision']
                    and phone['nativeGrid'] == phone['grid'] and mac['nativeGrid'] == mac['grid']
                    and mac['epoch'] == phone['epoch']):
                return mac, phone
        raise InvariantFailure(f'Mac/mobile ownership and grid did not converge: mac={mac}, phone={phone}')

    def prepare_mobile(self):
        options = self.options
        if options.simulator:
            self.simulator = options.simulator
        else:
            create = ['xcrun', 'simctl', 'create', 'Graftty agent integration ' + uuid.uuid4().hex[:8], options.device]
            if options.runtime:
                create.append(options.runtime)
            self.simulator = execute(create)
            self.owns_simulator = True
        print('Preparing private iOS test device: ' + self.simulator, flush=True)
        # Boot only our device. A supplied simulator is an explicitly selected test destination.
        devices = json.loads(execute(['xcrun', 'simctl', 'list', 'devices', '--json']))
        selected = next((d for runtime in devices['devices'].values() for d in runtime if d['udid'] == self.simulator), None)
        if not selected:
            raise InvariantFailure('selected simulator is unavailable')
        runtime = next(key for key, values in devices['devices'].items() if selected in values)
        self.summary['simulator'] = {'udid': self.simulator, 'name': selected['name'], 'runtime': runtime}
        (self.root / 'result.json').write_text(json.dumps(self.summary, indent=2))
        if selected['state'] != 'Booted':
            execute(['xcrun', 'simctl', 'boot', self.simulator])
        execute(['xcrun', 'simctl', 'bootstatus', self.simulator, '-b'], timeout=300, log=self.root / 'simulator-boot.log')
        derived = options.ios_cache
        derived.mkdir(parents=True, exist_ok=True)
        self.ios_lock = (derived.parent / (derived.name + '.lock')).open('a')
        fcntl.flock(self.ios_lock, fcntl.LOCK_EX)
        build_env = dict(os.environ)
        if options.ghostty_package:
            build_env['GRAFTTY_GHOSTTY_PACKAGE_PATH'] = str(options.ghostty_package)
        renderer_context = execute([sys.executable, str(REPO / 'scripts/ghostty-paging/compiler-context.py'),
            str(REPO), str(derived / 'manifest')], env=build_env)
        print('Building native mobile test host', flush=True)
        execute(['xcodebuild', '-project', str(REPO / 'Apps/GrafttyMobile/GrafttyMobile.xcodeproj'),
            '-scheme', 'GrafttyBrowserInteraction', '-destination', 'platform=iOS Simulator,id=' + self.simulator,
            '-derivedDataPath', str(derived), 'OTHER_SWIFT_FLAGS=$(inherited) -Xcc ' + renderer_context,
            'build-for-testing'], env=build_env,
            timeout=900, log=self.root / 'ios-build.log')
        run_files = [p for p in (derived / 'Build/Products').glob('*.xctestrun') if p.name != 'agent-integration.xctestrun']
        if len(run_files) != 1:
            raise InvariantFailure('expected one xctestrun file')
        data = plistlib.loads(run_files[0].read_bytes())
        data = patch_xctestrun(data, str(run_files[0].parent), self.server.endpoint)
        run_file = self.root / 'agent-integration.xctestrun'
        run_file.write_bytes(plistlib.dumps(data))
        self.mobile_command = ['xcodebuild', '-xctestrun', str(run_file), '-destination', 'platform=iOS Simulator,id=' + self.simulator,
            '-resultBundlePath', str(self.root / 'mobile.xcresult'), '-parallel-testing-enabled', 'NO',
            '-only-testing:GrafttyMobileInteractionTests/AgentNativeInteractionTests', 'test-without-building']
        self.mobile_environment = build_env

    def start_mobile(self):
        self.spawn(self.mobile_command, self.mobile_environment, 'mobile')
        self.wait_registered('mobile')
        self.wait_registered('gestures')

    def approve_known_tools(self):
        with self.server.models.condition:
            pending = dict(self.server.models.pending_tools)
        for agent, token in pending.items():
            if (agent, token) in self.approved_tokens or agent not in self.paths:
                continue
            value = self.snapshot(agent)
            text = value.get('nativeText', value['text'])
            # A new model tool can arrive before the old approval UI repaints.
            # Match its unique argument before pressing Enter.
            if approval_ready(token, text):
                if (agent, token) not in self.approval_candidates:
                    self.approval_candidates.add((agent, token))
                    continue
                self.act(Action('input', agent, {'text': ''}))
                self.approved_tokens.add((agent, token))
                self.summary['assertions'].append({'agent': agent, 'nativeOneTimeToolApproval': token})

    def wait_model(self, predicate, timeout=60):
        self.server.models.wait(predicate, timeout=timeout, tick=self.approve_known_tools)

    def message(self, sender, recipient, urgent=False):
        nonce = uuid.uuid4().hex
        destination = self.paths[recipient]['path'] + '#' + ('claude' if recipient.startswith('claude') else 'codex')
        self.act(Action('message', sender, {'destination': destination, 'text': 'GRAFTTY_TEST_MESSAGE ' + nonce,
                                          'urgent': str(urgent).lower()}))
        models = self.server.models
        self.wait_model(lambda: (recipient, nonce, 'message') in models.receipts, timeout=45)
        self.wait_model(lambda: (sender, nonce, 'reply') in models.receipts and nonce in models.tool_results, timeout=60)
        self.summary['assertions'].append({'message': nonce, 'sender': sender, 'recipient': recipient,
                                          'urgent': urgent, 'providerContextReceipt': True, 'toolReplyReceipt': True})

    def check_generated_content(self, agent):
        if any(failure['agent'] == agent for failure in self.invariant_failures):
            status = 'baselineFailed'
        else:
            value = self.act(Action('verify', agent))
            if re.search(r'ROW-[0-9]{6}', value['authoritativeText']):
                assert_buffer_matches(value['buffer'], value['authoritativeText'])
                status = 'checked'
            else:
                # Provider TUIs can virtualize the old fixture after messaging.
                # Absence is an explicit coverage gap, not a content pass.
                status = 'notObservable'
        self.summary.setdefault('generatedContentChecks', []).append({'agent': agent, 'status': status})

    def scenarios(self):
        if getattr(self.options, 'history', False):
            from history_scenario import run_history
            run_history(self)
            return
        if getattr(self.options, 'worktree_reentry', False):
            self.worktree_reentry()
            return
        broker, models = self.server.broker, self.server.models
        if not self.options.mac_only:
            self.start_mobile()
        self.phase = 'fixed'
        for agent in AGENTS:
            self.paths[agent] = self.act(Action('start', agent))
            deadline = time.monotonic() + 45
            reviewed_hooks = False
            while (agent, 'begin') not in models.arrived:
                if time.monotonic() >= deadline:
                    raise InvariantFailure(f'{agent} did not start its model stream')
                text = self.snapshot(agent)['text']
                if 'Hooks need review' in text and not reviewed_hooks:
                    self.act(Action('input', agent, {'text': '2'}))
                    reviewed_hooks = True
                    self.summary['assertions'].append({'agent': agent, 'generatedHooksReviewedInNativeUI': True})
                time.sleep(.05)
        for agent in AGENTS:
            if not self.options.mac_only:
                self.act(Action('connect', agent, {'session': self.paths[agent]['session']}, client='mobile'))
                self.converge(agent)
            models.release(agent, 'begin')
            self.wait_model(lambda: (agent, 'middle') in models.arrived)
            # Both clients now receive the same live terminal, with native
            # ownership changes while the model waits at a named barrier.
            if not self.options.mac_only:
                self.act(Action('takeControl', agent, client='mobile'))
                self.act(Action('resize', agent, {'width': '852', 'height': '393'}, client='mobile'))
                mac, _ = self.converge(agent)
                for visible in ('true', 'false'):
                    self.act(Action('keyboard', agent, {'visible': visible}, client='gestures'))
                mac, _ = self.converge(agent)
                before = self.act(Action('select', agent))
                self.act(Action('resize', agent, {'width': '700', 'height': '500'}))
                after = self.snapshot(agent)
                try:
                    assert_observation(before, after, preserve_selection=True)
                    if after['grid'] != mac['grid']:
                        raise InvariantFailure('follower Mac changed the authoritative PTY grid')
                except InvariantFailure as error:
                    self.invariant_failures.append({'agent': agent, 'phase': 'followerResize', 'error': str(error)})
                    (self.root / (agent + '-follower-resize-failure.json')).write_text(json.dumps(
                        {'before': before, 'after': after}, indent=2))
                self.act(Action('reconnect', agent, client='mobile'))
            else:
                self.act(Action('resize', agent, {'width': '393', 'height': '700'}))
            models.release(agent, 'middle')
            self.wait_model(lambda: (agent, 'end') in models.arrived)
            self.act(Action('takeControl', agent))
            self.act(Action('resize', agent, {'width': '1200', 'height': '800'}))
            models.release(agent, 'end')
            self.wait_model(lambda: agent in models.completed)
            self.wait_model(lambda: (agent, 'recap') in models.arrived)
            deadline = time.monotonic() + 5
            while True:
                native = self.act(Action('verify', agent))
                try:
                    assert_buffer_matches(native['buffer'], native['authoritativeText'])
                    if 'END-GRAFTTY-FIXTURE' not in native['authoritativeText']:
                        raise InvariantFailure('completed fixture marker absent from authoritative terminal')
                    if 'END-GRAFTTY-FIXTURE' not in native['buffer']:
                        raise InvariantFailure('completed native output lost its completion marker')
                    break
                except InvariantFailure as error:
                    if time.monotonic() < deadline:
                        time.sleep(.1)
                        continue
                    # Record persistent damage but still exercise independent
                    # provider pairs. The overall run remains a failure.
                    self.invariant_failures.append({'agent': agent, 'error': str(error)})
                    (self.root / (agent + '-output-failure.json')).write_text(json.dumps(native, indent=2))
                    break
            models.release(agent, 'recap')
            if not self.options.mac_only:
                owner, follower = self.converge(agent)
                if follower['isOwner'] != 'false':
                    raise InvariantFailure('mobile still owns the session after Mac takeover')
                grid = owner['grid']
                self.act(Action('keyboard', agent, {'visible': 'false', 'attempt': 'true'}, client='gestures'))
                if self.snapshot(agent)['grid'] != grid:
                    raise InvariantFailure('follower keyboard changed the authoritative PTY grid')
            self.summary['assertions'].append({'agent': agent, 'MacMobileMac': not self.options.mac_only,
                'followerResizeGated': not self.options.mac_only and after['grid'] == mac['grid'],
                'selectionPreservedDuringFollowerResize': (not self.options.mac_only and bool(before.get('selected'))
                                                          and before['selected'] == after.get('selected')),
                'reconnectedDuringStream': not self.options.mac_only})
        # Native lifecycle hooks must expose all agents before messaging.
        self.wait_model(lambda: all(agent in models.recaps_done for agent in AGENTS), timeout=45)
        roster = json.loads(self.act(Action('roster'))['agents'])
        for agent in AGENTS:
            if not any(row['path'] == self.paths[agent]['path'] and row['reachable'] == 'true' for row in roster):
                raise InvariantFailure(f'provider hooks did not register a reachable agent: {agent}')
        for sender, recipient in [('claude', 'codex'), ('codex', 'claude'),
                                  ('claude', 'claude-peer'), ('codex', 'codex-peer')]:
            self.message(sender, recipient)
            self.message(sender, recipient, urgent=True)
        actions = self.actions if self.actions is not None else seeded_actions(self.options.seed, self.options.actions, AGENTS)
        if self.options.mac_only:
            actions = [action for action in actions if action.client == 'mac']
        (self.root / 'actions.json').write_text(json.dumps([asdict(action) for action in actions], indent=2))
        self.phase = 'generated'
        for action in actions:
            if action.operation == 'message':
                self.message(action.provider, action.parameters['recipient'], action.parameters.get('urgent') == 'true')
                continue
            before = self.snapshot(action.provider, action.client)
            self.act(action)
            after = self.snapshot(action.provider, action.client)
            assert_observation(before, after)
            self.check_generated_content(action.provider)
        for agent in AGENTS:
            self.check_generated_content(agent)
        self.summary['assertions'].append({'seededActions': len(actions), 'seed': self.options.seed})
        if self.invariant_failures:
            self.phase = 'fixed'
            self.summary['outputFailures'] = self.invariant_failures
            raise InvariantFailure('native output differed from authoritative terminal history')

    def wait_mobile_keyboard(self, agent, visible):
        self.act(Action('keyboard', agent, {'visible': str(visible).lower()}, client='gestures'))
        def settled(value):
            target = float(value['keyboardTop']) - 58 if visible else float(value['windowHeight'])
            return (value['keyboard'] == str(visible).lower()
                    and abs(float(value['terminalBottom']) - target) < 2
                    and value['nativeGrid'] == value['grid'])
        return self.wait_snapshot(agent, settled, 'mobile')

    def check_mobile_reentry(self, agent, stage, *, authoritative_viewport=None):
        deadline = time.monotonic() + 5
        status = 'passed'
        while True:
            value = self.snapshot(agent, 'mobile')
            authoritative = self.act(Action('verify', agent))
            try:
                expected = authoritative['authoritativeText']
                if authoritative_viewport is not None:
                    expected = authoritative_viewport(value['physicalRows'], expected)
                assert_reentry_viewport(value, agent, expected)
            except InvariantFailure as error:
                if time.monotonic() < deadline:
                    time.sleep(.1)
                    continue
                status = 'failed'
                self.invariant_failures.append({'agent': agent, 'stage': stage, 'error': str(error)})
            break
        (self.root / f'{agent}-{stage}.json').write_text(json.dumps(value, indent=2))
        (self.root / f'{agent}-{stage}-mac.json').write_text(json.dumps(authoritative, indent=2))
        self.act(Action('snapshot', agent, client='gestures'))
        self.summary['assertions'].append({'agent': agent, 'stage': stage, 'status': status,
            'pagedGridMismatches': value.get('pagedGridMismatches'),
            'grid': value['grid'], 'nativeGrid': value['nativeGrid'],
            'keyboardTop': value['keyboardTop'], 'terminalBottom': value['terminalBottom']})

    def worktree_reentry(self):
        self.start_mobile()
        self.phase = 'fixed'
        models = self.server.models
        models.fixture_text = reentry_scenario_text
        for agent in ('claude', 'codex'):
            self.paths[agent] = self.act(Action('start', agent))
            deadline = time.monotonic() + 90
            last_review = 0
            while (agent, 'begin') not in models.arrived:
                if time.monotonic() >= deadline:
                    raise InvariantFailure(f'{agent} did not start its model stream')
                value = self.snapshot(agent)
                if 'Hooks need review' in value['text'] and time.monotonic() - last_review > 2:
                    self.act(Action('input', agent, {'text': '2'}))
                    last_review = time.monotonic()
                time.sleep(.05)
            self.act(Action('connect', agent, {'session': self.paths[agent]['session'],
                'presentation': 'route'}, client='mobile'))
            self.act(Action('takeControl', agent, client='mobile'))
            self.converge(agent)
            models.release(agent, 'begin')
            self.wait_model(lambda: (agent, 'middle') in models.arrived)
            self.wait_mobile_keyboard(agent, True)
            self.check_mobile_reentry(agent, 'keyboard-before')
            for iteration in range(3):
                self.act(Action('visibility', agent, {'visible': 'false'}, client='mobile'))
                if iteration == 0:
                    models.release(agent, 'middle')
                    self.wait_model(lambda: (agent, 'end') in models.arrived)
                    final_row = f'ROW-{self.options.rows - 1:06d}'
                    self.wait_hidden_snapshot(agent, lambda value: final_row in value['physicalRows'])
                if iteration == 1:
                    mac = self.act(Action('takeControl', agent))
                    self.wait_hidden_snapshot(agent, lambda value: value['isOwner'] == 'false'
                        and value['epoch'] == mac['epoch'] and value['owner'] == mac['owner'])
                    self.act(Action('takeControl', agent, {'mount': 'false'}, client='mobile'))
                    self.wait_hidden_snapshot(agent, lambda value: value['isOwner'] == 'true'
                        and int(value['epoch']) > int(mac['epoch']) and value['presentationGrid'] == 'physical')
                self.act(Action('visibility', agent, {'visible': 'true'}, client='mobile'))
                self.wait_mobile_keyboard(agent, True)
                self.converge(agent)
                self.check_mobile_reentry(agent, f'reentry-{iteration}')
            self.wait_mobile_keyboard(agent, False)
            self.converge(agent)
            self.check_mobile_reentry(agent, 'keyboard-hidden')
            models.release(agent, 'end')
            self.wait_model(lambda: (agent, 'recap') in models.arrived)
            models.release(agent, 'recap')
            self.act(Action('takeControl', agent))
            self.wait_model(lambda: agent in models.recaps_done)
        if self.invariant_failures:
            raise InvariantFailure('native viewport failed the worktree re-entry checks')

    def wait_hidden_snapshot(self, agent, predicate, timeout=20):
        deadline = time.monotonic() + timeout
        value = {}
        while time.monotonic() < deadline:
            value = self.act(Action('snapshot', agent, {'mount': 'false'}, client='mobile'))
            if predicate(value):
                return value
            time.sleep(.05)
        raise InvariantFailure(f'hidden mobile condition did not settle for {agent}: {value}')

    def run(self):
        self.thread.start()
        print(f'Native integration artifacts: {self.root}', flush=True)
        self.env = {}
        failure = None
        try:
            self.summary['invocation'] = {'executable': sys.executable, 'argv': list(sys.argv),
                'interpreterArgv': list(sys.orig_argv) if hasattr(sys, 'orig_argv') else None, 'cwd': os.getcwd()}
            self.summary['inputs'] = {key: str(value) if isinstance(value, Path) else value
                                     for key, value in vars(self.options).items()}
            self.summary['providerVersions'] = {}
            self.summary['commit'] = execute(['git', 'rev-parse', 'HEAD'])
            self.summary['sourceStatus'] = execute(['git', 'status', '--porcelain'], strip=False)
            self.summary['dirty'] = bool(self.summary['sourceStatus'])
            source_diff = execute(['git', 'diff', '--binary', 'HEAD'], strip=False)
            (self.root / 'source.diff').write_text(source_diff)
            self.summary['sourceDiffSHA256'] = hashlib.sha256(source_diff.encode()).hexdigest()
            for name in ('cli', 'zmx'):
                path = getattr(self.options, name)
                self.summary[name] = {'path': str(path)}
                self.summary[name]['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
            # Persist provenance before home setup, version commands, or native
            # builds can fail. Unobserved metadata stays absent, never guessed.
            (self.root / 'result.json').write_text(json.dumps(self.summary, indent=2))
            self.env = prepare_home(self.root, self.server.endpoint, self.options.codex, self.options.claude)
            if getattr(self.options, 'worktree_creation', False):
                # CLI-created Codex uses its configured model header without the
                # direct-launch export. Claude has its own endpoint and ignores it.
                self.env['GRAFTTY_TEST_AGENT'] = 'codex'
            if getattr(self.options, 'worktree_creation', False) and not getattr(self.options, 'worktree_creation_viewport_only', False):
                # This scenario verifies real terminal history. Claude's fullscreen
                # renderer virtualizes old rows inside the provider instead.
                self.env['CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN'] = '1'
                self.summary['providerModes'] = {'claude': 'classic (CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1)',
                                                 'codex': 'default'}
            for name in ('claude', 'codex'):
                self.summary['providerVersions'][name] = execute([str(getattr(self.options, name)), '--version'], env=self.env)
            self.env['GRAFTTY_SWIFTPM_SHARED_DIR'] = str(self.options.cache)
            if self.options.ghostty_package:
                self.env['GRAFTTY_GHOSTTY_PACKAGE_PATH'] = str(self.options.ghostty_package)
            manifest = {'endpoint': self.server.endpoint, 'root': str(self.root), 'cli': str(self.options.cli),
                        'zmx': str(self.options.zmx), 'codex': str(self.options.codex), 'claude': str(self.options.claude),
                        'seed': self.options.seed}
            self.server.manifest = manifest
            manifest_file = self.root / 'manifest.json'
            manifest_file.write_text(json.dumps(manifest))
            self.env['GRAFTTY_AGENT_INTEGRATION_MANIFEST'] = str(manifest_file)
            (self.root / 'bin' / 'graftty').symlink_to(self.options.cli)
            (self.root / 'result.json').write_text(json.dumps(self.summary, indent=2))
            if not self.options.mac_only:
                self.prepare_mobile()
            self.spawn([str(REPO / 'scripts/swiftpm'), 'test', '--build-system', 'native', '--filter', 'AgentIntegrationNativeTests'], self.env, 'mac')
            self.wait_registered('mac', timeout=900)
            self.scenarios()
            self.summary['result'] = 'passed'
        except Exception as error:
            failure = error
            self.summary['error'] = str(error)
            self.summary['outputFailures'] = self.invariant_failures
            # Preserve daemon/native evidence before teardown, even when the
            # invariant fails before its ordinary verification action.
            for agent in self.paths:
                try:
                    value = self.server.broker.command(Action('verify', agent), timeout=5)
                    (self.root / (agent + '-failure.json')).write_text(json.dumps(value, indent=2))
                except Exception as diagnostic_error:
                    self.summary.setdefault('diagnosticErrors', []).append(str(diagnostic_error))
            self.summary['failurePhase'] = 'fixed' if self.invariant_failures else self.phase
            self.summary['failureSignature'] = type(error).__name__ + ':' + str(error).split(':')[0]
        finally:
            for client in ('mobile', 'gestures', 'mac'):
                if client in self.server.broker.registrations:
                    try:
                        self.server.broker.command(Action('finish', parameters={'result': self.summary['result']}, client=client), timeout=15)
                    except Exception as error:
                        self.summary.setdefault('cleanupErrors', []).append(str(error))
            self.server.models.close()
            for name, child in self.children:
                try:
                    status = child.wait(timeout=120 if name == 'mobile' else 30)
                    if status and failure is None:
                        failure = InvariantFailure(f'{name} native tests exited {status}')
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                    if failure is None:
                        failure = InvariantFailure(f'{name} native test process did not finish')
            # All commands are scoped to this run's private daemon directory.
            try:
                if self.env.get('GRAFTTY_STATE_DIR'):
                    zmx_env = dict(self.env, ZMX_DIR=str(Path(self.env['GRAFTTY_STATE_DIR']) / 'zmx'))
                    result = subprocess.run([str(self.options.zmx), 'list'], env=zmx_env, capture_output=True, timeout=5)
                    for line in result.stdout.decode().splitlines():
                        session = line.split()[0] if line.split() else ''
                        if session.startswith('graftty-'):
                            subprocess.run([str(self.options.zmx), 'kill', '--force', session], env=zmx_env, capture_output=True, timeout=5)
            except (OSError, subprocess.TimeoutExpired) as error:
                self.summary.setdefault('cleanupErrors', []).append(str(error))
            if self.owns_simulator:
                for operation in ('shutdown', 'delete'):
                    try:
                        subprocess.run(['xcrun', 'simctl', operation, self.simulator], capture_output=True, timeout=30)
                    except subprocess.TimeoutExpired as error:
                        self.summary.setdefault('cleanupErrors', []).append(str(error))
            self.server.shutdown(); self.server.server_close(); self.thread.join()
            for log in self.logs:
                log.close()
            if self.ios_lock:
                self.ios_lock.close()
            if failure:
                self.summary['result'] = 'failed'
                self.summary['error'] = str(failure)
            (self.root / 'result.json').write_text(json.dumps(self.summary, indent=2))
        if failure:
            raise InvariantFailure(f'{failure}; artifacts: {self.root}')
        print(f'PASS: native agent scenarios. Artifacts: {self.root}', flush=True)
        return self.root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', type=Path, required=True, help='Unwrapped Codex CLI')
    parser.add_argument('--claude', type=Path, required=True, help='Native Claude CLI')
    parser.add_argument('--cli', type=Path, required=True, help='Built graftty-cli executable')
    parser.add_argument('--zmx', type=Path, required=True)
    parser.add_argument('--ghostty-package', type=Path, required=True, help='Snapshot-enabled local Ghostty package')
    parser.add_argument('--simulator', help='Use this test device without deleting it; default creates a private device')
    parser.add_argument('--mac-only', action='store_true', help='Debug the native Mac and messaging paths without claiming mobile coverage')
    parser.add_argument('--worktree-creation', action='store_true', help='Create provider worktrees through the CLI without mounting Mac panes, then verify mobile viewport stability')
    parser.add_argument('--worktree-creation-viewport-only', action='store_true',
                        help='Run bounded default-mode Claude lifecycle checks without a terminal-history oracle')
    parser.add_argument('--worktree-creation-source', choices=('cli', 'app-flow'), default='cli',
                        help='Startup boundary for --worktree-creation; app-flow exercises AddWorktreeFlow and TerminalManager')
    parser.add_argument('--worktree-reentry', action='store_true', help='Test retained mobile routes with keyboard changes and hidden ownership transitions')
    parser.add_argument('--history', action='store_true', help='Test dense wide provider output through bounded mobile history paging')

    parser.add_argument('--colors', action='store_true', help='Check real Codex syntax, diff, inline-code and link colors in native pixels')
    parser.add_argument('--device', default='iPhone 17 Pro')
    parser.add_argument('--runtime', help='CoreSimulator runtime identifier; default uses its newest compatible runtime')
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--actions', type=int, default=30)
    parser.add_argument('--rows', type=int, default=300)
    parser.add_argument('--cache', type=Path, default=Path.home() / 'Library/Caches/Graftty/SwiftPM')
    parser.add_argument('--ios-cache', type=Path, default=Path.home() / 'Library/Caches/Graftty/AgentIntegration/iOS')
    parser.add_argument('--replay', type=Path, help='actions.json from a previous run')
    parser.add_argument('--shrink', action='store_true', help='Replay fresh native runs to minimize a failing generated action list')
    options = parser.parse_args()
    for name in ('codex', 'claude', 'cli', 'zmx', 'ghostty_package'):
        setattr(options, name, getattr(options, name).resolve(strict=True))
    if options.seed < 0 or options.actions < 0 or options.rows < 100:
        parser.error('seed/actions must be nonnegative and rows must be at least 100')
    if options.worktree_creation_viewport_only and not options.worktree_creation:
        parser.error('--worktree-creation-viewport-only requires --worktree-creation')
    if options.worktree_creation and (options.history or options.worktree_reentry or options.colors or options.mac_only or options.replay or options.shrink):
        parser.error('--worktree-creation requires the standalone native mobile scenario')
    if options.history and (options.worktree_reentry or options.colors or options.mac_only or options.replay or options.shrink):
        parser.error('--history requires mobile and runs separately from other scenarios and generated actions')
    if options.worktree_reentry and options.colors:
        parser.error('--worktree-reentry and --colors are separate scenarios')
    if options.worktree_reentry and options.mac_only:
        parser.error('--worktree-reentry requires the native mobile host')
    if options.worktree_reentry and (options.replay or options.shrink):
        parser.error('--worktree-reentry does not use generated action replay or shrinking')
    actions = [Action(**value) for value in json.loads(options.replay.read_text())] if options.replay else None
    if options.worktree_creation:
        from worktree_creation import WorktreeCreationRun
        run = WorktreeCreationRun(options)
    elif options.colors:
        if options.replay or options.shrink:
            parser.error('--colors does not support generated-action replay or shrinking')
        from colors import ColorRun
        run = ColorRun(options)
    else:
        run = Run(options, actions)
    try:
        run.run()
    except InvariantFailure:
        if options.shrink and run.summary.get('failurePhase') == 'generated' and (run.root / 'actions.json').exists():
            source = [Action(**value) for value in json.loads((run.root / 'actions.json').read_text())]
            def fails(candidate):
                attempt = Run(options, candidate)
                try:
                    attempt.run()
                    return False
                except InvariantFailure:
                    return (attempt.summary.get('failurePhase') == 'generated'
                            and attempt.summary.get('failureSignature') == run.summary.get('failureSignature'))
            minimized = shrink(source, fails)
            (run.root / 'minimized-actions.json').write_text(json.dumps([asdict(action) for action in minimized], indent=2))
        raise


if __name__ == '__main__':
    main()
