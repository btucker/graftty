import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from harness import InvariantFailure
from history_scenario import gesture_backfill, load_history, verify_source_history


class HistoryScenarioTests(unittest.TestCase):
    def test_gesture_requires_both_loaded_growth_and_visible_older_rows(self):
        baseline = {'paging': 'available', 'total': '300', 'len': '37', 'text': 'ROW-000599'}
        samples = [baseline] * 3 + [dict(baseline, total='600'), dict(baseline, total='600', text='ROW-000500')]
        with TemporaryDirectory() as directory, patch('history_scenario.time.sleep'):
            run = SimpleNamespace(root=Path(directory), summary={'assertions': []}, act=Mock(),
                                  wait_snapshot=Mock(return_value=baseline), snapshot=Mock(side_effect=samples))
            gesture_backfill(run, 'codex')
            evidence = json.loads((run.root / 'history-codex-gesture.json').read_text())
        self.assertEqual(3, len(evidence))
        self.assertEqual(2, run.act.call_count)
        self.assertTrue(all(call.args[0].client == 'gestures' for call in run.act.call_args_list))
        self.assertTrue(run.summary['assertions'][0]['gestureLoadedOlderHistory'])

    def test_exhaustive_backfill_rejects_reordered_rows(self):
        with TemporaryDirectory() as directory, patch('history_scenario.time.sleep'):
            run = SimpleNamespace(root=Path(directory), options=SimpleNamespace(rows=3),
                summary={'assertions': []}, server=SimpleNamespace(broker=Mock()),
                snapshot=Mock(side_effect=[{'paging': 'available'}, {'paging': 'complete'}]),
                act=Mock(return_value={'selected': 'ROW-000000\nROW-000002\nROW-000001'}))
            with self.assertRaisesRegex(InvariantFailure, 'missing, duplicate, or reordered'):
                load_history(run, 'claude', 'attach')
            self.assertEqual(2, run.server.broker.command.call_count)
            self.assertEqual('select', run.act.call_args.args[0].operation)
            self.assertFalse(run.summary['assertions'])

    def test_host_refusal_stops_without_repeated_scroll_requests(self):
        with TemporaryDirectory() as directory:
            run = SimpleNamespace(root=Path(directory), server=SimpleNamespace(broker=Mock()),
                                  snapshot=Mock(return_value={'paging': 'pageTooLarge'}))
            with self.assertRaisesRegex(InvariantFailure, 'pageTooLarge'):
                load_history(run, 'codex', 'attach')
            self.assertEqual(1, run.server.broker.command.call_count)

    def test_source_history_rejects_provider_virtualization_before_attach(self):
        with TemporaryDirectory() as directory:
            run = SimpleNamespace(root=Path(directory), options=SimpleNamespace(rows=600),
                summary={'assertions': []}, act=Mock(return_value={
                    'authoritativeText': 'ROW-000599', 'total': '37', 'len': '37'}))
            with self.assertRaisesRegex(InvariantFailure, 'source history'):
                verify_source_history(run, 'claude')
            self.assertEqual('verify', run.act.call_args.args[0].operation)
            self.assertFalse(run.summary['assertions'])
