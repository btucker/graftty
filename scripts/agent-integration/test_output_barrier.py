import io
import json
import threading
from types import SimpleNamespace
import unittest

from harness import Broker
from model import reentry_scenario_text
from server import Handler, ModelState


class FlushedOutput(io.BytesIO):
    def __init__(self):
        super().__init__()
        self.published = b''

    def flush(self):
        self.published = super().getvalue()

    def getvalue(self):
        return self.published


class OutputBarrierTests(unittest.TestCase):
    def stream(self, protocol, pause=None, turn="initial"):
        broker = Broker()
        models = ModelState(broker, '/fixture/graftty', rows=3)
        models.fixture_text = reentry_scenario_text
        if pause is not None:
            models.pause_after_output = pause
        for phase in ('begin', 'middle', 'end'):
            models.release(protocol, phase)
        handler = object.__new__(Handler)
        handler.server = SimpleNamespace(models=models, broker=broker)
        handler.wfile = FlushedOutput()
        handler.send_response = lambda status: None
        handler.send_header = lambda key, value: None
        handler.end_headers = lambda: None
        body = {'stream': True,
                'messages' if protocol == 'claude' else 'input': [
                    {'role': 'user', 'content': 'GRAFTTY_TEST_BEGIN ' + protocol}]}
        if turn == 'followup':
            models.initials.add(protocol)
        elif turn == 'recap':
            body['messages' if protocol == 'claude' else 'input'] = [
                {'role': 'user', 'content': 'Stop hook: Before finishing, run graftty attention report --stdin'}]
            models.release(protocol, 'recap')
        thread = threading.Thread(target=handler.model, args=(body, protocol, protocol), daemon=True)
        thread.start()
        return models, handler, thread

    def events(self, handler):
        return [json.loads(line[6:]) for line in handler.wfile.getvalue().decode().splitlines()
                if line.startswith('data: ')]

    def test_creation_output_barrier_finalizes_text_without_finishing_the_turn(self):
        for protocol in ('claude', 'codex'):
            with self.subTest(protocol=protocol):
                models, handler, thread = self.stream(protocol, pause=True)
                try:
                    models.wait(lambda: (protocol, 'output') in models.arrived or protocol in models.completed, timeout=2)
                    self.assertIn((protocol, 'output'), models.arrived,
                                  'Creation output barrier must hold the stream before response completion')
                    events = self.events(handler)
                    if protocol == 'claude':
                        text = ''.join(event['delta']['text'] for event in events
                                       if event['type'] == 'content_block_delta')
                        event_types = [event['type'] for event in events]
                        self.assertEqual(event_types.count('content_block_stop'), 1,
                                         'Claude text block must finalize before the output barrier')
                        self.assertEqual(event_types[-1], 'content_block_stop')
                        terminal_types = {'message_delta', 'message_stop'}
                    else:
                        text = ''.join(event['delta'] for event in events
                                       if event['type'] == 'response.output_text.delta')
                        terminal_types = {'response.output_text.done', 'response.content_part.done',
                                          'response.output_item.done', 'response.completed'}
                    self.assertEqual(text, reentry_scenario_text(3))
                    self.assertTrue(text.endswith('END-GRAFTTY-FIXTURE'))
                    self.assertTrue(terminal_types.isdisjoint(event['type'] for event in events))
                    self.assertNotIn(protocol, models.completed)
                    self.assertTrue(thread.is_alive())
                    models.release(protocol, 'output')
                    thread.join(2)
                    self.assertFalse(thread.is_alive())
                    self.assertIn(protocol, models.completed)
                    self.assertEqual([event['type'] for event in self.events(handler)].count(
                        'message_stop' if protocol == 'claude' else 'response.completed'), 1)
                finally:
                    models.close()
                    thread.join(2)

    def test_existing_scenarios_do_not_acquire_an_output_barrier(self):
        for protocol in ('claude', 'codex'):
            with self.subTest(protocol=protocol):
                models, handler, thread = self.stream(protocol)
                try:
                    thread.join(2)
                    self.assertFalse(thread.is_alive())
                    self.assertIn(protocol, models.completed)
                    self.assertNotIn((protocol, 'output'), models.arrived)
                    self.assertEqual(models.arrived, {(protocol, phase) for phase in ('begin', 'middle', 'end')})
                finally:
                    models.close()
                    thread.join(2)

    def test_opt_in_does_not_gate_noninitial_text_or_real_recap_tool_responses(self):
        for protocol in ('claude', 'codex'):
            for turn in ('followup', 'recap'):
                with self.subTest(protocol=protocol, turn=turn):
                    models, handler, thread = self.stream(protocol, pause=True, turn=turn)
                    try:
                        thread.join(2)
                        self.assertFalse(thread.is_alive())
                        self.assertNotIn((protocol, 'output'), models.arrived)
                        self.assertNotIn(protocol, models.completed)
                        events = self.events(handler)
                        self.assertIn('message_stop' if protocol == 'claude' else 'response.completed',
                                      [event['type'] for event in events])
                        if turn == 'recap':
                            self.assertIn((protocol, 'recap'), models.arrived)
                            self.assertTrue(models.pending_tools[protocol].startswith('recap:'))
                            self.assertIn('attention report --stdin', json.dumps(events))
                            self.assertNotIn(protocol, models.recaps_done)
                        else:
                            self.assertFalse(models.arrived)
                    finally:
                        models.close()
                        thread.join(2)
