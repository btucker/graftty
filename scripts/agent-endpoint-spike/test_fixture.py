import unittest

from fixture import anthropic_events, response_events, scenario_text
from smoke import PROMPT, completed_text, is_main_request


class ProtocolTests(unittest.TestCase):
    def test_anthropic_reconstructs_exact_content_and_stops(self):
        expected = scenario_text(8)
        events = list(anthropic_events(expected, "claude-fixture"))
        actual = "".join(event["delta"]["text"] for event in events
                         if event["type"] == "content_block_delta")
        self.assertEqual(expected, actual)
        self.assertEqual("message_stop", events[-1]["type"])
        self.assertEqual("end_turn", events[-2]["delta"]["stop_reason"])

    def test_responses_completes_with_same_content_and_monotonic_sequence(self):
        expected = scenario_text(8)
        events = list(response_events(expected, "gpt-5.4"))
        self.assertEqual(expected, "".join(event["delta"] for event in events
                                         if event["type"] == "response.output_text.delta"))
        self.assertEqual("response.completed", events[-1]["type"])
        self.assertEqual(expected, events[-1]["response"]["output"][0]["content"][0]["text"])
        self.assertEqual(list(range(len(events))), [e["sequence_number"] for e in events])

    def test_numbered_rows_include_width_stress_and_end_marker(self):
        value = scenario_text(100)
        self.assertIn("ROW-000099", value)
        self.assertIn("漢字", value)
        self.assertIn("END-GRAFTTY-FIXTURE", value)
        self.assertGreater(max(map(len, value.splitlines())), 120)

    def test_completion_ignores_partial_messages_and_auxiliary_records(self):
        message = {"content": [{"type": "text", "text": "complete"}], "stop_reason": None}
        self.assertIsNone(completed_text({"type": "assistant", "message": message}, "claude"))
        message["stop_reason"] = "end_turn"
        self.assertEqual("complete", completed_text({"type": "assistant", "message": message}, "claude"))
        self.assertIsNone(completed_text({"type": "event_msg", "payload": {"type": "thread_name_updated"}}, "codex"))
        self.assertEqual("complete", completed_text({"type": "event_msg", "payload": {
            "type": "task_complete", "last_agent_message": "complete"}}, "codex"))

    def test_title_request_does_not_start_resize_schedule(self):
        for key in ("messages", "input"):
            request = {"body": {key: [{"role": "user", "content": [{"type": "text", "text": PROMPT}]}]}}
            self.assertTrue(is_main_request(request))
            request["body"][key][0]["content"][0]["text"] = "Generate a title for: " + PROMPT
            self.assertFalse(is_main_request(request))


if __name__ == "__main__":
    unittest.main()
