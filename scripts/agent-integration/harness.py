"""Deterministic actions, correlated native observations, and invariant checks."""
from dataclasses import dataclass, field
import json
from pathlib import Path
import queue
import random
import re
import threading
import time
import unicodedata


class InvariantFailure(RuntimeError):
    pass


@dataclass(frozen=True)
class Action:
    operation: str
    provider: str = ''
    parameters: dict = field(default_factory=dict)
    client: str = 'mac'


def approval_ready(token, text):
    marker = token.split(':', 1)[1]
    if '\n Bash command\n' in text:
        text = text.rsplit('\n Bash command\n', 1)[1]
    return marker in re.sub(r'[\s\u2500-\u257f]+', '', text) and bool(re.search(
        r'(?i)(do you want to (proceed|allow|run)|would you like to run|allow this)', text))


def assert_buffer_matches(rendered, authoritative):
    expected = re.findall(r'ROW-[0-9]{6}', authoritative)
    actual = re.findall(r'ROW-[0-9]{6}', rendered)
    if not expected:
        raise InvariantFailure('authoritative daemon contains no numbered rows; comparison would be vacuous')
    if actual != expected:
        raise InvariantFailure(f'native row order/content differs from zmx: expected={expected}, actual={actual}')
    native_rows = list(re.finditer(r'ROW-[0-9]{6}', rendered))
    daemon_rows = list(re.finditer(r'ROW-[0-9]{6}', authoritative))
    def content(text, rows, index):
        start = rows[index].end()
        if index + 1 < len(rows):
            end = rows[index + 1].start()
        else:
            end = text.find('END-GRAFTTY-FIXTURE', start)
            if end < 0:
                end = len(text)
        return unicodedata.normalize('NFC', text[start:end].strip())

    for index, label in enumerate(expected):
        daemon_content = content(authoritative, daemon_rows, index)
        # zmx's text export omits parts of complex graphemes. Row identity is
        # checked for all rows; exact content uses ASCII daemon rows only.
        if not daemon_content.isascii():
            continue
        native_content = content(rendered, native_rows, index)
        native_chars = list(re.finditer(r'(\s*)(\S)', native_content))
        daemon_chars = list(re.finditer(r'(\s*)(\S)', daemon_content))
        matches = len(native_chars) == len(daemon_chars)
        for left, right in zip(native_chars, daemon_chars):
            # Physical wraps make separators ambiguous only at line breaks.
            # Preserve literal horizontal spacing everywhere else.
            left_gap, right_gap = left[1], right[1]
            if left[2] != right[2] or ('\n' not in left_gap + right_gap and left_gap != right_gap):
                matches = False
                break
        if not matches:
            raise InvariantFailure(f'native logical row content differs from zmx: {label}')


def patch_xctestrun(value, product_root, endpoint):
    if isinstance(value, dict):
        result = {key: patch_xctestrun(child, product_root, endpoint) for key, child in value.items()}
        if 'TestBundlePath' in result:
            result.setdefault('EnvironmentVariables', {})['GRAFTTY_AGENT_INTEGRATION_URL'] = endpoint
        return result
    if isinstance(value, list):
        return [patch_xctestrun(child, product_root, endpoint) for child in value]
    if isinstance(value, str):
        return value.replace('__TESTROOT__', product_root)
    return value


def seeded_actions(seed, count, providers=('claude', 'codex')):
    rng = random.Random(seed)
    actions = []
    for _ in range(count):
        operation = rng.choice(('resize', 'takeControl', 'scroll', 'select', 'reconnect', 'snapshot', 'message'))
        client = rng.choice(('mac', 'mobile'))
        if operation == 'reconnect':
            client = 'mobile'
        parameters = {}
        provider = rng.choice(providers)
        if operation == 'message':
            client = 'mac'
            parameters = {'recipient': rng.choice([p for p in providers if p != provider]),
                          'urgent': str(bool(rng.getrandbits(1))).lower()}
        elif operation == 'resize':
            width, height = rng.choice(((393, 852), (852, 393), (720, 500), (1200, 800)))
            parameters = {'width': str(width), 'height': str(height)}
        elif operation == 'scroll':
            parameters = {'position': rng.choice(('top', 'bottom', 'middle'))}
        actions.append(Action(operation, provider, parameters, client))
    return actions


