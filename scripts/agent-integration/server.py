"""Loopback controller and fake model server for the native integration clients."""
import html
import hashlib
import http.server
import json
from pathlib import Path
import re
import shlex
import threading
from urllib.parse import urlsplit
import uuid

from harness import Action, Broker, InvariantFailure
from model import model_events, reply_command, scenario_text, user_text


class ModelState:
    def __init__(self, broker, cli, rows=300):
        self.broker = broker
        self.cli = cli
        self.rows = rows
        self.fixture_text = scenario_text
        self.pause_after_output = False
        self.condition = threading.Condition()
        self.barriers = {}
        self.arrived = set()
        self.completed = set()
        self.receipts = {}
        self.reply_tools = {}
        self.tool_results = set()
        self.initials = set()
        self.pending_tools = {}
        self.recaps_issued = set()
        self.recaps_done = set()
        self.closed = False

    def gate(self, agent, phase):
        key = (agent, phase)
        with self.condition:
            self.arrived.add(key)
            self.condition.notify_all()
            event = self.barriers.setdefault(key, threading.Event())
        self.broker.record({'kind': 'barrier', 'agent': agent, 'phase': phase})
        if not event.wait(600) or self.closed:
            raise InvariantFailure(f'model barrier expired: {key}')

    def release(self, agent, phase):
        with self.condition:
            self.barriers.setdefault((agent, phase), threading.Event()).set()

    def wait(self, predicate, timeout=60, tick=None):
        import time
        deadline = time.monotonic() + timeout
        while True:
            with self.condition:
                if predicate():
                    return
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise InvariantFailure(f'model context or stream barrier did not arrive: pending={self.pending_tools}, arrivals={sorted(self.arrived)}, receipts={sorted(self.receipts)}')
            if tick:
                tick()
            with self.condition:
                self.condition.wait(min(remaining, .2) if tick else remaining)

    def close(self):
        with self.condition:
            self.closed = True
            for event in self.barriers.values():
                event.set()
            self.condition.notify_all()

    def plan(self, body, agent, protocol):
        texts = user_text(body, markers_only=True)
        # Request identity is selected from exact test prompts, never a title
        # prompt that happens to quote a conversation containing the nonce.
        for text in reversed(texts):
            begin = re.fullmatch(r'GRAFTTY_TEST_BEGIN ([a-z0-9-]+)', text.strip())
            if begin and agent in ('claude', 'codex'):
                agent = begin[1]
        joined = '\n'.join(texts)
        tool_result_text = []
        for message in body.get('messages', body.get('input', [])):
            if not isinstance(message, dict):
                continue
            if message.get('type') == 'function_call_output':
                tool_result_text.append(str(message.get('output', '')))
            if message.get('role') == 'user' and isinstance(message.get('content'), list):
                tool_result_text.extend(json.dumps(part.get('content', '')) for part in message['content']
                                        if part.get('type') == 'tool_result' and not part.get('is_error'))
        with self.condition:
            for nonce in self.reply_tools:
                if any('GRAFTTY_TOOL_REPLY_OK ' + nonce in text for text in tool_result_text):
                    self.tool_results.add(nonce)
                    if self.pending_tools.get(agent) == 'reply:' + nonce:
                        self.pending_tools.pop(agent)
            for result in tool_result_text:
                for match in re.finditer(r'GRAFTTY_RECAP_OK ([a-z0-9-]+) ([a-f0-9]{64})', result):
                    self.recaps_done.add(match[1])
                    if self.pending_tools.get(agent) == 'recap:' + match[2]:
                        self.pending_tools.pop(agent)
            for match in re.finditer(r'GRAFTTY_TEST_REPLY ([A-Za-z0-9-]+)', joined):
                self.receipts.setdefault((agent, match[1], 'reply'), {'agent': agent, 'nonce': match[1]})
            items = body.get('messages', body.get('input', []))
            last = json.dumps(items[-1]) if items else ''
            if 'graftty attention report --stdin' in last and ('Before finishing' in last or 'Stop hook' in last):
                key = hashlib.sha256((agent + str(len(items)) + last).encode()).hexdigest()
                if key not in self.recaps_issued:
                    self.recaps_issued.add(key)
                    self.pending_tools[agent] = 'recap:' + key
                    recap = {'title': 'Agent fixture ' + agent, 'context': 'Automated native terminal integration',
                             'completed': 'Scripted fixture turn completed', 'next': 'Wait for the next test action',
                             'emoji': '🧪', 'emojiAlternatives': ['📱', '⌨️']}
                    delimiter = 'GRAFTTY_RECAP_' + key
                    command = (f'{shlex.quote(self.cli)} attention report --stdin <<\'{delimiter}\'\n'
                               + json.dumps(recap) + '\n' + delimiter + '\n'
                               + 'fixture_recap_status=$?\n[ "$fixture_recap_status" -eq 0 ] || exit "$fixture_recap_status"\n'
                               + "printf '%s\\n' 'GRAFTTY_RECAP_OK " + agent + " " + key + "'\n")
                    tool = {'name': 'Bash' if protocol == 'claude' else 'exec_command',
                            'arguments': {'command' if protocol == 'claude' else 'cmd': command}}
                    if protocol == 'claude':
                        tool['arguments']['description'] = 'Report isolated fixture completion'
                    self.condition.notify_all()
                    return agent, None, tool, False
            incoming = list(re.finditer(r'GRAFTTY_TEST_MESSAGE ([A-Za-z0-9-]+)', joined))
            if incoming:
                nonce = incoming[-1][1]
                envelope = re.search(r'<graftty-peer-message\b[^>]*\bid="([^"]+)"[^>]*>[^<]*GRAFTTY_TEST_MESSAGE ' + re.escape(nonce), joined, re.DOTALL)
                if not envelope:
                    # Body can include the formatter's contextual preface or
                    # multiple messages. Locate the nearest enclosing header.
                    headers = list(re.finditer(r'<graftty-peer-message\b[^>]*\bid="([^"]+)"', joined[:incoming[-1].start()]))
                    envelope = headers[-1] if headers else None
                if envelope:
                    identifier = html.unescape(envelope[1])
                    self.receipts[(agent, nonce, 'message')] = {'agent': agent, 'nonce': nonce, 'messageID': identifier}
                    self.condition.notify_all()
                    if nonce not in self.reply_tools:
                        command = reply_command(self.cli, identifier, 'GRAFTTY_TEST_REPLY ' + nonce)
                        command += 'fixture_reply_status=$?\n[ "$fixture_reply_status" -eq 0 ] || exit "$fixture_reply_status"\n'
                        command += "printf '%s\\n' 'GRAFTTY_TOOL_REPLY_OK " + nonce + "'\n"
                        self.reply_tools[nonce] = command
                        self.pending_tools[agent] = 'reply:' + nonce
                        tool = {'name': 'Bash' if protocol == 'claude' else 'exec_command',
                                'arguments': {'command' if protocol == 'claude' else 'cmd': command}}
                        if protocol == 'claude':
                            tool['arguments']['description'] = 'Reply to isolated Graftty message ' + nonce
                        else:
                            tool['arguments'].update(sandbox_permissions='require_escalated',
                                justification='Allow the isolated Graftty test reply ' + nonce,
                                login=False, max_output_tokens=1000)
                        return agent, None, tool, False
                    return agent, 'MESSAGE-RECEIVED ' + nonce, None, False
            if any(text.startswith('GRAFTTY_TEST_BEGIN ') for text in texts) and not incoming:
                # A reply turn also contains earlier prompts. Do not replay the
                # initial stream once the same session is handling peer context.
                if agent not in self.initials and not any('<graftty-peer-message' in text for text in texts):
                    self.initials.add(agent)
                    return agent, self.fixture_text(self.rows), None, True
            self.condition.notify_all()
        return agent, 'Graftty integration', None, False


class IntegrationServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, root, cli, rows=300):
        self.root = Path(root)
        self.broker = Broker(root)
        self.models = ModelState(self.broker, cli, rows)
        self.manifest = {}
        super().__init__(('127.0.0.1', 0), Handler)

    @property
    def endpoint(self):
        return f'http://127.0.0.1:{self.server_port}'


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def json(self, value, status=200):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parts = urlsplit(self.path).path.strip('/').split('/')
        try:
            if parts == ['manifest']:
                self.json(self.server.manifest)
            elif len(parts) == 2 and parts[0] == 'commands':
                self.json(self.server.broker.next_command(parts[1]))
            elif len(parts) == 2 and parts[0] == 'registration':
                self.json(self.server.broker.wait_registered(parts[1]))
            else:
                self.json({'error': 'unexpected path'}, 404)
        except (ValueError, KeyError, InvariantFailure) as error:
            self.json({'error': str(error)}, 400)

    def do_POST(self):
        path = urlsplit(self.path).path
        parts = path.strip('/').split('/')
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 <= size <= 16 * 1024 * 1024:
                raise ValueError('body too large')
            body = json.loads(self.rfile.read(size))
            if len(parts) == 2 and parts[0] == 'register':
                self.server.broker.register(parts[1], body)
                self.json({'ok': True})
            elif len(parts) == 2 and parts[0] == 'observations':
                self.server.broker.observe(parts[1], body)
                self.json({'ok': True})
            elif parts == ['rtc', 'offer']:
                self.json(self.server.broker.command(Action('acceptOffer', parameters=body), timeout=25))
            elif len(parts) == 2 and parts[0] == 'client-error':
                self.server.broker.record({'kind': 'client-error', 'client': parts[1], **body})
                self.json({'ok': True})
            elif len(parts) == 4 and parts[0] == 'model':
                protocol = 'claude' if parts[-1] == 'messages' else 'codex'
                self.model(body, self.headers.get('X-Graftty-Test-Agent', parts[1]), protocol)
            elif len(parts) == 5 and parts[0] == 'model' and parts[-1] == 'count_tokens':
                self.json({'input_tokens': 10})
            else:
                self.json({'error': 'unexpected path', 'path': path}, 404)
        except (ValueError, KeyError, InvariantFailure) as error:
            self.json({'error': str(error)}, 400)

    def model(self, body, agent, protocol):
        if not body.get('stream'):
            self.json({'error': 'fixture requires streaming'}, 400)
            return
        identifier = uuid.uuid4().hex
        agent, text, tool, initial = self.server.models.plan(body, agent, protocol)
        self.server.broker.record({'kind': 'model-request', 'agent': agent, 'requestID': identifier,
                                  'protocol': protocol, 'body': body})
        events = list(model_events(protocol, text=text, tool=tool, request_id=identifier))
        deltas = sum(event['type'] in ('content_block_delta', 'response.output_text.delta') for event in events)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        ordinal = 0
        try:
            if tool and self.server.models.pending_tools.get(agent, '').startswith('recap:'):
                # Hold the recap tool response until the controller can handle
                # its approval. Provider Stop hooks may already have rendered;
                # only the opt-in output gate preserves the pre-hook viewport.
                self.server.models.gate(agent, 'recap')
            for event in events:
                if initial and event['type'] in ('content_block_delta', 'response.output_text.delta'):
                    if ordinal == 0:
                        self.server.models.gate(agent, 'begin')
                    elif ordinal == deltas // 2:
                        self.server.models.gate(agent, 'middle')
                    elif ordinal == deltas - 1:
                        self.server.models.gate(agent, 'end')
                    ordinal += 1
                self.wfile.write(f'event: {event["type"]}\ndata: {json.dumps(event)}\n\n'.encode())
                self.wfile.flush()
                if (initial and self.server.models.pause_after_output and ordinal == deltas
                        and event['type'] in ('content_block_delta', 'response.output_text.delta')):
                    # Creation checks need all text, including its final sentinel,
                    # before terminal response events let provider Stop hooks
                    # replace the viewport. Other scenarios retain their gates.
                    self.server.models.gate(agent, 'output')
            if initial:
                with self.server.models.condition:
                    self.server.models.completed.add(agent)
                    self.server.models.condition.notify_all()
            self.server.broker.record({'kind': 'model-completed', 'agent': agent, 'requestID': identifier})
        except (BrokenPipeError, ConnectionResetError, InvariantFailure) as error:
            self.server.broker.record({'kind': 'model-disconnected', 'agent': agent, 'requestID': identifier, 'error': str(error)})
        finally:
            self.close_connection = True
