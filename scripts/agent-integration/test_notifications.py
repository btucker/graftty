import json
import hashlib
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from harness import InvariantFailure
from model import model_events
from notifications import NotificationRun, assert_notification_evidence, verify_attention_isolation, notification_scenario_text


class NotificationEvidenceTests(unittest.TestCase):
    def test_native_tap_requires_observed_foreground_and_root_view(self):
        runner = NotificationRun.__new__(NotificationRun)
        for result in ({'performed': 'notificationsTap'},
                       {'foreground': 'false', 'rootVisible': 'true'},
                       {'foreground': 'true', 'rootVisible': 'false'}):
            runner.act = Mock(return_value=result)
            with self.subTest(result=result), self.assertRaises(InvariantFailure):
                runner.tap_mobile_notification('claude', {'title': 'Fixture'}, 'cold')
        success = {'foreground': 'true', 'rootVisible': 'true', 'tapCount': '2'}
        runner.act = Mock(return_value=success)
        self.assertEqual(success, runner.tap_mobile_notification('claude', {'title': 'Fixture'}, 'cold'))

    def test_simulator_metadata_uses_the_selected_runtime_not_the_default_option(self):
        runner = NotificationRun.__new__(NotificationRun)
        runner.summary = {}
        selected = {'udid': 'selected-device', 'name': 'Private fixture',
                    'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}
        runtimes = {'runtimes': [{'identifier': 'selected-runtime', 'version': '26.4', 'buildversion': '23E214'}]}
        with patch('notifications.execute', return_value=json.dumps(runtimes)):
            runner.record_simulator(selected, 'selected-runtime')
        self.assertEqual({'udid': 'selected-device', 'name': 'Private fixture',
            'deviceTypeIdentifier': selected['deviceTypeIdentifier'], 'runtimeIdentifier': 'selected-runtime',
            'runtimeVersion': '26.4', 'runtimeBuild': '23E214'}, runner.summary['simulator'])
        with patch('notifications.execute', return_value='{"runtimes":[]}'), self.assertRaises(InvariantFailure):
            runner.record_simulator(selected, 'missing-runtime')

    def test_executable_provenance_hashes_the_actual_input_bytes(self):
        runner = NotificationRun.__new__(NotificationRun)
        runner.summary = {}
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'fixture-binary'
            binary.write_bytes(b'fixture executable')
            runner.options = SimpleNamespace(cli=binary, zmx=binary)
            runner.record_executable_provenance()
            for name in ('cli', 'zmx'):
                self.assertEqual({'path': str(binary), 'sha256': hashlib.sha256(b'fixture executable').hexdigest()},
                                 runner.summary['executables'][name])

    def test_fixture_has_distinct_initial_middle_and_final_stream_barriers(self):
        for provider in ('claude', 'codex'):
            events = model_events(provider, text=notification_scenario_text())
            deltas = sum(event['type'] in ('content_block_delta', 'response.output_text.delta') for event in events)
            self.assertGreaterEqual(deltas, 4)

    def event(self, timestamp=10):
        return {'runtime': 'codex', 'worktree': '/fixture/worktree', 'agentID': 'codex-fixture',
                'sessionID': 'session', 'paneSessionName': 'pane', 'stoppedAt': timestamp,
                'recap': {'title': 'Fixture purpose', 'completed': 'Completed fixture turn'}}

    def observation(self, events):
        attempts = [{'identifier': 'agent-attention:/fixture/worktree', 'title': e['recap']['title'],
                     'body': e['recap']['completed'], 'userInfo': {'runtime': e['runtime'],
                     'worktree_path': e['worktree'], 'session_id': e.get('sessionID'),
                     'pane_session_name': e.get('paneSessionName')}} for e in events]
        return {'events': json.dumps(events), 'attempts': json.dumps(attempts),
                'postedCount': str(len(attempts))}

    def test_requires_actual_provider_identity_recap_and_one_delivery_per_stop(self):
        observation = self.observation([self.event(), self.event(20)])
        assert_notification_evidence(observation, 'codex', '/fixture/worktree', 2)
        for field in ('agentID', 'sessionID', 'paneSessionName', 'recap'):
            event = self.event()
            incomplete = self.observation([event])
            event.pop(field)
            incomplete['events'] = json.dumps([event])
            with self.subTest(field=field), self.assertRaises(InvariantFailure):
                assert_notification_evidence(incomplete, 'codex', '/fixture/worktree', 1)

    def test_rejects_duplicate_capture_wrong_source_and_missing_delivery(self):
        for events in ([self.event(), self.event()], [{**self.event(), 'runtime': 'claude'}],
                       [{**self.event(), 'worktree': '/another'}]):
            with self.subTest(events=events), self.assertRaises(InvariantFailure):
                assert_notification_evidence(self.observation(events), 'codex', '/fixture/worktree', len(events))
        observation = self.observation([self.event()])
        with self.assertRaises(InvariantFailure):
            assert_notification_evidence({**observation, 'postedCount': '2'}, 'codex', '/fixture/worktree', 1)

    def test_native_request_must_retain_the_provider_pane(self):
        observation = self.observation([self.event()])
        attempts = json.loads(observation['attempts'])
        attempts[0]['userInfo'].pop('pane_session_name')
        with self.assertRaises(InvariantFailure):
            assert_notification_evidence({**observation, 'attempts': json.dumps(attempts)},
                'codex', '/fixture/worktree', 1)

    def test_stop_wait_retains_a_late_duplicate_for_count_validation(self):
        runner = NotificationRun.__new__(NotificationRun)
        runner.approve_known_tools = Mock()
        runner.evidence = Mock(side_effect=[self.observation([self.event()]),
            self.observation([self.event(), self.event(20)]), self.observation([self.event(), self.event(20)])])
        with patch('notifications.time.monotonic', side_effect=[0, 0, 0, .2, .2, 1.1, 1.1]), \
             patch('notifications.time.sleep'):
            observed = runner.wait_stops('codex', 1)
        with self.assertRaises(InvariantFailure):
            assert_notification_evidence(observed, 'codex', '/fixture/worktree', 1)

    def test_isolation_fails_closed_for_old_cli_or_different_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {}
            execute = Mock(return_value=str(root / 'attention'))
            verify_attention_isolation(root, Path('/fixture/graftty'), env, execute)
            self.assertEqual(str((root / 'attention').resolve()), env['GRAFTTY_ATTENTION_DIR'])
            self.assertEqual(['/fixture/graftty', 'attention', 'directory'], execute.call_args.args[0])
            for output in ('', '/private/tmp/graftty-attention-501', 'usage: attention report'):
                with self.subTest(output=output), self.assertRaises(InvariantFailure):
                    verify_attention_isolation(root, Path('/fixture/graftty'), {}, Mock(return_value=output))


if __name__ == '__main__':
    unittest.main()
