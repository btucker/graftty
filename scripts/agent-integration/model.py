"""Scripted model adapters. Tool calls run only explicit fixture commands."""
import copy
import json
import re
import shlex
import sys
from pathlib import Path
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'agent-endpoint-spike'))
from fixture import anthropic_events, response_events, scenario_text


def color_scenario_text(rows=100):
    # Repeat so a complete sample stays visible on short mobile viewports.
    sample = '''`COLOR_INLINE`

[COLOR_LINK](https://example.invalid/color)

```python
COLOR_STRING = "emerald"
```

```diff
-COLOR_REMOVED
+COLOR_ADDED
```

'''
    streamed = re.sub(r'(COLOR_[A-Z]+)', r'\1_STREAMED', sample)
    return 'BEGIN-GRAFTTY-FIXTURE\n\n' + sample + streamed + 'END-GRAFTTY-FIXTURE'


def user_text(body, markers_only=False):
    result = []
    for message in body.get('messages', body.get('input', [])):
        if not isinstance(message, dict) or message.get('role') != 'user':
            continue
        content = message.get('content', [])
        parts = [content] if isinstance(content, str) else [p.get('text', '') for p in content if isinstance(p, dict)]
        for text in parts:
            if not markers_only or text.startswith(('GRAFTTY_TEST_', '<graftty-peer-message', '<cross-session-message',
                    'Another Claude session sent a message:\n<cross-session-message')):
                result.append(text)
    return result


def reply_command(cli, identifier, text):
    if not re.fullmatch(r'[A-Za-z0-9-]+', identifier):
        raise ValueError('invalid message ID')
    delimiter = 'GRAFTTY_REPLY_' + uuid.uuid4().hex
    return f'{shlex.quote(cli)} team reply {shlex.quote(identifier)} --stdin <<\'{delimiter}\'\n{text}\n{delimiter}\n'


def model_events(protocol, text=None, tool=None, request_id=None):
    request_id = request_id or uuid.uuid4().hex
    if tool is None:
        source = anthropic_events(text, 'claude-sonnet-4-6') if protocol == 'claude' else response_events(text, 'gpt-5.4')
        for original in source:
            event = copy.deepcopy(original)
            if 'message' in event:
                event['message']['id'] = 'msg_' + request_id
            if 'response' in event:
                event['response']['id'] = request_id
                for item in event['response'].get('output', []):
                    item['id'] = 'msg_' + request_id
            if 'item' in event:
                event['item']['id'] = 'msg_' + request_id
            if 'item_id' in event:
                event['item_id'] = 'msg_' + request_id
            yield event
        return
    call_id = 'call_' + request_id
    arguments = json.dumps(tool['arguments'])
    if protocol == 'claude':
        events = list(anthropic_events('', 'claude-sonnet-4-6'))
        events[0]['message']['id'] = 'msg_' + request_id
        events[1]['content_block'] = {'type': 'tool_use', 'id': call_id, 'name': tool['name'], 'input': {}}
        events.insert(2, {'type': 'content_block_delta', 'index': 0,
                         'delta': {'type': 'input_json_delta', 'partial_json': arguments}})
        events[-2]['delta']['stop_reason'] = 'tool_use'
    else:
        item = {'id': 'fc_' + request_id, 'type': 'function_call', 'call_id': call_id,
                'name': tool['name'], 'arguments': '', 'status': 'in_progress'}
        response = {'id': request_id, 'object': 'response', 'created_at': 0, 'model': 'gpt-5.4',
                    'status': 'in_progress', 'output': []}
        done = {**item, 'arguments': arguments, 'status': 'completed'}
        events = [{'type': 'response.created', 'response': response},
                  {'type': 'response.output_item.added', 'output_index': 0, 'item': item},
                  {'type': 'response.function_call_arguments.delta', 'item_id': item['id'], 'output_index': 0, 'delta': arguments},
                  {'type': 'response.function_call_arguments.done', 'item_id': item['id'], 'output_index': 0, 'arguments': arguments},
                  {'type': 'response.output_item.done', 'output_index': 0, 'item': done},
                  {'type': 'response.completed', 'response': {**response, 'status': 'completed', 'output': [done],
                    'usage': {'input_tokens': 10, 'output_tokens': 20, 'total_tokens': 30}}}]
    for sequence, event in enumerate(events):
        yield {**event, **({'sequence_number': sequence} if protocol == 'codex' else {})}
