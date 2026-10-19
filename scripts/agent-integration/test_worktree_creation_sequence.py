"""Regression for checking completed native output at the correct model barrier."""
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from worktree_creation import WorktreeCreationRun


class CreationOutputBarrierTests(unittest.TestCase):
    def test_complete_output_is_checked_while_recap_is_held(self):
        for viewport_only in (False, True):
            with self.subTest(viewport_only=viewport_only):
                self.check_sequence(viewport_only)

    def check_sequence(self, viewport_only):
        providers = ('claude',) if viewport_only else ('claude', 'codex')
        # The server holds the final text delta at `end`; it holds the next
        # Stop-hook tool stream at `recap`. Only the latter has complete output.
        models = SimpleNamespace(
            arrived={(agent, phase) for agent in providers for phase in ('begin', 'middle', 'end')},
            completed=set(), recaps_done=set(), released=set())

        def release(agent, phase):
            models.released.add((agent, phase))
            if phase == 'end':
                models.completed.add(agent)
                models.arrived.add((agent, 'recap'))
            elif phase == 'recap':
                models.recaps_done.add(agent)
        models.release = release
        run = object.__new__(WorktreeCreationRun)
        run.options = SimpleNamespace(worktree_creation_source='cli',
                                      worktree_creation_viewport_only=viewport_only)
        run.paths, run.summary, run.invariant_failures = {}, {'assertions': []}, []
        run.server = SimpleNamespace(models=models, broker=SimpleNamespace(
            registrations={'mac': {}, 'mobile': {}},
            command=Mock(return_value={'viewMounted': 'false', 'session': 'created', 'path': '/created'})))
        run.start_mobile = Mock()
        run.wait_provider_hooks = Mock()
        run.record_stability = Mock()
        run.wait_mobile_keyboard = Mock()
        grid = ['41x23']

        def action(value):
            if value.operation == 'resize':
                grid[0] = value.parameters['width'] + 'x' + value.parameters['height']
            return {}
        run.act = action
        run.snapshot = lambda *args: {'grid': grid[0], 'viewMounted': 'false', 'text': ''}
        run.wait_model = lambda predicate: self.assertTrue(predicate(), 'required model barrier not reached')
        checked = []

        def check_output(agent, stage):
            self.assertIn(agent, models.completed, 'Complete-output assertions ran before the final text delta')
            self.assertIn((agent, 'recap'), models.arrived)
            self.assertNotIn((agent, 'recap'), models.released,
                             'Stop-hook tool UI may replace output while checking it')
            checked.append((agent, stage))
        run.check_mobile_reentry = check_output
        run.check_history = lambda agent: check_output(agent, 'history')

        def complete_recap(agent):
            self.assertIn((agent, 'created-pane-reconnected-output'), checked)
            release(agent, 'recap')
        run.complete_provider_recap = complete_recap
        run.scenarios()
        for agent in providers:
            self.assertIn((agent, 'created-pane-output'), checked)
            self.assertIn((agent, 'created-pane-reconnected-output'), checked)
            self.assertEqual((agent, 'history') in checked, not viewport_only)
            self.assertIn(agent, models.recaps_done)
