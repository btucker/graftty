import copy
import unittest

from harness import InvariantFailure
from preview_scenario import require_continuity, require_matrix


class PreviewEvidenceTests(unittest.TestCase):
    def baseline(self):
        return {key: 'identity' for key in ('session', 'clientID', 'containerID', 'surfaceID',
            'channelID', 'channelOpens', 'ownerIdentity', 'owner', 'epoch', 'revision', 'grid',
            'nativeGrid', 'attachmentID', 'navigationID') } | {'connection': 'live',
                'channelOpens': '1', 'terminalMounted': 'true', 'terminalContained': 'true',
                'sourceControllerAttached': 'true', 'quickLook': 'false',
                'previewOwnerIdentity': 'identity', 'channelCloses': '0', 'parserGridMatches': 'true', 'pagedGridMismatches': ''}

    def test_reconnect_and_replacement_fail_even_when_session_matches(self):
        for key in ('clientID', 'containerID', 'surfaceID', 'channelID', 'channelOpens',
                    'ownerIdentity', 'epoch', 'revision', 'grid', 'attachmentID', 'navigationID'):
            before, after = self.baseline(), self.baseline()
            after[key] = 'changed'
            with self.subTest(key=key), self.assertRaises(InvariantFailure):
                require_continuity(before, after)

    def test_missing_diagnostics_never_count_as_continuity(self):
        before = self.baseline()
        for key in before:
            after = copy.deepcopy(before)
            del after[key]
            with self.subTest(key=key), self.assertRaises(InvariantFailure):
                require_continuity(before, after)

    def test_full_matrix_required(self):
        cases = [{'provider': p, 'retained': r, 'embedded': e, 'passed': True}
                 for p in ('claude', 'codex') for r in (False, True) for e in (False, True)]
        require_matrix(cases)
        with self.assertRaises(InvariantFailure):
            require_matrix(cases[:-1])
        with self.assertRaises(InvariantFailure):
            require_matrix(cases + [cases[0]])
        cases[0]['passed'] = False
        with self.assertRaises(InvariantFailure):
            require_matrix(cases)

    def test_stable_but_wrong_parser_or_native_grid_fails(self):
        for changes in ({'parserGridMatches': 'false'}, {'nativeGrid': 'other'},
                        {'pagedGridMismatches': 'source mismatch'}, {'channelCloses': '1'}):
            before = self.baseline() | changes
            with self.subTest(changes=changes), self.assertRaises(InvariantFailure):
                require_continuity(before, before)

    def test_system_cover_may_remove_window_without_detaching_source_controller(self):
        before = self.baseline()
        covered = before | {'terminalMounted': 'false', 'quickLook': 'true'}
        require_continuity(before, covered, covered=True)
        with self.assertRaises(InvariantFailure):
            require_continuity(before, covered)
        for key in ('terminalContained', 'sourceControllerAttached'):
            with self.subTest(key=key), self.assertRaises(InvariantFailure):
                require_continuity(before, covered | {key: 'false'}, covered=True)

    def test_owner_grid_waits_for_real_parser_and_canvas_convergence(self):
        from types import SimpleNamespace
        from unittest.mock import Mock, patch
        from preview_scenario import wait_preview_owner_grid
        ready = self.baseline() | {'isOwner': 'true', 'canvasGrid': 'physical',
                                  'presentationGrid': 'physical'}
        for changes in ({'parserGridMatches': 'false'}, {'nativeGrid': 'other'},
                        {'canvasGrid': '124x40'}, {'presentationGrid': '124x40'},
                        {'isOwner': 'false'}, {'pagedGridMismatches': 'source mismatch'}):
            with self.subTest(changes=changes), patch('preview_scenario.time.sleep'):
                run = SimpleNamespace(act=Mock(side_effect=[ready | changes, ready]))
                self.assertEqual(ready, wait_preview_owner_grid(run, 'claude'))
                self.assertEqual(2, run.act.call_count)
                self.assertTrue(all(call.args[0].operation == 'previewSnapshot' for call in run.act.call_args_list))

    def test_owner_grid_timeout_reports_parser_canvas_and_paging_evidence(self):
        from types import SimpleNamespace
        from unittest.mock import Mock
        from preview_scenario import wait_preview_owner_grid
        pending = self.baseline() | {'isOwner': 'true', 'canvasGrid': 'physical',
            'presentationGrid': 'physical', 'parserGridMatches': 'false',
            'paging': 'live', 'ownerResizeRequests': '1'}
        run = SimpleNamespace(act=Mock(return_value=pending))
        with self.assertRaises(InvariantFailure) as failure:
            wait_preview_owner_grid(run, 'claude', timeout=0)
        for key in ('isOwner', 'canvasGrid', 'presentationGrid', 'parserGridMatches',
                    'grid', 'nativeGrid', 'paging', 'pagedGridMismatches', 'ownerResizeRequests'):
            self.assertIn(key, str(failure.exception))


