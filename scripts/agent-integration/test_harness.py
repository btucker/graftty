import json
import unittest

from harness import Action, Broker, InvariantFailure, assert_observation, seeded_actions, shrink, assert_buffer_matches, patch_xctestrun, approval_ready
from model import model_events, user_text, reply_command
from server import ModelState


class SequenceTests(unittest.TestCase):
    def test_xctestrun_paths_are_relocated_in_arrays_and_dictionaries(self):
        value = {'TestBundlePath': '__TESTHOST__/Tests.xctest',
                 'UITargetAppPath': '__TESTROOT__/app', 'DependentProductPaths': ['__TESTROOT__/app']}
        result = patch_xctestrun(value, '/tmp/products', 'http://127.0.0.1:1234')
        self.assertEqual('/tmp/products/app', result['DependentProductPaths'][0])
        self.assertEqual('/tmp/products/app', result['UITargetAppPath'])
        self.assertEqual('__TESTHOST__/Tests.xctest', result['TestBundlePath'])
        self.assertEqual('http://127.0.0.1:1234', result['EnvironmentVariables']['GRAFTTY_AGENT_INTEGRATION_URL'])

    def test_tool_approval_requires_the_current_unique_argument(self):
        self.assertFalse(approval_ready('reply:newnonce', 'oldnonce Do you want to proceed?'))
        self.assertFalse(approval_ready('reply:newnonce', 'newnonce tool is starting'))
        self.assertFalse(approval_ready('reply:newnonce', 'Next tool newnonce\n Bash command\noldnonce\nDo you want to proceed?'))
        self.assertTrue(approval_ready('reply:newnonce', 'new\nnonce\nDo you want to proceed?'))
        self.assertTrue(approval_ready('reply:newnonce', 'new\n│ nonce\nDo you want to proceed?'))

    def test_seed_replays_the_same_actions(self):
        self.assertEqual(seeded_actions(17, 50), seeded_actions(17, 50))
        self.assertNotEqual(seeded_actions(17, 50), seeded_actions(18, 50))
        operations = {a.operation for a in seeded_actions(17, 100)}
        self.assertTrue({'resize', 'takeControl', 'scroll', 'select', 'reconnect', 'snapshot', 'message'} <= operations)

    def test_broker_correlates_observations_and_rejects_duplicates(self):
        broker = Broker()
        action = broker.enqueue('mac', Action('snapshot', 'claude'))
        command = broker.next_command('mac', timeout=.01)
        self.assertEqual(action, command['id'])
        broker.observe('mac', {'id': action, 'values': {'text': 'ok'}})
        self.assertEqual('ok', broker.wait(action, timeout=.01)['values']['text'])
        with self.assertRaises(ValueError):
            broker.observe('mobile', {'id': action, 'values': {}})
        with self.assertRaises(ValueError):
            broker.observe('mac', {'id': action, 'values': {}})

    def test_native_failure_is_not_a_passing_receipt(self):
        broker = Broker()
        action = broker.enqueue('mobile', Action('snapshot', 'codex'))
        broker.observe('mobile', {'id': action, 'error': 'renderer missing', 'values': {}})
        with self.assertRaises(InvariantFailure):
            broker.wait(action, timeout=.01)

    def test_anchor_is_text_not_physical_row_count(self):
        before = {'text': 'ROW-000123 word', 'anchor': 'ROW-000123', 'revision': '7', 'grid': '80x24'}
        assert_observation(before, {'text': 'ROW-000123\nword', 'anchor': 'ROW-000123', 'revision': '8', 'grid': '40x24'}, preserve_anchor=True)
        with self.assertRaises(InvariantFailure):
            assert_observation(before, {**before, 'anchor': 'ROW-000124'}, preserve_anchor=True)
        with self.assertRaises(InvariantFailure):
            assert_observation(before, {**before, 'revision': '6'})

    def test_selection_cannot_disappear_or_pass_vacuously(self):
        before = {'text': 'ROW-000001', 'selected': 'logical text'}
        assert_observation(before, before, preserve_selection=True)
        for selected in ('', 'other'):
            with self.assertRaises(InvariantFailure):
                assert_observation(before, {**before, 'selected': selected}, preserve_selection=True)
        with self.assertRaises(InvariantFailure):
            assert_observation({'text': 'a'}, {'text': 'a'}, preserve_selection=True)

    def test_renderer_row_sequence_matches_the_real_daemon(self):
        assert_buffer_matches('ROW-000001 long\nwrapped\nROW-000002 漢字', 'ROW-000001 long wrapped\nROW-000002 漢字')
        for bad in ('ROW-000002 ROW-000001', 'ROW-000001', 'ROW-000001 ROW-000001 ROW-000002', 'ROW-000001 corrupt ROW-000002', 'blank'):
            with self.assertRaises(InvariantFailure):
                assert_buffer_matches(bad, 'ROW-000001 ROW-000002')
        with self.assertRaises(InvariantFailure):
            assert_buffer_matches('ROW-000001 damaged ROW-000002', 'ROW-000001 intact ROW-000002')
        with self.assertRaises(InvariantFailure):
            assert_buffer_matches('blank', 'blank')

    def test_daemon_grapheme_export_does_not_create_false_failures(self):
        assert_buffer_matches('ROW-000001 漢字 👩🏽‍💻\nROW-000002 tail',
                              'ROW-000001 漢字 👩\nROW-000002 tail')

    def test_shrinker_retains_the_failing_action(self):
        actions = ['resize', 'scroll', 'bad-handoff', 'snapshot', 'scroll']
        self.assertEqual(['bad-handoff'], shrink(actions, lambda values: 'bad-handoff' in values))


