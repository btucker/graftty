#!/usr/bin/env python3
"""Opt-in disposable-host probe. No model turns or credential copying.

Run as the managed user with a generated MCP configuration directory and a
Graftty CLI path. An authenticated parent proxy must already be connected.
"""
import json
import os
import pathlib
import selectors
import subprocess
import sys
import time


class RPC:
    def __init__(self, command, env, cwd):
        self.child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.DEVNULL, env=env, cwd=cwd)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.child.stdout, selectors.EVENT_READ)
        self.buffer = b''

    def send(self, value):
        self.child.stdin.write(json.dumps(value).encode() + b'\n')
        self.child.stdin.flush()

    def receive(self, predicate, timeout=35):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                if line:
                    value = json.loads(line)
                    if predicate(value):
                        return value
            if self.selector.select(0.1):
                chunk = os.read(self.child.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError('Agent exited before MCP response')
                self.buffer += chunk
                if len(self.buffer) > 4 * 1024 * 1024:
                    raise RuntimeError('Response limit exceeded')
        raise RuntimeError('MCP response deadline exceeded')

    def close(self):
        self.child.stdin.close()
        try:
            self.child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.child.terminate()
            try:
                self.child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait(timeout=3)
        self.selector.close()


def main():
    root = pathlib.Path(sys.argv[1])
    cli = sys.argv[2]
    installed = '--installed-profile' in sys.argv[3:]
    workspace = pathlib.Path.cwd() if installed else root / 'workspace'
    workspace.mkdir(exist_ok=True)
    environment = {'PATH': os.environ['PATH'], 'HOME': str(root),
                   'CODEX_HOME': str(root / '.codex'), 'CLAUDE_CONFIG_DIR': str(root / '.claude'),
                   'GRAFTTY_SOCK': os.environ['GRAFTTY_SOCK']}
    for directory in ['.codex', '.claude']:
        (root / directory).mkdir(exist_ok=True, mode=0o700)
    if installed:
        # The production placement must have installed these files itself.
        assert (root / '.codex/config.toml').is_file()
        assert (root / '.claude/.claude.json').is_file()
        for directory in ['/run/graftty-mcp', '/opt/graftty-mcp']:
            try:
                (pathlib.Path(directory) / 'must-not-write').write_text('unexpected')
            except OSError as error:
                assert error.errno == 30, 'Mount must be read-only'
            else:
                raise AssertionError('MCP mount was writable')
        forbidden = subprocess.run([cli, 'pane', 'list'], env=environment, cwd=workspace,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        assert forbidden.returncode != 0 and b"only serves this profile" in forbidden.stderr
    else:
        (root / '.codex/config.toml').write_bytes((root / 'codex-mcp.toml').read_bytes())
    configuration = next((root / '.graftty-mcp' if installed else root).glob('????????-????-????-????-????????????.json'))
    if '--expect-revoked' in sys.argv[3:]:
        rejected = subprocess.run(
            [cli, 'remote', 'mcp', 'bridge', '--config', str(configuration)],
            input=b'', stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=environment, cwd=workspace, timeout=15)
        assert rejected.returncode != 0 and not rejected.stdout, 'Revoked grant was accepted'
        print(json.dumps({'revokedGrant': 'rejected'}), flush=True)
        return
    # A copied grant address must not authorize a different assignment.
    changed = json.loads(configuration.read_text())
    changed['scope']['generation'] += 1
    wrong_generation = root / 'wrong-generation.json'
    wrong_generation.write_text(json.dumps(changed))
    rejected = subprocess.run(
        [cli, 'remote', 'mcp', 'bridge', '--config', str(wrong_generation)],
        input=b'', stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        env=environment, cwd=workspace, timeout=15)
    assert rejected.returncode != 0 and not rejected.stdout, 'Changed assignment was accepted'
    print(json.dumps({'changedAssignment': 'rejected'}), flush=True)
    raw = RPC([cli, 'remote', 'mcp', 'bridge', '--config', str(configuration)], environment, workspace)
    try:
        raw.send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
            'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'live-worker', 'version': '1'}}})
        assert 'result' in raw.receive(lambda x: x.get('id') == 1)
        raw.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        raw.send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})
        tools = raw.receive(lambda x: x.get('id') == 2)['result']['tools']
        assert [tool['name'] for tool in tools] == ['touch_parent']
        raw.send({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'touch_parent', 'arguments': {}}})
        result = raw.receive(lambda x: x.get('id') == 3)['result']
        assert result['content'][0]['text'] == 'parent executed'
        print(json.dumps({'bridge': 'passed', 'tool': 'touch_parent', 'execution': 'parent'}), flush=True)
    finally:
        raw.close()

    for runtime in ['codex', 'claude']:
        command = ['codex', 'app-server'] if runtime == 'codex' else [
            'claude', '-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose']
        if runtime == 'claude' and not installed:
            command += ['--strict-mcp-config', '--mcp-config', str(root / 'claude-mcp.json')]
        client = RPC(command, environment, workspace)
        try:
            if runtime == 'codex':
                client.send({'id': 1, 'method': 'initialize', 'params': {
                    'clientInfo': {'name': 'graftty_live_mcp', 'version': '1'}, 'capabilities': {'experimentalApi': True}}})
                assert 'error' not in client.receive(lambda x: x.get('id') == 1)
                client.send({'method': 'initialized', 'params': {}})

            else:
                client.send({'type': 'control_request', 'request_id': 'init', 'request': {'subtype': 'initialize'}})
                response = client.receive(lambda x: x.get('type') == 'control_response')
                assert response['response']['subtype'] == 'success'
            for attempt in range(20):
                if runtime == 'codex':
                    request_id = attempt + 2
                    client.send({'id': request_id, 'method': 'mcpServerStatus/list', 'params': {}})
                    response = client.receive(lambda x: x.get('id') == request_id, timeout=15)
                    assert 'error' not in response, response
                else:
                    client.send({'type': 'control_request', 'request_id': 'status-' + str(attempt), 'request': {'subtype': 'mcp_status'}})
                    response = client.receive(lambda x: x.get('type') == 'control_response', timeout=15)
                    assert response['response']['subtype'] == 'success', response
                if 'touch_parent' in json.dumps(response):
                    break
                time.sleep(0.5)
            assert 'touch_parent' in json.dumps(response), response
            print(json.dumps({'runtime': runtime, 'nativeMCPDiscovery': 'passed', 'tool': 'touch_parent'}), flush=True)
        finally:
            client.close()


if __name__ == '__main__':
    main()