class PreviewProviderProtocolTests(unittest.TestCase):
    def test_native_input_receipt_is_distinct_from_stream_and_recap_completion(self):
        from harness import Broker
        from server import ModelState
        for provider in ('claude', 'codex'):
            model = ModelState(Broker(), '/fixture/graftty')
            nonce = 'a' * 32
            body = {'messages' if provider == 'claude' else 'input': [
                {'role': 'user', 'content': 'GRAFTTY_TEST_PREVIEW ' + nonce}]}
            result = model.plan(body, provider, provider)
            self.assertEqual('preview:' + nonce, result[3])
            self.assertIn((provider, nonce, 'preview'), model.receipts)
            self.assertNotIn((provider, 'preview:' + nonce), model.completed_streams)
            self.assertNotIn((provider, nonce), model.completed_preview_recaps)
            # Repeated historical prompts never become a second live stream.
            self.assertFalse(model.plan(body, provider, provider)[3])

    def test_post_dismissal_input_has_its_own_receipt_and_recap_context(self):
        from harness import Broker
        from server import ModelState
        for provider in ('claude', 'codex'):
            model = ModelState(Broker(), '/fixture/graftty')
            nonce = 'b' * 32
            field = 'messages' if provider == 'claude' else 'input'
            body = {field: [{'role': 'user', 'content': 'GRAFTTY_TEST_PREVIEW_ACK ' + nonce}]}
            self.assertEqual('preview-ack:' + nonce, model.plan(body, provider, provider)[3])
            self.assertIn((provider, nonce, 'preview-ack'), model.receipts)
            body[field].append({'role': 'user', 'content': 'Stop hook: Before finishing, run graftty attention report --stdin'})
            self.assertIsNotNone(model.plan(body, provider, provider)[2])
            key = next(iter(model.recaps_issued))
            self.assertEqual(nonce, model.recap_contexts[key])
            body[field].append({'type': 'function_call_output', 'output': f'GRAFTTY_RECAP_OK {provider} {key}'})
            model.plan(body, provider, provider)
            self.assertIn((provider, nonce), model.completed_preview_recaps)


class PreviewSourceProvenanceTests(unittest.TestCase):
    def test_new_unstaged_source_cannot_escape_the_recorded_git_diff(self):
        from pathlib import Path
        import subprocess
        import tempfile
        from unittest.mock import patch
        from preview_scenario import require_tracked_preview_sources
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            source = root / 'scripts/agent-integration/new_scenario.py'
            source.parent.mkdir(parents=True)
            source.write_text('NEW_VALIDATION_INPUT = True\n')
            with patch('run.REPO', root):
                with self.assertRaisesRegex(InvariantFailure, 'Stage new integration source'):
                    require_tracked_preview_sources()
                subprocess.run(['git', '-C', str(root), 'add', 'scripts'], check=True)
                require_tracked_preview_sources()