class ModelTests(unittest.TestCase):
    def test_auxiliary_title_cannot_claim_a_message_receipt(self):
        body = {'messages': [{'role': 'user', 'content': [{'type': 'text', 'text': 'Generate a title for GRAFTTY_TEST_MESSAGE abc'}]}]}
        self.assertEqual([], user_text(body, markers_only=True))
        body['messages'][0]['content'][0]['text'] = '<graftty-peer-message id="42">\nGRAFTTY_TEST_MESSAGE abc\n</graftty-peer-message>'
        self.assertEqual(1, len(user_text(body, markers_only=True)))

    def test_tool_protocols_stop_for_tool_and_preserve_arguments(self):
        for protocol in ('claude', 'codex'):
            events = list(model_events(protocol, text=None, tool={'name': 'Bash' if protocol == 'claude' else 'exec_command',
                'arguments': {'command' if protocol == 'claude' else 'cmd': "printf 'nonce'"}}, request_id='unique-9'))
            encoded = json.dumps(events)
            self.assertIn('nonce', encoded)
            if protocol == 'claude':
                self.assertEqual('tool_use', events[-2]['delta']['stop_reason'])
            else:
                self.assertEqual('function_call', events[-1]['response']['output'][0]['type'])
                self.assertEqual('unique-9', events[-1]['response']['id'])

    def test_reply_command_does_not_interpolate_message_text_into_shell_code(self):
        command = reply_command('/tmp/graftty cli', '123', 'GRAFTTY_TEST_REPLY $(touch /tmp/bad)')
        self.assertIn("'/tmp/graftty cli'", command)
        self.assertIn("<<'", command)
        with self.assertRaises(ValueError):
            reply_command('/tmp/graftty', 'invalid\nID', 'body')

    def test_message_receipt_requires_real_envelope_and_tool_result(self):
        state = ModelState(Broker(), '/tmp/graftty')
        body = {'messages': [{'role': 'user', 'content': '<graftty-peer-message id="123">\nGRAFTTY_TEST_MESSAGE nonce\n</graftty-peer-message>'}]}
        agent, _, tool, initial = state.plan(body, 'claude', 'claude')
        self.assertFalse(initial)
        self.assertEqual('Bash', tool['name'])
        self.assertIn(('claude', 'nonce', 'message'), state.receipts)
        self.assertNotIn('nonce', state.tool_results)
        body['messages'].append({'role': 'user', 'content': [{'type': 'tool_result', 'content': 'GRAFTTY_TOOL_REPLY_OK nonce'}]})
        state.plan(body, 'claude', 'claude')
        self.assertIn('nonce', state.tool_results)

    def test_quoted_title_does_not_satisfy_context_receipt(self):
        state = ModelState(Broker(), '/tmp/graftty')
        body = {'messages': [{'role': 'user', 'content': 'Generate title: <graftty-peer-message id="123">GRAFTTY_TEST_MESSAGE nonce</graftty-peer-message>'}]}
        state.plan(body, 'claude', 'claude')
        self.assertEqual({}, state.receipts)

    def test_claude_native_preface_preserves_message_receipt(self):
        state = ModelState(Broker(), '/tmp/graftty')
        body = {'messages': [{'role': 'user', 'content': 'Another Claude session sent a message:\n<cross-session-message>\n<graftty-peer-message id="123">\nGRAFTTY_TEST_REPLY nonce\n</graftty-peer-message>\n</cross-session-message>'}]}
        state.plan(body, 'claude', 'claude')
        self.assertIn(('claude', 'nonce', 'reply'), state.receipts)

    def test_stop_hook_requests_a_real_recap_tool_instead_of_replaying_initial_output(self):
        state = ModelState(Broker(), '/tmp/graftty')
        body = {'messages': [{'role': 'user', 'content': 'GRAFTTY_TEST_BEGIN claude'}]}
        self.assertTrue(state.plan(body, 'claude', 'claude')[-1])
        body['messages'].append({'role': 'user', 'content': 'Stop hook feedback:\nBefore finishing, run `graftty attention report --stdin`.'})
        _, _, tool, initial = state.plan(body, 'claude', 'claude')
        self.assertFalse(initial)
        self.assertIn('attention report --stdin', tool['arguments']['command'])


if __name__ == '__main__':
    unittest.main()
