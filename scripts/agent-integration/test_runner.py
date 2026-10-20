import hashlib
import json
import plistlib
from pathlib import Path
import tempfile
import threading
import tomllib
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from harness import Action, Broker, InvariantFailure
from run import Run, execute, main, prepare_home


class RunnerLifecycleTests(unittest.TestCase):
    def test_mobile_recovery_approves_only_the_visible_known_tool_on_mobile(self):
        runner = Run.__new__(Run)
        runner.server = SimpleNamespace(models=SimpleNamespace(condition=threading.Condition(),
            pending_tools={'claude': 'recap:unique-token', 'codex': 'recap:other-token'}))
        runner.paths = {'claude': {}, 'codex': {}}
        runner.approved_tokens, runner.approval_candidates = set(), set()
        runner.summary = {'assertions': []}
        runner.snapshot = Mock(return_value={'text': 'unique-token\nDo you want to proceed?'})
        runner.act = Mock()
        runner.approve_known_tools(client='mobile', agent='claude')
        runner.act.assert_not_called()
        runner.approve_known_tools(client='mobile', agent='claude')
        runner.act.assert_called_once_with(Action('previewInput', 'claude',
            {'text': '', 'takeControl': 'false'}, client='gestures'))
        runner.snapshot.assert_called_with('claude', 'mobile')
        runner.approve_known_tools(client='mobile', agent='claude')
        self.assertEqual(1, runner.act.call_count)

    def test_history_and_creation_cannot_silently_select_one_scenario(self):
        arguments = ['run.py']
        for option in ('--codex', '--claude', '--cli', '--zmx', '--ghostty-package'):
            arguments.extend((option, '/bin/echo'))
        with patch('run.sys.argv', arguments + ['--history', '--worktree-creation']), \
             patch('run.sys.stderr'), patch('run.Run') as runner, \
             patch('worktree_creation.WorktreeCreationRun') as creation:
            with self.assertRaises(SystemExit) as error:
                main()
            self.assertEqual(2, error.exception.code)
            runner.assert_not_called()
            creation.assert_not_called()

    def test_history_dispatch_preserves_its_dedicated_scenario(self):
        runner = Run.__new__(Run)
        runner.options = SimpleNamespace(history=True)
        with patch('history_scenario.run_history') as history:
            runner.scenarios()
        history.assert_called_once_with(runner)

    def test_source_provenance_keeps_git_status_columns_and_patch_newlines(self):
        raw = b' M fixture.py\n\n'
        with patch('run.subprocess.run', return_value=SimpleNamespace(returncode=0, stdout=raw)):
            self.assertEqual(raw.decode(), execute(['git', 'status', '--porcelain'], strip=False))
            self.assertEqual('M fixture.py', execute(['git', 'status', '--porcelain']))

    def test_provenance_survives_setup_and_scenario_failures_and_success(self):
        for failure_stage in ('home', 'version', 'mobile-build', 'scenario', None):
            with self.subTest(failure_stage=failure_stage), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binaries = {}
                for name in ('cli', 'zmx', 'codex', 'claude'):
                    binaries[name] = root / name
                    binaries[name].write_bytes((name + '-fixture').encode())
                options = SimpleNamespace(**binaries, rows=100, seed=7, mac_only=False,
                    cache=root / 'cache', ios_cache=root / 'ios', ghostty_package=None,
                    simulator='fixture-device', worktree_creation=True,
                    worktree_creation_source='app-flow', worktree_creation_viewport_only=False)
                server = Mock(endpoint='http://127.0.0.1:1234', broker=Broker())
                with patch('run.tempfile.mkdtemp', return_value=directory), \
                     patch('run.IntegrationServer', return_value=server), patch('run.threading.Thread'):
                    runner = Run(options)

                def execute_fixture(command, **kwargs):
                    if command == ['git', 'rev-parse', 'HEAD']:
                        return 'fixture-head'
                    if command[:3] == ['git', 'status', '--porcelain']:
                        return ' M scripts/agent-integration/run.py'
                    if command[:3] == ['git', 'diff', '--binary']:
                        return 'fixture diff'
                    if command[-1] == '--version':
                        if failure_stage == 'version' and command[0] == str(options.codex):
                            raise InvariantFailure('version failure')
                        return Path(command[0]).name + '-version'
                    if command[:4] == ['xcrun', 'simctl', 'list', 'devices']:
                        return json.dumps({'devices': {'fixture-runtime': [{'udid': 'fixture-device',
                            'name': 'Fixture phone', 'state': 'Booted'}]}})
                    if command[0] == 'xcodebuild':
                        raise InvariantFailure('mobile-build failure')
                    return ''

                def home_fixture(*args, **kwargs):
                    # Provenance must already be durable before setup can fail.
                    early = json.loads((root / 'result.json').read_text())
                    self.assertEqual('fixture-head', early['commit'])
                    self.assertEqual(hashlib.sha256(b'cli-fixture').hexdigest(), early['cli']['sha256'])
                    if failure_stage == 'home':
                        raise InvariantFailure('home failure')
                    return prepare_home(*args, **kwargs)

                def scenario_fixture():
                    if failure_stage == 'scenario':
                        runner.phase = 'fixed'
                        raise InvariantFailure('scenario failure')

                with patch('run.execute', side_effect=execute_fixture), \
                     patch('run.prepare_home', side_effect=home_fixture), \
                     patch('run.subprocess.run', return_value=SimpleNamespace(stdout=b'')) as cleanup, \
                     patch.object(runner, 'spawn') as spawn, patch.object(runner, 'wait_registered'), \
                     patch.object(runner, 'scenarios', side_effect=scenario_fixture), \
                     patch.object(runner, 'prepare_mobile',
                         side_effect=runner.prepare_mobile if failure_stage == 'mobile-build' else lambda: None):
                    if failure_stage:
                        with self.assertRaisesRegex(InvariantFailure, failure_stage + ' failure'):
                            runner.run()
                    else:
                        runner.run()
                    if failure_stage in ('home', 'version', 'mobile-build'):
                        spawn.assert_not_called()
                    if failure_stage == 'home':
                        cleanup.assert_not_called()
                result = json.loads((root / 'result.json').read_text())
                self.assertEqual('failed' if failure_stage else 'passed', result['result'])
                self.assertEqual('fixture-head', result['commit'])
                self.assertTrue(result['dirty'])
                self.assertEqual(' M scripts/agent-integration/run.py', result['sourceStatus'])
                self.assertEqual(hashlib.sha256(b'fixture diff').hexdigest(), result['sourceDiffSHA256'])
                self.assertEqual('fixture diff', (root / 'source.diff').read_text())
                self.assertEqual('app-flow', result['inputs']['worktree_creation_source'])
                for name in ('cli', 'zmx'):
                    self.assertEqual({'path': str(binaries[name]),
                        'sha256': hashlib.sha256((name + '-fixture').encode()).hexdigest()}, result[name])
                if failure_stage != 'home':
                    self.assertEqual('claude-version', result['providerVersions']['claude'])
                    self.assertEqual('codex', runner.env['GRAFTTY_TEST_AGENT'])
                    self.assertEqual('1', runner.env['CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN'])
                    self.assertEqual('manual (permissions.defaultMode=default)', result['providerPermissions']['claude'])
                    self.assertEqual('inline (tui.alternate_screen=never)', result['providerModes']['codex'])
                    settings = json.loads((root / 'home/.claude/settings.json').read_text())
                    self.assertEqual({'defaultMode': 'default'}, settings.get('permissions'))
                    config = tomllib.loads((root / 'home/.codex/config.toml').read_text())
                    self.assertEqual('never', config.get('tui', {}).get('alternate_screen'))
                else:
                    self.assertEqual({}, result['providerVersions'])
                    self.assertNotIn('simulator', result)
                self.assertEqual(str(options.cli), result['inputs']['cli'])
                self.assertIn('argv', result['invocation'])
                if failure_stage == 'version':
                    self.assertNotIn('codex', result['providerVersions'])
                if failure_stage == 'mobile-build':
                    self.assertEqual({'udid': 'fixture-device', 'name': 'Fixture phone',
                        'runtime': 'fixture-runtime'}, result['simulator'])
                    self.assertTrue(runner.ios_lock.closed)
                if failure_stage:
                    self.assertEqual('fixed' if failure_stage == 'scenario' else 'setup', result['failurePhase'])
                server.shutdown.assert_called_once()
                server.server_close.assert_called_once()

    def test_reentry_waits_for_current_rows_and_keeps_both_native_observations(self):
        runner = Run.__new__(Run)
        runner.invariant_failures = []
        runner.summary = {'assertions': []}
        physical = 'ROW-000001 retained output\nROW-000002 retained output\n\n› Ask Codex to do anything\n? for shortcuts'
        healthy = {'physicalRows': physical, 'pagedGridMismatches': '', 'grid': '41x5', 'nativeGrid': '41x5',
                   'keyboardTop': '500', 'terminalBottom': '442'}
        stale = {**healthy, 'physicalRows': physical.replace('ROW-000001 retained', 'ROW-000001 stale')}
        runner.snapshot = Mock(side_effect=[stale, healthy])
        runner.act = Mock(return_value={'authoritativeText': physical})
        with tempfile.TemporaryDirectory() as directory, patch('run.time.sleep'):
            runner.root = Path(directory)
            runner.check_mobile_reentry('codex', 'reentry-0')
            self.assertEqual(healthy, json.loads((runner.root / 'codex-reentry-0.json').read_text()))
            self.assertEqual(physical, json.loads((runner.root / 'codex-reentry-0-mac.json').read_text())['authoritativeText'])
        self.assertEqual(2, runner.snapshot.call_count)
        self.assertFalse(runner.invariant_failures)
        self.assertEqual('passed', runner.summary['assertions'][0]['status'])

    def test_reentry_records_a_persistent_payload_failure_after_settling(self):
        runner = Run.__new__(Run)
        runner.invariant_failures = []
        runner.summary = {'assertions': []}
        physical = 'ROW-000001 stale output\nROW-000002 retained output\n\n› Ask Codex to do anything\n? for shortcuts'
        runner.snapshot = Mock(return_value={'physicalRows': physical, 'pagedGridMismatches': '',
            'grid': '41x5', 'nativeGrid': '41x5', 'keyboardTop': '500', 'terminalBottom': '442'})
        runner.act = Mock(return_value={'authoritativeText': physical.replace('stale output', 'retained output')})
        with tempfile.TemporaryDirectory() as directory, patch('run.time.monotonic', side_effect=[0, 6]):
            runner.root = Path(directory)
            runner.check_mobile_reentry('codex', 'reentry-0')
        self.assertEqual(1, len(runner.invariant_failures))
        self.assertIn('logical row content', runner.invariant_failures[0]['error'])
        self.assertEqual('failed', runner.summary['assertions'][0]['status'])

    def test_creation_provider_modes_are_private_and_opt_in(self):
        for manual, inline in ((False, False), (True, False), (True, True)):
            with self.subTest(manual=manual, inline=inline), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare_home(root, 'http://127.0.0.1:1234', Path('/bin/echo'), Path('/bin/echo'),
                             manual_claude=manual, inline_codex=inline)
                settings = json.loads((root / 'home/.claude/settings.json').read_text())
                self.assertEqual({'autoUpdatesChannel': 'stable', **(
                    {'permissions': {'defaultMode': 'default'}} if manual else {})}, settings)
                config = tomllib.loads((root / 'home/.codex/config.toml').read_text())
                self.assertEqual({'alternate_screen': 'never'} if inline else None, config.get('tui'))
                self.assertEqual('on-request', config['approval_policy'])
                self.assertEqual('fixture', config['model_provider'])

    def test_provider_home_does_not_supply_terminal_capabilities(self):
        with tempfile.TemporaryDirectory() as directory:
            env = prepare_home(Path(directory), 'http://127.0.0.1:1234', Path('/bin/echo'), Path('/bin/echo'))
        for key in ('TERM', 'COLORTERM', 'TERM_PROGRAM', 'NO_COLOR', 'FORCE_COLOR'):
            self.assertNotIn(key, env, f'{key} would mask the production terminal environment')

    def test_mobile_build_forwards_renderer_context_to_cached_dependencies(self):
        for preview in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                runner = Run.__new__(Run)
                runner.root = Path(directory)
                runner.summary = {}
                derived = runner.root / 'ios-cache'
                products = derived / 'Build/Products'
                products.mkdir(parents=True)
                (products / 'Fixture.xctestrun').write_bytes(plistlib.dumps({}))
                renderer = runner.root / 'libghostty-spm'
                runner.options = SimpleNamespace(simulator='fixture-device', ios_cache=derived, ghostty_package=renderer, preview=preview)
                runner.server = Mock(endpoint='http://127.0.0.1:1234')

                def execute_fixture(command, **kwargs):
                    if command[:4] == ['xcrun', 'simctl', 'list', 'devices']:
                        return json.dumps({'devices': {'fixture': [{'udid': 'fixture-device', 'name': 'Fixture phone', 'state': 'Booted'}]}})
                    if any('compiler-context.py' in str(argument) for argument in command):
                        self.assertEqual(str(renderer), kwargs['env']['GRAFTTY_GHOSTTY_PACKAGE_PATH'])
                        return '-DGRAFTTY_RENDERER_fixture'
                    return ''

                with patch('run.execute', side_effect=execute_fixture) as execute, \
                     patch('run.patch_xctestrun', return_value={}):
                    try:
                        runner.prepare_mobile()
                    finally:
                        runner.ios_lock.close()
                build = next(call for call in execute.call_args_list if call.args[0][0] == 'xcodebuild')
                expected_flags = 'OTHER_SWIFT_FLAGS=$(inherited) -Xcc -DGRAFTTY_RENDERER_fixture'
                if preview:
                    expected_flags += ' -D GRAFTTY_PAGED_HISTORY'
                self.assertEqual(str(derived), runner.mobile_command[runner.mobile_command.index('-derivedDataPath') + 1])
                self.assertIn(expected_flags, build.args[0])
                self.assertEqual(str(renderer), build.kwargs['env']['GRAFTTY_GHOSTTY_PACKAGE_PATH'])
                self.assertEqual({'udid': 'fixture-device', 'name': 'Fixture phone', 'runtime': 'fixture'},
                                 runner.summary['simulator'])

    def test_mobile_build_finishes_before_native_deadline_starts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            options = SimpleNamespace(cli=Path('/bin/echo'), codex=Path('/bin/echo'), claude=Path('/bin/echo'),
                zmx=Path('/bin/echo'), rows=100, seed=1, mac_only=False, cache=root / 'cache', ghostty_package=None)
            server = Mock(endpoint='http://127.0.0.1:1234', broker=Broker())
            with patch('run.tempfile.mkdtemp', return_value=directory), patch('run.IntegrationServer', return_value=server):
                runner = Run(options)
            events = []
            with patch('run.execute', return_value='fixture-version'), \
                 patch('run.subprocess.run', return_value=SimpleNamespace(stdout=b'')), \
                 patch.object(runner, 'prepare_mobile', side_effect=lambda: events.append('mobile-build-finished')), \
                 patch.object(runner, 'spawn', side_effect=lambda *args: events.append('native-test-started')), \
                 patch.object(runner, 'wait_registered'), \
                 patch.object(runner, 'scenarios', side_effect=lambda: events.append('scenarios')):
                runner.run()
            self.assertEqual(['mobile-build-finished', 'native-test-started', 'scenarios'], events)
            self.assertEqual('passed', json.loads((root / 'result.json').read_text())['result'])

    def test_generated_content_failure_is_not_hidden_by_nonblank_text(self):
        runner = Run.__new__(Run)
        runner.invariant_failures = []
        runner.summary = {}
        runner.act = Mock(return_value={'buffer': 'ROW-000001 damaged', 'authoritativeText': 'ROW-000001 expected'})
        with self.assertRaises(InvariantFailure):
            runner.check_generated_content('claude')
        runner.act.return_value = {'buffer': 'plain TUI', 'authoritativeText': 'plain TUI'}
        runner.check_generated_content('claude')
        self.assertEqual('notObservable', runner.summary['generatedContentChecks'][-1]['status'])
        runner.invariant_failures = [{'agent': 'claude'}]
        runner.act.reset_mock()
        runner.check_generated_content('claude')
        runner.act.assert_not_called()
        self.assertEqual('baselineFailed', runner.summary['generatedContentChecks'][-1]['status'])
