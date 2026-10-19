import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from harness import InvariantFailure
from worktree_creation import WorktreeCreationRun, claude_auto_mode_notice_ready


def billing_notice(host='127.0.0.1:54124'):
    return f"""We're changing auto mode to no longer charge for classifier requests in Claude Code.

However, this session isn't eligible because your requests go through {host}, which isn't compatible with this
update.

Nothing breaks: auto mode keeps working, and its classifier requests are billed as before.

To fix it and access the new version of auto mode, ask your gateway to implement:
https://code.claude.com/docs/en/auto-mode-classifier-billing

Enter to continue · Esc to cancel"""


class WorktreeCompletionTests(unittest.TestCase):
    def test_exact_fixture_billing_notice_is_informational(self):
        text = 'Real stop hook and pending recap tool\n' + billing_notice()
        self.assertTrue(claude_auto_mode_notice_ready(text, 'http://127.0.0.1:54124'))
        for altered in (text.replace('54124', '12345'), text + '\nDo you want to allow this?',
                        text.replace('Enter to continue · Esc to cancel', ''),
                        'Enter to continue · Esc to cancel'):
            self.assertFalse(claude_auto_mode_notice_ready(altered, 'http://127.0.0.1:54124'))

    def make_run(self, root, provider='claude'):
        run = object.__new__(WorktreeCreationRun)
        run.root = Path(root)
        run.summary = {'assertions': [], 'providerVersions': {'claude': '2.1.296 (Claude Code)'}}
        run.act = Mock()
        run.approve_known_tools = Mock()
        run.snapshot = Mock(return_value={'nativeText': billing_notice(), 'text': billing_notice()})
        models = SimpleNamespace(pending_tools={provider: 'recap:nonce'}, recaps_done=set(), release=Mock())
        run.server = SimpleNamespace(models=models, endpoint='http://127.0.0.1:54124')
        return run, models

    def test_notice_is_dismissed_once_but_never_counts_as_recap_receipt(self):
        with tempfile.TemporaryDirectory() as root:
            run, models = self.make_run(root)
            def wait(predicate, timeout, tick):
                for _ in range(5):
                    tick()
                self.assertFalse(predicate())
                self.assertEqual(models.recaps_done, set())
                raise InvariantFailure('no actual provider tool result')
            models.wait = wait
            with self.assertRaisesRegex(InvariantFailure, 'no actual provider tool result'):
                run.complete_provider_recap('claude')
            inputs = [call.args[0] for call in run.act.call_args_list if call.args[0].operation == 'input']
            self.assertEqual(len(inputs), 1)
            self.assertEqual(run.snapshot.call_count, 3)
            self.assertEqual(inputs[0].parameters, {'text': ''})
            self.assertGreaterEqual(run.approve_known_tools.call_count, 1)
            evidence = json.loads((run.root / 'claude-creation-completion-notice.json').read_text())
            self.assertEqual(evidence['pendingTool'], 'recap:nonce')
            self.assertEqual(evidence['observation']['nativeText'], billing_notice())
            self.assertEqual(evidence['afterObservation']['nativeText'], billing_notice())
            self.assertFalse(evidence['authenticRecapReceived'])
            self.assertEqual(evidence['providerVersion'], '2.1.296 (Claude Code)')

    def test_unknown_provider_versions_never_acknowledge_the_notice(self):
        for version in (None, '', '2.1.295 (Claude Code)', '2.1.297 (Claude Code)', '2.1.296'):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as root:
                run, models = self.make_run(root)
                run.summary['providerVersions'] = {} if version is None else {'claude': version}
                models.wait = lambda predicate, timeout, tick: [tick() for _ in range(3)]
                run.complete_provider_recap('claude')
                self.assertFalse(any(call.args[0].operation == 'input' for call in run.act.call_args_list))
                self.assertFalse((run.root / 'claude-creation-completion-notice.json').exists())

    def test_real_permission_dialog_is_left_to_existing_approval_handler(self):
        with tempfile.TemporaryDirectory() as root:
            run, models = self.make_run(root)
            run.snapshot.return_value = {'nativeText': billing_notice() + '\nBash command\n'
                                        'Do you want to allow this command?\n1. Yes\n2. No'}
            models.wait = lambda predicate, timeout, tick: [tick() for _ in range(3)]
            run.complete_provider_recap('claude')
            self.assertFalse(any(call.args[0].operation == 'input' for call in run.act.call_args_list))
            self.assertEqual(run.approve_known_tools.call_count, 3)

    def test_receipt_and_after_observation_are_recorded_on_success(self):
        with tempfile.TemporaryDirectory() as root:
            run, models = self.make_run(root)
            before = {'nativeText': billing_notice()}
            after = {'nativeText': 'GRAFTTY_RECAP_OK claude nonce'}
            run.snapshot.side_effect = [before, before, after]
            def wait(predicate, timeout, tick):
                tick(); tick()
                models.recaps_done.add('claude')
                self.assertTrue(predicate())
            models.wait = wait
            run.complete_provider_recap('claude')
            evidence = json.loads((run.root / 'claude-creation-completion-notice.json').read_text())
            self.assertEqual(evidence['observation'], before)
            self.assertEqual(evidence['afterObservation'], after)
            self.assertTrue(evidence['authenticRecapReceived'])

    def test_after_snapshot_error_preserves_original_completion_failure(self):
        with tempfile.TemporaryDirectory() as root:
            run, models = self.make_run(root)
            before = {'nativeText': billing_notice()}
            run.snapshot.side_effect = [before, before, RuntimeError('snapshot transport closed')]
            def wait(predicate, timeout, tick):
                tick(); tick()
                raise InvariantFailure('original missing receipt')
            models.wait = wait
            with self.assertRaisesRegex(InvariantFailure, 'original missing receipt'):
                run.complete_provider_recap('claude')
            evidence = json.loads((run.root / 'claude-creation-completion-notice.json').read_text())
            self.assertIn('snapshot transport closed', evidence['afterObservationError'])
            self.assertFalse(evidence['authenticRecapReceived'])

    def test_codex_and_unrelated_pending_tools_do_not_receive_notice_input(self):
        for provider, token in (('codex', 'recap:nonce'), ('claude', 'reply:nonce')):
            with self.subTest(provider=provider, token=token), tempfile.TemporaryDirectory() as root:
                run, models = self.make_run(root, provider)
                models.pending_tools[provider] = token
                def wait(predicate, timeout, tick):
                    tick(); tick(); tick()
                    self.assertFalse(predicate())
                models.wait = wait
                run.complete_provider_recap(provider)
                self.assertFalse(any(call.args[0].operation == 'input' for call in run.act.call_args_list))
                self.assertEqual(models.recaps_done, set())

    def test_recap_is_released_only_after_mac_can_accept_input(self):
        with tempfile.TemporaryDirectory() as root:
            run, models = self.make_run(root)
            events = []
            run.act.side_effect = lambda action: events.append(action.operation)
            models.release.side_effect = lambda agent, phase: events.append('release-' + phase)
            models.wait = lambda predicate, timeout, tick: events.append('wait-for-real-receipt')
            run.complete_provider_recap('claude')
            self.assertEqual(events, ['visibility', 'takeControl', 'release-recap', 'wait-for-real-receipt'])

    def test_one_snapshot_never_acknowledges_a_notice(self):
        with tempfile.TemporaryDirectory() as root:
            run, models = self.make_run(root)
            models.wait = lambda predicate, timeout, tick: tick()
            run.complete_provider_recap('claude')
            self.assertFalse(any(call.args[0].operation == 'input' for call in run.act.call_args_list))
