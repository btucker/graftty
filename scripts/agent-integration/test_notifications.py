import json
import hashlib
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from harness import InvariantFailure, Broker
from server import ModelState
from model import model_events
from notifications import NotificationRun, assert_notification_evidence, verify_attention_isolation, notification_scenario_text


class NotificationEvidenceTests(unittest.TestCase):
    def test_next_stop_waits_for_rendered_input_then_submits_once(self):
        runner = NotificationRun.__new__(NotificationRun)
        runner.act = Mock()
        runner.wait_snapshot = Mock()
        runner.wait_model = Mock()
        runner.model_prompt_receipt = Mock(return_value={'requestID': 'request', 'occurrences': 1})
        runner.summary = {'assertions': []}
        with patch('notifications.time.sleep') as settle:
            runner.submit_next_stop('codex')
        actions = [call.args[0] for call in runner.act.call_args_list]
        self.assertEqual(2, len(actions))
        prompt = actions[0].parameters['text']
        self.assertTrue(prompt.startswith('GRAFTTY_TEST_NEXT_STOP codex '))
        self.assertEqual('false', actions[0].parameters['submit'])
        self.assertEqual({}, actions[1].parameters)
        predicate = runner.wait_snapshot.call_args.args[1]
        self.assertTrue(predicate({'text': prompt}))
        self.assertFalse(predicate({'text': 'not yet entered'}))
        settle.assert_called_once_with(.25)
        self.assertEqual('request', runner.summary['assertions'][0]['nextStopSubmission']['requestID'])

    def test_next_stop_receipt_requires_one_exact_user_prompt(self):
        runner = NotificationRun.__new__(NotificationRun)
        broker = Broker()
        runner.server = SimpleNamespace(broker=broker)
        prompt = 'GRAFTTY_TEST_NEXT_STOP codex nonce'
        def request(text, identifier='request', agent='codex'):
            return {'kind': 'model-request', 'agent': agent, 'requestID': identifier,
                    'body': {'input': [{'role': 'user', 'content': text}]}}
        broker.record(request('<session>' + prompt + '</session>'))
        broker.record(request(prompt, agent='claude'))
        self.assertIsNone(runner.model_prompt_receipt('codex', prompt))
        broker.record(request(prompt))
        broker.record(request(prompt, identifier='continuation'))
        self.assertEqual({'requestID': 'request', 'occurrences': 1}, runner.model_prompt_receipt('codex', prompt))
        duplicate = request(prompt)
        duplicate['body']['input'] *= 2
        broker.record(duplicate)
        with self.assertRaises(InvariantFailure):
            runner.model_prompt_receipt('codex', prompt)

    def test_notification_route_requires_fresh_visible_target_session_content(self):
        runner = NotificationRun.__new__(NotificationRun)
        runner.markers = {'claude': 'NOTIFY_CLAUDE_123', 'codex': 'NOTIFY_CODEX_123'}
        runner.act = Mock(return_value={'foreground': 'true', 'rootVisible': 'true'})
        prepared = {'expectedHost': 'host', 'expectedWorktree': 'worktree', 'expectedPane': 'target',
                    'observationSequence': '5', 'observedAt': '100.0'}
        valid = {'pending': 'false', 'selectedHost': 'host', 'worktree': 'worktree', 'pane': 'target',
                 'fetchCount': '1', 'session': 'target', 'live': 'true', 'mounted': 'true',
                 'surfaceReady': 'true', 'physicalRows': 'NOTIFY_CLAUDE_123', 'nativeGrid': '30x80',
                 'observationSequence': '1', 'observedAt': '101.0'}
        candidates = [valid]
        for field, bad in [('session', 'other'), ('live', 'false'), ('mounted', 'false'),
                           ('surfaceReady', 'false'), ('physicalRows', 'NOTIFY_CODEX_123'),
                           ('physicalRows', 'NOTIFY_CLAUDE_123 NOTIFY_CODEX_123'),
                           ('nativeGrid', ''), ('observationSequence', '0'), ('observedAt', '100.0')]:
            candidates.append({**valid, field: bad})
        decisions = []
        def observe(provider, predicate, **kwargs):
            decisions.extend(predicate(candidate) for candidate in candidates)
            return valid
        runner.wait_mobile_notification = observe
        self.assertEqual(valid, runner.wait_mobile_route('claude', prepared))
        self.assertEqual([True] + [False] * (len(candidates) - 1), decisions)
        self.assertEqual('notificationsCapture', runner.act.call_args.args[0].operation)

    def test_model_completion_marker_is_emitted_by_both_provider_responses(self):
        state = ModelState(Mock(), '/fixture/cli')
        self.assertEqual('Graftty integration', state.plan({}, 'claude', 'claude')[1])
        state.completion_text = lambda provider: 'NOTIFY_' + provider.upper()
        for provider in ('claude', 'codex'):
            self.assertEqual((provider, 'NOTIFY_' + provider.upper(), None, False),
                             state.plan({}, provider, provider))

    def test_active_retry_rejects_lifecycle_rescue_remount_and_different_routes(self):
        valid = {'mode': 'active-retry', 'observedScenePhase': 'active', 'sceneTransitions': '0',
                 'responseCount': '2', 'fetchCount': '2', 'requestCount': '2',
                 'responseIDs': '["same", "same"]', 'responseRoutes': '[{"pane": "target"}, {"pane": "target"}]',
                 'sceneProbeIDs': '["original"]'}
        NotificationRun.assert_active_retry(valid, responses=2, fetches=2)
        for field, bad in [('observedScenePhase', 'inactive'), ('sceneTransitions', '2'),
                           ('responseCount', '1'), ('fetchCount', '1'), ('requestCount', '1'),
                           ('sceneProbeIDs', '["original", "replacement"]'),
                           ('responseRoutes', '[{"pane": "target"}, {"pane": "different"}]')]:
            with self.subTest(field=field), self.assertRaises(InvariantFailure):
                NotificationRun.assert_active_retry({**valid, field: bad}, responses=2, fetches=2)

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
