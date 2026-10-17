import json
import unittest

from harness import InvariantFailure, assert_color_samples
from model import color_scenario_text


class NativeColorTests(unittest.TestCase):
    markers = ('COLOR_INLINE', 'COLOR_LINK', 'COLOR_STRING', 'COLOR_REMOVED', 'COLOR_ADDED')

    def test_probe_requires_every_styled_row_not_just_a_colored_link(self):
        samples = dict.fromkeys(self.markers, 30)
        assert_color_samples({'colorPixels': json.dumps(samples)})
        for marker in self.markers:
            for count in (0, -1):
                with self.subTest(marker=marker, count=count), self.assertRaises(InvariantFailure):
                    assert_color_samples({'colorPixels': json.dumps({**samples, marker: count})})
        with self.assertRaises(InvariantFailure):
            assert_color_samples({'colorPixels': json.dumps({'COLOR_LINK': 300})})
        with self.assertRaises(InvariantFailure):
            assert_color_samples({'text': 'all text present'})

    def test_scripted_response_deliberately_exercises_color(self):
        text = color_scenario_text()
        self.assertIn('```python', text)
        self.assertIn('```diff', text)
        self.assertIn('`COLOR_INLINE`', text)
        self.assertIn('[COLOR_LINK](https://example.invalid/color)', text)
        for marker in self.markers:
            self.assertGreaterEqual(text.count(marker), 2)
