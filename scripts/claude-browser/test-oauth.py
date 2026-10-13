#!/usr/bin/env python3
"""Opt-in Claude MCP OAuth regression with a local server and fake keychain.

Usage: test-oauth.py /absolute/path/to/claude [success|wrong-state|denied]
The production open wrapper is rendered from AgentHookInstaller.swift. Only
its graftty executable is replaced with an argv recorder. No live pane is used.
"""
import argparse
import base64
import fcntl
import hashlib
import http.server
import json
import os
import pathlib
import pty
import re
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import textwrap
import threading
import time
import urllib.parse


def executable(path, content):
    path.write_text(content)
    path.chmod(0o700)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('claude', type=pathlib.Path)
    parser.add_argument('case', choices=('success', 'wrong-state', 'denied'), default='success', nargs='?')
    parser.add_argument('--tui', action='store_true')
    parser.add_argument('--reauth', action='store_true', help='Authenticate, then select Re-authenticate in /mcp')
    parser.add_argument('--no-browser', action='store_true', help='Verify manual URL mode does not call an opener')
    parser.add_argument('--custom-browser', action='store_true', help='Verify an explicit BROWSER bypasses managed open')
    options = parser.parse_args()
    options.tui = options.tui or options.reauth
    if options.no_browser and options.tui:
        parser.error('--no-browser is a CLI login option')
    if options.no_browser and options.custom_browser:
        parser.error('choose --no-browser or --custom-browser')
    claude = options.claude.resolve(strict=True)
    case = 'success' if options.reauth else options.case
    chrome = pathlib.Path('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
    assert chrome.is_file()
    root = pathlib.Path(tempfile.mkdtemp(prefix='graftty-claude-oauth-', dir='/private/tmp'))
    state = {'tokens': [], 'requests': [], 'authorizations': []}
    attempts = []
    issued_tokens = []
    authenticated_requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, value, status=200, headers=None):
            data = json.dumps(value).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = urllib.parse.urlparse(self.path).path
            state['requests'].append(('GET', path))
            if 'oauth-protected-resource' in path or path == '/resource-metadata':
                self.reply({'resource': base + '/mcp', 'authorization_servers': [base], 'scopes_supported': ['fixture']})
            elif 'oauth-authorization-server' in path or 'openid-configuration' in path:
                self.reply({'issuer': base, 'authorization_endpoint': base + '/authorize',
                            'token_endpoint': base + '/token', 'registration_endpoint': base + '/register',
                            'response_types_supported': ['code'], 'grant_types_supported': ['authorization_code'],
                            'token_endpoint_auth_methods_supported': ['none'],
                            'code_challenge_methods_supported': ['S256'], 'scopes_supported': ['fixture']})
            elif path == '/authorize':
                state['authorizations'].append(base + self.path)
                query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                fields = {'state': query['state'][0]}
                if case == 'denied':
                    fields['error'] = 'access_denied'
                else:
                    fields['code'] = 'fixture-code'
                if case == 'wrong-state':
                    fields['state'] = 'wrong-state'
                self.send_response(302)
                self.send_header('Location', query['redirect_uri'][0] + '?' + urllib.parse.urlencode(fields))
                self.send_header('Content-Length', '0')
                self.end_headers()
            else:
                self.reply({}, 404)

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            path = urllib.parse.urlparse(self.path).path
            state['requests'].append(('POST', path))
            if path == '/register':
                registration = json.loads(body)
                self.reply({'client_id': 'fixture-client', 'redirect_uris': registration['redirect_uris'],
                            'token_endpoint_auth_method': 'none'}, 201)
            elif path == '/token':
                state['tokens'].append(urllib.parse.parse_qs(body.decode()))
                issued_tokens.append('fixture-only-access-token-' + str(len(issued_tokens) + 1))
                self.reply({'access_token': issued_tokens[-1], 'token_type': 'Bearer',
                            'expires_in': 3600, 'scope': 'fixture'})
            elif path == '/mcp':
                if not issued_tokens or self.headers.get('Authorization') != 'Bearer ' + issued_tokens[-1]:
                    self.reply({}, 401, {'WWW-Authenticate': 'Bearer resource_metadata="' + base + '/resource-metadata"'})
                    return
                authenticated_requests.append(issued_tokens[-1])
                request = json.loads(body)
                method = request.get('method')
                if method == 'initialize':
                    result = {'protocolVersion': '2025-03-26', 'capabilities': {'tools': {}},
                              'serverInfo': {'name': 'fixture', 'version': '1'}}
                elif method == 'tools/list':
                    result = {'tools': []}
                else:
                    result = {}
                if 'id' in request:
                    self.reply({'jsonrpc': '2.0', 'id': request['id'], 'result': result})
                else:
                    self.reply({}, 202)
            else:
                self.reply({}, 404)

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    base = 'http://127.0.0.1:' + str(server.server_port)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    config = root / 'config'
    config.mkdir()
    home = root / 'home'
    home.mkdir()
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    (config / '.claude.json').write_text(json.dumps({
        'hasCompletedOnboarding': True, 'theme': 'dark',
        'customApiKeyResponses': {'approved': ['fixture-only-api-key'], 'rejected': []},
        'mcpServers': {'fixture': {'type': 'http', 'url': base + '/mcp'}},
        'projects': {str(root): {'hasTrustDialogAccepted': True}},
    }))
    (config / 'settings.json').write_text(json.dumps({'autoUpdatesChannel': 'stable'}))
    # Never delegate to the real security utility, even for an unknown request.
    # The native client still performs its own serialization and store calls.
    executable(bin_dir / 'security', '#!' + sys.executable + '\n' + textwrap.dedent('''\
        import hashlib, json, os, pathlib, shlex, sys
        root = pathlib.Path(os.environ['FIXTURE_ROOT'])
        args = sys.argv[1:]
        if args == ['-i']:
            args = shlex.split(sys.stdin.read())
        with (root / 'security-calls.jsonl').open('a') as log:
            log.write(json.dumps(args) + '\\n')
        if args == ['show-keychain-info']:
            sys.exit(0)
        if '-s' not in args:
            sys.exit(90)
        service = args[args.index('-s') + 1]
        suffix = hashlib.sha256(os.environ['CLAUDE_CONFIG_DIR'].encode()).hexdigest()[:8]
        if not service.startswith('Claude Code') or not service.endswith('-' + suffix):
            sys.exit(91)
        target = root / ('keychain-' + hashlib.sha256(service.encode()).hexdigest() + '.json')
        if args[0] == 'find-generic-password':
            if not target.exists():
                sys.exit(44)
            print(target.read_text())
        elif args[0] == 'add-generic-password':
            target.write_text(bytes.fromhex(args[args.index('-X') + 1]).decode())
        elif args[0] == 'delete-generic-password':
            target.unlink(missing_ok=True)
        else:
            sys.exit(92)
        '''))
    recorder = root / 'graftty-recorder'
    executable(recorder, '#!' + sys.executable + '\nimport json, os, pathlib, sys\n'
               'root = pathlib.Path(os.environ["FIXTURE_ROOT"])\n'
               '(root / "offer.tmp").write_text(json.dumps(sys.argv[1:]))\n'
               'os.replace(root / "offer.tmp", root / "offer.json")\n')
    source = (pathlib.Path(__file__).resolve().parents[2] /
              'Sources/GrafttyKit/Teams/AgentHookInstaller.swift').read_text()
    # Fail closed if this small Swift literal gains another interpolation/escape.
    template = source.split('private static func openWrapperScript(grafttyCLIPath: String) -> String {', 1)[1].split('"""')[1]
    version = re.search(r'public static let version = "([^"]+)"', source)[1]
    wrapper = textwrap.dedent(template).strip() + '\n'
    wrapper = wrapper.replace(r'\(version)', version).replace(r'\(shellCommandToken(grafttyCLIPath))', shlex.quote(str(recorder)))
    assert '\\' not in wrapper, 'Update fixture renderer for the changed Swift literal'
    executable(bin_dir / 'open', wrapper)
    # Defense in depth: no external network, real security executable, or caller
    # credential directories. The PATH shim above stores only fixture data.
    profile = root / 'isolation.sb'
    actual_home = pathlib.Path.home()
    profile.write_text('(version 1)\n(allow default)\n'
                       '(deny network*)\n(allow network* (local ip "localhost:*") (remote ip "localhost:*"))\n'
                       '(deny process-exec (literal "/usr/bin/security") (literal "/usr/bin/open"))\n' +
                       ''.join('(deny file-read* file-write* (subpath ' + json.dumps(str(actual_home / path)) + '))\n'
                               for path in ('.claude', '.claude.json', 'Library/Keychains')))
    env = {'PATH': str(bin_dir) + ':/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(home),
           'TMPDIR': str(root), 'CLAUDE_CONFIG_DIR': str(config), 'CLAUDE_SECURESTORAGE_CONFIG_DIR': str(config),
           'FIXTURE_ROOT': str(root), 'USER': 'graftty-fixture', 'TERM': 'xterm-256color',
           'LANG': 'en_US.UTF-8', 'GRAFTTY_SOCK': str(root / 'fake.sock'), 'ZMX_SESSION': 'fixture',
           'ANTHROPIC_API_KEY': 'fixture-only-api-key', 'ANTHROPIC_BASE_URL': base,
           'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'DISABLE_AUTOUPDATER': '1',
           'CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN': '1'}
    if options.custom_browser:
        custom_browser = root / 'custom-browser'
        executable(custom_browser, '#!/bin/sh\nexec ' + shlex.quote(str(recorder)) + ' custom-browser \"$@\"\n')
        env['BROWSER'] = str(custom_browser)
    process = browser = None
    master = slave = None
    raw = bytearray()

    def terminal_text():
        text = re.sub(rb'\x1b\][^\x07]*\x07', b'', bytes(raw))
        text = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b' ', text)
        return b' '.join(text.split())

    def pump(seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not select.select([master], [], [], min(.1, max(0, deadline - time.monotonic())))[0]:
                continue
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            raw.extend(data)
            for request, reply in ((b'\x1b[6n', b'\x1b[1;1R'), (b'\x1b[?u', b'\x1b[?0u'),
                                   (b'\x1b[c', b'\x1b[?1;2c'), (b'\x1b]11;?', b'\x1b]11;rgb:0000/0000/0000\x1b\\')):
                if request in data:
                    os.write(master, reply)

    def wait_text(expected, offset=0):
        deadline = time.monotonic() + 20
        while expected not in terminal_text()[offset:] and time.monotonic() < deadline:
            pump(.1)
            if process.poll() is not None:
                break
        assert expected in terminal_text()[offset:], 'Missing TUI text: ' + repr(expected)

    def open_mcp_menu(reauth=False):
        offset = len(terminal_text())
        os.write(master, b'/mcp')
        pump(.3)
        os.write(master, b'\r')
        wait_text(b'https://code.claude.com/docs/en/mcp for help', offset)
        pump(.1)
        os.write(master, b'\r')
        wait_text(b'Re-authenticate' if reauth else b'Authenticate', offset)
        if reauth:
            # The connected server defaults to Reconnect; select item 1.
            os.write(master, b'1')
            pump(.3)
        os.write(master, b'\r')

    def check_attempt():
        nonlocal browser
        offer = root / 'offer.json'
        for _ in range(200):
            pump(.1)
            if options.no_browser and re.search(rb'(http://127\.0\.0\.1:[0-9]+/authorize\?[^\x07\x1b\s]+)(?=[\x07\x1b\s])', raw):
                break
            if offer.exists() or process.poll() is not None:
                break
        if options.no_browser:
            assert not offer.exists(), 'Manual URL mode invoked an opener'
            auth_url = re.search(rb'(http://127\.0\.0\.1:[0-9]+/authorize\?[^\x07\x1b\s]+)(?=[\x07\x1b\s])', raw)[1].decode()
        else:
            assert offer.exists(), 'No opener handoff: ' + raw.decode(errors='replace')[-2500:]
            args = json.loads(offer.read_text())
            assert len(args) == 2 and args[0] == ('custom-browser' if options.custom_browser else 'open')
            auth_url = args[1]
        for _ in range(50):
            if auth_url.encode() in raw:
                break
            pump(.1)
        assert auth_url.encode() in raw, 'Opener URL differs from the native authorization link'
        parsed = urllib.parse.urlparse(auth_url)
        assert parsed.scheme == 'http' and parsed.netloc == urllib.parse.urlparse(base).netloc
        query = urllib.parse.parse_qs(parsed.query)
        assert query['code_challenge_method'] == ['S256'] and query['state']
        assert query['client_id'] == ['fixture-client'] and query['response_type'] == ['code']
        callback = urllib.parse.urlparse(query['redirect_uri'][0])
        assert callback.hostname in ('127.0.0.1', 'localhost') and callback.port
        completion = b'Authentication successful.' if options.tui else b'Authenticated with \"fixture\"'
        assert not state['tokens'] and completion not in terminal_text()[text_offset:], 'Enqueue falsely completed OAuth'
        browser_log_path = root / ('browser-' + str(len(attempts) + 1) + '.log')
        with browser_log_path.open('wb') as browser_log:
            browser = subprocess.Popen([str(chrome), '--headless=new', '--dump-dom', '--disable-gpu', '--no-first-run',
                                        '--no-default-browser-check', '--disable-background-networking', '--use-mock-keychain',
                                        '--user-data-dir=' + str(root / 'chrome-profile'), auth_url],
                                       stdout=browser_log, stderr=browser_log, start_new_session=True)
        for _ in range(300):
            pump(.1)
            if options.tui and completion in terminal_text()[text_offset:]:
                break
            if case == 'wrong-state' and 'Invalid state parameter' in browser_log_path.read_text(errors='replace'):
                pump(1)
                break
            if options.tui and case == 'denied' and b'OAuth error: access_denied' in terminal_text()[text_offset:]:
                break
            if process.poll() is not None:
                pump(.2)
                break
        assert state['authorizations'] == [auth_url], 'Browser changed the original authorization URL'
        if case == 'success':
            assert len(state['tokens']) == 1
            token = state['tokens'][0]
            challenge = base64.urlsafe_b64encode(hashlib.sha256(token['code_verifier'][0].encode()).digest()).decode().rstrip('=')
            assert challenge == query['code_challenge'][0]
            assert token['code'] == ['fixture-code'] and token['redirect_uri'] == query['redirect_uri']
            assert token['grant_type'] == ['authorization_code'] and token['client_id'] == query['client_id']
            assert completion in terminal_text()[text_offset:], raw.decode(errors='replace')[-2000:]
            if not options.tui:
                assert process.returncode == 0
            assert any(issued_tokens[-1] in path.read_text() for path in root.glob('keychain-*.json')), 'Current token not persisted'
            if options.tui:
                assert re.search(rb'Authentication successful\. (?:Connected|Reconnected) to fixture\.', terminal_text()[text_offset:])
                assert issued_tokens[-1] in authenticated_requests, 'TUI did not reconnect with the current token'
        else:
            assert not state['tokens']
            assert completion not in terminal_text()[text_offset:]
            assert not any('fixture-only-access-token' in path.read_text() for path in root.glob('keychain-*.json'))
            if case == 'wrong-state':
                assert 'Invalid state parameter' in browser_log_path.read_text(errors='replace')
                assert process.poll() is None, 'Wrong state should leave this attempt waiting'
            elif not options.tui:
                assert process.returncode not in (None, 0), raw.decode(errors='replace')[-2000:]
                assert b"Couldn't complete authentication" in raw
            else:
                assert b'OAuth error: access_denied' in terminal_text()[text_offset:]
        if options.no_browser:
            assert not offer.exists(), 'Manual URL mode invoked an opener'
        attempts.append({'case': case, 'tokenExchanges': len(state['tokens']),
                         'completionRendered': case == 'success', 'originalURL': auth_url,
                         'tokens': list(state['tokens'])})
        return auth_url

    try:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        process = subprocess.Popen(['/usr/bin/sandbox-exec', '-f', str(profile), str(claude)] + ([] if options.tui else ['mcp', 'login', 'fixture'] + (['--no-browser'] if options.no_browser else [])),
                                   cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        slave = None
        if options.tui:
            wait_text(b'1 MCP server needs authentication')
            open_mcp_menu()
        text_offset = 0
        first_url = check_attempt()
        if options.reauth:
            browser.wait(timeout=10)
            case = options.case
            state['tokens'].clear()
            state['authorizations'].clear()
            (root / 'offer.json').unlink()
            text_offset = len(terminal_text())
            open_mcp_menu(reauth=True)
            second_url = check_attempt()
            first_query = urllib.parse.parse_qs(urllib.parse.urlparse(first_url).query)
            second_query = urllib.parse.parse_qs(urllib.parse.urlparse(second_url).query)
            assert first_query['state'] != second_query['state']
            assert first_query['code_challenge'] != second_query['code_challenge']
        receipt = {'result': 'passed', 'case': case, 'entrypoint': '/mcp' if options.tui else 'mcp login', 'nativeClaude': str(claude),
                   'productionOpenWrapper': not options.custom_browser and not options.no_browser, 'reauthentication': options.reauth, 'customBrowser': options.custom_browser, 'originalURLPreserved': True,
                   'tokenExchanges': len(state['tokens']), 'completionRendered': case == 'success',
                   'manualURL': options.no_browser, 'attempts': attempts, 'fixture': str(root)}
    finally:
        for child in (browser, process):
            if child is not None and child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except PermissionError:
                    child.terminate()
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except PermissionError:
                        child.kill()
                    except ProcessLookupError:
                        pass
                    child.wait(timeout=5)
        for descriptor in (master, slave):
            if descriptor is not None:
                os.close(descriptor)
        server.shutdown()
        server.server_close()
        shutil.rmtree(root / 'chrome-profile', ignore_errors=True)
        (root / 'terminal.raw').write_bytes(raw)
        (root / 'requests.json').write_text(json.dumps({**state, 'attempts': attempts, 'authenticatedRequests': authenticated_requests}, indent=2))
        print('Fixture evidence:', root)
    (root / 'receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps({key: value for key, value in receipt.items() if key != 'attempts'}))


if __name__ == '__main__':
    main()
