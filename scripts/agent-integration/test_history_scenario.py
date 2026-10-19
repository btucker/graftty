import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from harness import InvariantFailure
from history_scenario import gesture_backfill, load_history, verify_source_history, ROW_PAYLOAD, row_records, HISTORY_ROWS_END


class HistoryScenarioTests(unittest.TestCase):
    def test_gesture_requires_both_loaded_growth_and_visible_older_rows(self):
        baseline = {'paging': 'available', 'total': '300', 'len': '37', 'offset': '246', 'historyGeneration': '1', 'issuedHistoryRequests': '1', 'importedHistoryPages': '1', 'text': 'ROW-000599'}
        samples = [baseline] * 4 + [dict(baseline, total='600'), dict(baseline, total='600', text='ROW-000500', issuedHistoryRequests='2', importedHistoryPages='2')]
        with TemporaryDirectory() as directory, patch('history_scenario.time.sleep'):
            run = SimpleNamespace(root=Path(directory), summary={'assertions': []}, act=Mock(return_value={'loadedHistory': 'ROW-000550 ROW-000599'}),
                                  wait_snapshot=Mock(return_value=baseline), snapshot=Mock(side_effect=samples))
            gesture_backfill(run, 'codex')
            evidence = json.loads((run.root / 'history-codex-gesture.json').read_text())
        self.assertEqual(3, len(evidence))
        self.assertEqual(3, run.act.call_count)
        self.assertTrue(all(call.args[0].client == 'gestures' for call in run.act.call_args_list[1:]))
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
            run = SimpleNamespace(root=Path(directory), options=SimpleNamespace(rows=3), server=SimpleNamespace(broker=Mock()),
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

    def test_live_rows_do_not_count_as_gesture_backfill(self):
        baseline = {'paging': 'available', 'total': '283', 'len': '37', 'offset': '246', 'historyGeneration': '1', 'issuedHistoryRequests': '1', 'importedHistoryPages': '1', 'text': 'ROW-000567'}
        samples = [baseline] * 4 + [dict(baseline, total='285', text='ROW-000508'),
                                  dict(baseline, total='668', text='ROW-000400', issuedHistoryRequests='2', importedHistoryPages='2')]
        def act(action):
            return {'loadedHistory': 'ROW-000508 ROW-000567 ROW-000599'}
        with TemporaryDirectory() as directory, patch('history_scenario.time.sleep'):
            run = SimpleNamespace(root=Path(directory), summary={'assertions': []}, act=Mock(side_effect=act),
                                  wait_snapshot=Mock(return_value=baseline), snapshot=Mock(side_effect=samples))
            gesture_backfill(run, 'claude')
        gestures = [call for call in run.act.call_args_list if call.args[0].client == 'gestures']
        self.assertEqual(2, len(gestures), 'Spinner growth must not count as imported history')
        self.assertEqual(400, run.summary['assertions'][0]['firstRowAfter'])

    def test_resize_matches_provider_redraw_without_deduplicating_it(self):
        source = '\n'.join(f'ROW-{i:06d} ' + ROW_PAYLOAD for i in (0, 1, 1, 2)) + '\n' + HISTORY_ROWS_END
        def act(action):
            return {'authoritativeText': source} if action.operation == 'verify' else {'selected': source}
        with TemporaryDirectory() as directory, patch('history_scenario.time.sleep'):
            run = SimpleNamespace(root=Path(directory), options=SimpleNamespace(rows=3),
                summary={'assertions': []}, server=SimpleNamespace(broker=Mock()),
                snapshot=Mock(return_value={'paging': 'complete'}), act=Mock(side_effect=act))
            load_history(run, 'claude', 'resized')
            evidence = json.loads((run.root / 'history-claude-resized.json').read_text())
        self.assertEqual([0, 1, 1, 2], evidence['actualRows'])
        self.assertEqual([0, 1, 1, 2], evidence['expectedRows'])

    def test_cached_movement_with_live_growth_does_not_count_as_import(self):
        baseline = {'paging': 'available', 'total': '283', 'len': '37', 'offset': '246', 'text': 'ROW-000567',
                    'historyGeneration': '1', 'issuedHistoryRequests': '1', 'importedHistoryPages': '1'}
        samples = [baseline] * 4 + [dict(baseline, total='285', text='ROW-000520'),
            dict(baseline, total='668', text='ROW-000400', issuedHistoryRequests='2', importedHistoryPages='2')]
        with TemporaryDirectory() as directory, patch('history_scenario.time.sleep'):
            run = SimpleNamespace(root=Path(directory), summary={'assertions': []},
                act=Mock(return_value={'loadedHistory': 'ROW-000508 ROW-000599'}),
                wait_snapshot=Mock(return_value=baseline), snapshot=Mock(side_effect=samples))
            gesture_backfill(run, 'claude')
        self.assertEqual(2, sum(call.args[0].client == 'gestures' for call in run.act.call_args_list))
        self.assertEqual(400, run.summary['assertions'][0]['firstRowAfter'])

    def test_source_oracle_rejects_dropped_extra_and_reordered_rows(self):
        source = '\n'.join(f'ROW-{i:06d} ' + ROW_PAYLOAD for i in (0, 1, 2)) + '\n' + HISTORY_ROWS_END
        for ids in ((0, 1), (0, 1, 1, 2), (0, 2, 1)):
            with self.subTest(ids=ids), TemporaryDirectory() as directory:
                selected = '\n'.join(f'ROW-{i:06d} ' + ROW_PAYLOAD for i in ids) + '\n' + HISTORY_ROWS_END
                run = SimpleNamespace(root=Path(directory), options=SimpleNamespace(rows=3),
                    summary={'assertions': []}, server=SimpleNamespace(broker=Mock()),
                    snapshot=Mock(return_value={'paging': 'complete'}),
                    act=Mock(side_effect=lambda action: {'authoritativeText': source}
                             if action.operation == 'verify' else {'selected': selected}))
                with self.assertRaisesRegex(InvariantFailure, 'missing, duplicate, or reordered'):
                    load_history(run, 'claude', 'resized')

    def test_source_oracle_rejects_payload_corruption(self):
        source = '\n'.join(f'ROW-{i:06d} ' + ROW_PAYLOAD for i in (0, 1, 2)) + '\n' + HISTORY_ROWS_END
        with TemporaryDirectory() as directory:
            run = SimpleNamespace(root=Path(directory), options=SimpleNamespace(rows=3),
                summary={'assertions': []}, server=SimpleNamespace(broker=Mock()),
                snapshot=Mock(return_value={'paging': 'complete'}),
                act=Mock(side_effect=lambda action: {'authoritativeText': source} if action.operation == 'verify'
                         else {'selected': source.replace('HistoryPanel', 'HistoryLost', 1)}))
            with self.assertRaisesRegex(InvariantFailure, 'content differs'):
                load_history(run, 'claude', 'resized')

    def test_source_oracle_rejects_extra_wrapped_payload_without_row_marker(self):
        source = '\n'.join(f'ROW-{i:06d} ' + ROW_PAYLOAD for i in range(3))
        corrupted = source.replace('ROW-000001 ' + ROW_PAYLOAD,
                                   'ROW-000001 ' + ROW_PAYLOAD + '🧪 src/components/HistoryPanel.swift:100 ')
        self.assertNotEqual(row_records(source), row_records(corrupted))
