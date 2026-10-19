import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from verify_history_results import verify_provider_result, verify_swift


class HistoryResultTests(unittest.TestCase):
    def test_nominal_success_with_skipped_providers_is_rejected(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'result.json'
            path.write_text(json.dumps({'result': 'passed', 'assertions': []}))
            with self.assertRaisesRegex(ValueError, 'source history'):
                verify_provider_result(path)

    def test_zero_executed_tests_is_not_green(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'red.log').write_text('Test run with 1 test in 1 suite failed after 1 second with 1 issue\n'
                'Dense history must arrive as a bounded page, not a host limit refusal')
            (root / 'green.log').write_text('Executed 0 tests, with 0 failures')
            with self.assertRaisesRegex(ValueError, 'focused suites'):
                verify_swift(root)

    def test_failed_structured_result_is_rejected(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'result.json'
            path.write_text(json.dumps({'result': 'failed'}))
            with self.assertRaisesRegex(ValueError, 'did not pass'):
                verify_provider_result(path)
