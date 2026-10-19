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