def assert_observation(before, after, preserve_anchor=False, preserve_selection=False):
    if not after.get('text', '').strip():
        raise InvariantFailure('native renderer returned blank text')
    if int(after.get('revision', '0')) < int(before.get('revision', '0')):
        raise InvariantFailure(f'ownership revision regressed: {before} -> {after}')
    if preserve_anchor and before.get('anchor') and before['anchor'] != after.get('anchor'):
        raise InvariantFailure(f'reading anchor changed: {before.get("anchor")} -> {after.get("anchor")}')
    if preserve_selection:
        if not before.get('selected'):
            raise InvariantFailure('native selection was not established')
        if before['selected'] != after.get('selected'):
            raise InvariantFailure('selected logical text changed or disappeared')


def assert_lower_viewport(value):
    rows = value.get('physicalRows', '').split('\n')
    if not rows or not '\n'.join(rows[-4:]).strip():
        raise InvariantFailure('lower native viewport is blank')
    if not value.get('grid') or value.get('nativeGrid') != value['grid']:
        raise InvariantFailure('native viewport differs from the authoritative grid')


class Broker:
    def __init__(self, directory=None):
        self.lock = threading.Condition()
        self.queues = {name: queue.Queue() for name in ('mac', 'mobile', 'gestures')}
        self.pending = {}
        self.completed = {}
        self.next_id = 1
        self.directory = Path(directory) if directory else None
        self.registrations = {}
        self.events = []

    def record(self, event):
        with self.lock:
            self.events.append(event)
            if self.directory:
                with (self.directory / 'trace.jsonl').open('a') as stream:
                    stream.write(json.dumps(event, ensure_ascii=False) + '\n')

    def enqueue(self, client, action):
        with self.lock:
            if client not in self.queues:
                raise ValueError('unknown client')
            identifier = self.next_id
            self.next_id += 1
            command = {'id': identifier, 'operation': action.operation,
                       'provider': action.provider, 'parameters': action.parameters}
            self.pending[identifier] = (client, command)
            self.queues[client].put(command)
            self.record({'kind': 'command', 'client': client, **command})
            return identifier

    def next_command(self, client, timeout=1):
        try:
            return self.queues[client].get(timeout=timeout)
        except queue.Empty:
            return {'id': 0, 'operation': 'idle', 'provider': '', 'parameters': {}}

    def observe(self, client, observation):
        with self.lock:
            identifier = observation['id']
            expected = self.pending.get(identifier)
            if not expected or expected[0] != client or identifier in self.completed:
                raise ValueError('unsolicited, duplicate, or wrong-client observation')
            self.completed[identifier] = observation
            self.record({'kind': 'observation', 'client': client, **observation})
            self.lock.notify_all()

    def wait(self, identifier, timeout=60):
        deadline = time.monotonic() + timeout
        with self.lock:
            while identifier not in self.completed:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise InvariantFailure(f'action {identifier} timed out: {self.pending[identifier]}')
                self.lock.wait(remaining)
            observation = self.completed[identifier]
        if observation.get('error'):
            raise InvariantFailure(f'action {identifier}: {observation["error"]}')
        return observation

    def command(self, action, timeout=60):
        return self.wait(self.enqueue(action.client, action), timeout)['values']

    def register(self, client, value):
        with self.lock:
            self.registrations[client] = value
            self.record({'kind': 'registered', 'client': client})
            self.lock.notify_all()

    def wait_registered(self, client, timeout=120):
        deadline = time.monotonic() + timeout
        with self.lock:
            while client not in self.registrations:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise InvariantFailure(f'{client} never registered')
                self.lock.wait(remaining)
            return self.registrations[client]


def shrink(actions, fails):
    """Delta-debug an action list. The caller owns fresh-process replay."""
    result = list(actions)
    granularity = 2
    while len(result) >= 2:
        length = (len(result) + granularity - 1) // granularity
        for start in range(0, len(result), length):
            candidate = result[:start] + result[start + length:]
            if candidate and fails(candidate):
                result = candidate
                granularity = max(2, granularity - 1)
                break
        else:
            if granularity >= len(result):
                break
            granularity = min(len(result), granularity * 2)
    return result
