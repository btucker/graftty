import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from harness import InvariantFailure, assert_reentry_viewport
from run import Run
from worktree_creation import (WorktreeCreationRun, assert_stable_grid, assert_history_rows,
                               authoritative_history_viewport, provider_hooks_registered)


class WorktreeCreationTests(unittest.TestCase):
    def sample(self, grid='41x24', revision='7', native=None, requests='2'):
        return {'mobile': {'grid': grid, 'nativeGrid': native or grid, 'revision': revision,
                           'pagedGridMismatches': '', 'owner': 'phone', 'ownerResizeRequests': requests},
                'mac': {'grid': grid, 'revision': revision, 'owner': 'phone'}}

    def test_settled_owner_grid_remains_stable(self):
        assert_stable_grid([self.sample() for _ in range(10)])

    def test_resize_oscillation_cannot_pass_by_returning_to_first_size(self):
        with self.assertRaises(InvariantFailure):
            assert_stable_grid([self.sample(), self.sample('80x24', '8'), self.sample(revision='9')])

    def test_same_grid_resize_feedback_and_wrong_parser_are_rejected(self):
        for samples in ([self.sample(), self.sample(revision='8'), self.sample(revision='9')],
                        [self.sample(native='80x24')] * 3):
            with self.assertRaises(InvariantFailure):
                assert_stable_grid(samples)

    def test_missing_observations_cannot_establish_stability(self):
        for samples in ([], [self.sample()], [{'mobile': {}, 'mac': {}}] * 3):
            with self.assertRaises(InvariantFailure):
                assert_stable_grid(samples)

    def test_same_grid_requests_cannot_hide_behind_unchanged_revision(self):
        with self.assertRaises(InvariantFailure):
            assert_stable_grid([self.sample(requests=str(count)) for count in range(3)])

    def test_request_evidence_is_required(self):
        value = self.sample()
        del value['mobile']['ownerResizeRequests']
        with self.assertRaises(InvariantFailure):
            assert_stable_grid([value] * 3)

    def test_history_checks_complete_rows_between_clipped_edges(self):
        source = 'ROW-000001 first\nROW-000002 second\nROW-000003 third\nROW-000004 fourth'
        assert_history_rows('ROW-000001 st\nROW-000002 second\nROW-000003 th', source)
        for text in ('ROW-000001 st\nROW-000002 wrong\nROW-000003 th', 'ROW-000002 second'):
            with self.assertRaises(InvariantFailure):
                assert_history_rows(text, source)

    def assert_history_viewport(self, visible, authoritative):
        expected = authoritative_history_viewport(visible, authoritative)
        assert_reentry_viewport({'physicalRows': visible, 'grid': '41x24', 'nativeGrid': '41x24',
                                'pagedGridMismatches': ''}, 'claude', expected)

    def test_current_viewport_matches_complete_history_suffix(self):
        rows = [f'ROW-{index:06d} retained output' for index in range(300)]
        source = '\n'.join(rows) + '\nEND-GRAFTTY-FIXTURE\n❯ '
        visible = '\n'.join(rows[-20:]) + '\nEND-GRAFTTY-FIXTURE\n❯ '
        self.assert_history_viewport(visible, source)

    def test_history_viewport_allows_clipped_prefix_and_physical_wraps(self):
        source = 'ROW-000001 retained output\nROW-000002 retained output\nROW-000003 retained output\nEND-GRAFTTY-FIXTURE\n❯ '
        visible = 'ned output\nROW-000002 retained\n output\nROW-000003 retained output\nEND-GRAFTTY-FIXTURE\n❯ '
        self.assert_history_viewport(visible, source)

    def test_history_viewport_rejects_missing_reordered_and_corrupt_tail(self):
        rows = [f'ROW-{index:06d} retained output' for index in range(6)]
        end = '\nEND-GRAFTTY-FIXTURE\n❯ '
        source = '\n'.join(rows) + end
        invalid = [
            '\n'.join(rows[2:5]) + end,  # Stale subset, missing the daemon's last row.
            '\n'.join([rows[2], rows[4], rows[5]]) + end,  # Interior row omitted.
            '\n'.join([rows[3], rows[2], rows[4], rows[5]]) + end,
            '\n'.join(rows[2:] + [rows[5]]) + end,
            '\n'.join(rows[2:]).replace('ROW-000004 retained', 'ROW-000004 corrupted') + end,
            '\n'.join(rows[2:]).replace('ROW-000005 retained output', 'ROW-000005 retained') + end,
            '\n'.join(rows[2:]) + '\n❯ ',  # No complete end sentinel.
            rows[-1] + end,  # Too little numbered evidence.
            'No fixture output\n❯ ',
        ]
        for visible in invalid:
            with self.subTest(visible=visible), self.assertRaises(InvariantFailure):
                self.assert_history_viewport(visible, source)

    def test_history_viewport_rejects_incomplete_or_non_ascii_reference(self):
        visible = 'ROW-000002 retained output\nROW-000003 retained output\nEND-GRAFTTY-FIXTURE\n❯ '
        for source in (visible.replace('END-GRAFTTY-FIXTURE', ''),
                       visible.replace('retained output', 'retained output 👩🏽‍💻')):
            with self.subTest(source=source), self.assertRaises(InvariantFailure):
                self.assert_history_viewport(visible, source)

    def test_only_native_history_leg_selects_a_history_suffix(self):
        run = object.__new__(WorktreeCreationRun)
        for viewport_only in (False, True):
            run.options = SimpleNamespace(worktree_creation_viewport_only=viewport_only)
            for provider in ('claude', 'codex'):
                with patch.object(Run, 'check_mobile_reentry') as check:
                    run.check_mobile_reentry(provider, 'created-pane-output')
                    check.assert_called_once_with(provider, 'created-pane-output',
                        authoritative_viewport=None if viewport_only else authoritative_history_viewport)