class PreviewExecutableProvenanceTests(unittest.TestCase):
    def test_registration_evidence_requires_real_hashes_and_excludes_pairing_keys(self):
        from preview_scenario import native_registration_evidence
        registrations = {client: {'nativeExecutable': '/fixture/' + client,
            'nativeExecutableSHA256': 'a' * 64, 'clientKey': 'ephemeral-private-key',
            'fingerprint': 'pairing-record'} for client in ('mac', 'mobile')}
        registrations['gestures'] = {'driver': 'XCUITest'}
        result = native_registration_evidence(registrations)
        self.assertEqual('a' * 64, result['mobile']['nativeExecutableSHA256'])
        self.assertNotIn('clientKey', result['mac'])
        self.assertNotIn('fingerprint', result['mac'])
        for client in ('mac', 'mobile'):
            broken = copy.deepcopy(registrations)
            broken[client]['nativeExecutableSHA256'] = ''
            with self.subTest(client=client), self.assertRaises(InvariantFailure):
                native_registration_evidence(broken)

    def test_node_resolves_actual_optional_package_binary_instead_of_wrapper(self):
        import hashlib
        import json
        import os
        from pathlib import Path
        import subprocess
        import tempfile
        from preview_scenario import resolve_codex_executable
        node = json.loads(subprocess.check_output(['node', '-p',
            'JSON.stringify({platform:process.platform, arch:process.arch})']))
        arch = {'arm64': 'aarch64', 'x64': 'x86_64'}[node['arch']]
        suffix = {'darwin': 'apple-darwin', 'linux': 'unknown-linux-musl', 'win32': 'pc-windows-msvc'}[node['platform']]
        triple = arch + '-' + suffix
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / 'node_modules/@openai/codex'
            entry = package / 'bin/codex.js'
            entry.parent.mkdir(parents=True)
            entry.write_text('// JavaScript launcher, not the native binary\n')
            platform = package.parent / ('codex-' + node['platform'] + '-' + node['arch'])
            platform.mkdir()
            (platform / 'package.json').write_text(json.dumps({'name': '@openai/' + platform.name}))
            native = platform / 'vendor' / triple / 'bin/codex'
            native.parent.mkdir(parents=True)
            native.write_bytes(b'actual native executable bytes')
            evidence = resolve_codex_executable(entry, os.environ.copy())
            self.assertEqual(str(native.resolve()), evidence['path'])
            self.assertEqual(hashlib.sha256(native.read_bytes()).hexdigest(), evidence['sha256'])
            self.assertNotEqual(hashlib.sha256(entry.read_bytes()).hexdigest(), evidence['sha256'])
            self.assertEqual(triple, evidence['targetTriple'])
            self.assertEqual(64, len(evidence['nodeExecutableSHA256']))
            native.unlink()
            with self.assertRaises(InvariantFailure):
                resolve_codex_executable(entry, os.environ.copy())


class PreviewAttentionIsolationTests(unittest.TestCase):
    def test_preview_checks_private_attention_directory_before_marking_manifest(self):
        from pathlib import Path
        import tempfile
        from types import SimpleNamespace
        from unittest.mock import patch
        from run import Run
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner = Run.__new__(Run)
            runner.root = root
            runner.options = SimpleNamespace(preview=True, cli=Path('/fixture/graftty'))
            runner.env, runner.summary = {}, {}
            manifest = {}
            expected = str((root / 'attention').resolve())
            with patch('run.execute', return_value=expected) as execute:
                runner.configure_fixture(manifest)
            self.assertEqual(expected, runner.env['GRAFTTY_ATTENTION_DIR'])
            self.assertEqual(expected, runner.summary['attentionDirectory'])
            self.assertEqual('preview', manifest['scenario'])
            execute.assert_called_once_with(['/fixture/graftty', 'attention', 'directory'], env=runner.env)
            for actual in ('/private/tmp/graftty-attention-501', '', 'attention'):
                manifest = {}
                with patch('run.execute', return_value=actual), self.assertRaises(InvariantFailure):
                    runner.configure_fixture(manifest)
                self.assertNotIn('scenario', manifest)


