#!/usr/bin/env python3
"""Native discovery and retention checks for disposable AWSLiveHostTests hosts only."""
import json
import os
import pathlib
import selectors
import subprocess
import sys
import time


def is_agent_process(line, runtime):
    words = line.split()
    if not words:
        return False
    executable = pathlib.Path(words[0]).name
    entrypoint = {
        'codex': '/@openai/codex/bin/codex.js',
        'claude': '/@anthropic-ai/claude-code/cli.js',
    }[runtime]
    return executable == runtime or (
        executable in {'node', 'bun'} and len(words) > 1
        and (pathlib.Path(words[1]).name == runtime or words[1].endswith(entrypoint))
    )


records = json.loads(pathlib.Path(sys.argv[1]).read_text())
for record in records:
    env = record['environment']
    container = env['containerID']
    home = env['agentSkillHome']
    workspace = env['remoteWorkspaceFolder']
    runtime = record['intent']['devContainer']['agentRuntime']
    if len(sys.argv) > 2 and sys.argv[2] == 'retained':
        assert subprocess.run(['docker', 'inspect', container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
        assert subprocess.check_output(['runuser', '-u', 'ubuntu', '--', 'cat', home + '/.codex/retention-probe.txt'], text=True) == 'retained-session-fixture'
        print(json.dumps({'runtime': runtime, 'containerRemoved': True, 'profileRetained': True}))
        continue
    prefix = ['docker', 'exec', '-i', '-u', 'ubuntu', '-w', workspace, container, 'env', 'HOME=' + home, 'CODEX_HOME=' + home + '/.codex', 'CLAUDE_CONFIG_DIR=' + home + '/.claude', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1']
    processes = subprocess.check_output(['docker', 'exec', container, 'ps', '-eo', 'args'], text=True)
    assert any(is_agent_process(line, runtime) for line in processes.splitlines()), 'Agent process missing'
    version = subprocess.check_output(prefix + [runtime, '--version'], text=True).strip()
    native = prefix + ['timeout', '40s'] + (['codex', 'app-server', '--listen', 'stdio://'] if runtime == 'codex' else ['claude', '--print', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--settings', '{"disableAllHooks":true}'])
    child = subprocess.Popen(native, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    buffer = b''

    def send(value):
        child.stdin.write(json.dumps(value).encode() + b'\n')
        child.stdin.flush()

    def receive(predicate):
        global buffer
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                if not line:
                    continue
                value = json.loads(line)
                if predicate(value):
                    return value
            if not selector.select(0.2):
                continue
            chunk = os.read(child.stdout.fileno(), 65536)
            assert chunk, 'Native agent exited before discovery'
            buffer += chunk
            assert len(buffer) < 4 * 1024 * 1024
        raise RuntimeError('Native discovery timed out')
    try:
        if runtime == 'codex':
            send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'graftty_live_probe', 'version': '1'}, 'capabilities': {'experimentalApi': True}}})
            assert 'error' not in receive(lambda x: x.get('id') == 1)
            send({'method': 'initialized', 'params': {}})
            send({'id': 2, 'method': 'skills/list', 'params': {'cwds': [workspace], 'forceReload': True}})
            response = receive(lambda x: x.get('id') == 2)
            names = {skill['name'] for entry in response['result']['data'] for skill in entry['skills']}
        else:
            send({'type': 'control_request', 'request_id': 'live-init', 'request': {'subtype': 'initialize'}})
            response = receive(lambda x: x.get('type') == 'control_response')['response']
            assert response['subtype'] == 'success'
            names = {entry['name'] for entry in response['response']['commands']}
        assert {'graftty-live-parent', 'graftty-live-project'} <= names, names
    finally:
        child.stdin.close()
        try:
            child.wait(timeout=4)
        except subprocess.TimeoutExpired:
            child.terminate()
            child.wait(timeout=5)
        selector.close()
    script = 'set -eu\ngit status --porcelain\ntest ! -L .agents/skills/graftty-live-project\nprintf retained-session-fixture > "$CODEX_HOME/retention-probe.txt"\n'
    subprocess.run(prefix + ['/bin/sh', '-c', script], check=True, capture_output=True)
    value = subprocess.check_output(['runuser', '-u', 'ubuntu', '--', 'cat', home + '/.codex/retention-probe.txt'], text=True)
    assert value == 'retained-session-fixture'
    print(json.dumps({'runtime': runtime, 'version': version, 'skills': sorted(names & {'graftty-live-parent', 'graftty-live-project'}), 'profileReadableOnHost': True}))