class ProviderHookEvidenceTests(unittest.TestCase):
    def row(self, provider='codex', **changes):
        row = dict(path='/fixture/worktree', runtime=provider, reachable='true',
                   transport=provider, runtimeSessionID='session-123', paneSessionName='graftty-created',
                   transportThreadID='session-123' if provider == 'codex' else '')
        row.update(changes)
        return row

    def test_wrapper_presence_is_not_provider_hook_receipt(self):
        for provider in ('claude', 'codex'):
            row = self.row(provider, transport='', runtimeSessionID='', transportThreadID='')
            self.assertFalse(provider_hooks_registered([row], provider, row['path'], 'graftty-created'))

    def test_bound_live_provider_identity_is_required(self):
        for provider in ('claude', 'codex'):
            row = self.row(provider)
            self.assertTrue(provider_hooks_registered([row], provider, row['path'], 'graftty-created'))
            for changes in (dict(path='/other'), dict(runtime='other'), dict(reachable='false'),
                            dict(transport='other'), dict(runtimeSessionID=''), dict(paneSessionName='graftty-other')):
                self.assertFalse(provider_hooks_registered([self.row(provider, **changes)], provider, row['path'], 'graftty-created'))
        for thread in ('', 'different-session'):
            self.assertFalse(provider_hooks_registered([self.row(transportThreadID=thread)],
                                                      'codex', '/fixture/worktree', 'graftty-created'))

    def test_wait_accepts_delayed_binding_and_preserves_evidence(self):
        run = object.__new__(WorktreeCreationRun)
        run.paths = {'codex': {'path': '/fixture/worktree', 'session': 'graftty-created'}}
        wrapper = self.row(transport='', runtimeSessionID='', transportThreadID='')
        bound = self.row()
        with tempfile.TemporaryDirectory() as root:
            run.root = Path(root)
            with patch.object(run, 'act', side_effect=[{'agents': json.dumps([wrapper])},
                                                     {'agents': json.dumps([bound])}]) as act, \
                 patch('worktree_creation.time.monotonic', side_effect=[0, 0]), \
                 patch('worktree_creation.time.sleep'):
                run.wait_provider_hooks('codex')
            self.assertEqual(act.call_count, 2)
            self.assertEqual(json.loads((run.root / 'codex-creation-hooks.json').read_text()), [bound])

    def test_wait_times_out_on_wrapper_only_and_keeps_failure_evidence(self):
        run = object.__new__(WorktreeCreationRun)
        run.paths = {'codex': {'path': '/fixture/worktree', 'session': 'graftty-created'}}
        wrapper = self.row(transport='', runtimeSessionID='', transportThreadID='')
        with tempfile.TemporaryDirectory() as root:
            run.root = Path(root)
            with patch.object(run, 'act', return_value={'agents': json.dumps([wrapper])}) as act, \
                 patch('worktree_creation.time.monotonic', side_effect=[0, 0, 5]), \
                 patch('worktree_creation.time.sleep'), \
                 self.assertRaisesRegex(InvariantFailure, 'did not bind a live native session'):
                run.wait_provider_hooks('codex')
            self.assertEqual(act.call_count, 2)
            self.assertEqual(json.loads((run.root / 'codex-creation-hooks.json').read_text()), [wrapper])
