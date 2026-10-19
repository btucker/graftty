import unittest

from worktree_startup import classify_green, classify_red


class StartupEvidenceTests(unittest.TestCase):
    def test_red_requires_the_targeted_runtime_assertion(self):
        failure = 'REMOTE-22.39 Expectation failed: Structured agent prompt must reach the provider argv'
        self.assertTrue(classify_red(1, failure))
        self.assertFalse(classify_red(0, failure))
        self.assertFalse(classify_red(1, 'error: could not compile REMOTE-22.39'))
        self.assertFalse(classify_red(1, 'REMOTE-22.39 Expectation failed: unrelated assertion'))

    def test_green_requires_both_specs_to_actually_pass(self):
        passing = '\n'.join(f'✔ Test "@spec REMOTE-22.{number}: behavior" passed after 0.1 seconds.'
                            for number in (38, 39))
        self.assertTrue(classify_green(0, passing))
        self.assertFalse(classify_green(1, passing))
        self.assertFalse(classify_green(0, passing.replace('✔ Test "@spec REMOTE-22.39', '↷ Test "@spec REMOTE-22.39')))
        self.assertFalse(classify_green(0, 'REMOTE-22.38 REMOTE-22.39 Test run with 1 test passed after 1 second.'))