class PreviewExecutableStabilityTests(unittest.TestCase):
    def test_shared_binary_replacement_fails_even_if_native_tests_pass(self):
        import hashlib
        from pathlib import Path
        import tempfile
        from types import SimpleNamespace
        from preview_scenario import verify_preview_executables
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary = {}
            for name in ('cli', 'zmx', 'codex', 'claude', 'codexNativeExecutable'):
                path = root / name
                path.write_bytes(name.encode())
                summary[name] = {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
            runner = SimpleNamespace(summary=summary)
            verify_preview_executables(runner)
            (root / 'cli').write_bytes(b'other worktree rebuilt this executable')
            with self.assertRaisesRegex(InvariantFailure, 'Executable changed.*cli'):
                verify_preview_executables(runner)


class PreviewManualPermissionTests(unittest.TestCase):
    def test_declines_real_auto_mode_prompt_only_after_native_selection_is_no(self):
        import tempfile
        from pathlib import Path
        from types import SimpleNamespace
        from unittest.mock import Mock
        from preview_scenario import keep_claude_manual
        prompt = ('Make auto mode your default permission mode?\n'
                  '❯ Yes, set auto mode as my default permission mode\n'
                  '  No, keep manual mode')
        selected = prompt.replace('❯ Yes', '  Yes').replace('  No', '❯ No')
        with tempfile.TemporaryDirectory() as directory:
            run = SimpleNamespace(root=Path(directory), summary={'assertions': []}, act=Mock(),
                snapshot=Mock(return_value={'nativeText': selected}),
                wait_snapshot=Mock(side_effect=[{'nativeText': prompt}, {'nativeText': selected}, {'nativeText': '❯ '}]))
            from unittest.mock import patch
            events = []
            run.act.side_effect = lambda action: events.append('Down' if action.parameters.get('submit') == 'false' else 'Return')
            run.snapshot.side_effect = lambda agent: events.append('revalidate No') or {'nativeText': selected}
            with patch('preview_scenario.time.sleep', side_effect=lambda delay: events.append(('settle', delay))):
                keep_claude_manual(run)
            self.assertEqual(['Down', ('settle', 1.0), 'revalidate No', 'Return'], events)
            actions = [call.args[0] for call in run.act.call_args_list]
            self.assertEqual([{'text': '\x1b[B', 'submit': 'false'}, {'text': ''}], [a.parameters for a in actions])
            self.assertTrue(run.summary['assertions'][0]['declinedAutoPermissionsInNativeUI'])
            # The confirmation predicate must reject the still-selected Yes row.
            selected_predicate = run.wait_snapshot.call_args_list[1].args[1]
            self.assertFalse(selected_predicate({'nativeText': prompt}))
            self.assertTrue(selected_predicate({'nativeText': selected}))


    def test_changed_selection_after_settling_never_submits_return(self):
        import tempfile
        from pathlib import Path
        from types import SimpleNamespace
        from unittest.mock import Mock, patch
        from preview_scenario import keep_claude_manual
        prompt = 'Make auto mode your default permission mode?\n  Yes, set auto mode as my default permission mode\n❯ No, keep manual mode'
        with tempfile.TemporaryDirectory() as directory:
            run = SimpleNamespace(root=Path(directory), summary={'assertions': []}, act=Mock(),
                wait_snapshot=Mock(return_value={'nativeText': prompt}),
                snapshot=Mock(return_value={'nativeText': prompt.replace('❯ No', '  No').replace('  Yes', '❯ Yes')}))
            with patch('preview_scenario.time.sleep'), self.assertRaises(InvariantFailure):
                keep_claude_manual(run)
            run.act.assert_not_called()

    def test_dropped_return_retries_once_only_while_no_remains_selected(self):
        import tempfile
        from pathlib import Path
        from types import SimpleNamespace
        from unittest.mock import Mock, patch
        from preview_scenario import keep_claude_manual
        prompt = {'nativeText': 'Make auto mode your default permission mode?\n  Yes, set auto mode as my default permission mode\n❯ No, keep manual mode'}
        with tempfile.TemporaryDirectory() as directory:
            run = SimpleNamespace(root=Path(directory), summary={'assertions': []}, act=Mock(),
                wait_snapshot=Mock(side_effect=[prompt, InvariantFailure('did not dismiss'), {'nativeText': 'idle'}]),
                snapshot=Mock(return_value=prompt))
            with patch('preview_scenario.time.sleep') as settle:
                keep_claude_manual(run)
            self.assertEqual(2, run.act.call_count)
            self.assertEqual(2, settle.call_count)
            self.assertTrue(all(call.args[0].parameters == {'text': ''} for call in run.act.call_args_list))
