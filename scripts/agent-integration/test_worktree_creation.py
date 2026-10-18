import unittest

from harness import InvariantFailure
from worktree_creation import assert_stable_grid, assert_history_rows


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
