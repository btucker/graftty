#!/usr/bin/env python3
"""Opt-in, isolated OAuth smoke test for the patched TUI and stock app-server.

Usage: test-oauth.py PATCHED_TUI NATIVE_CODEX [success|wrong-state|denied]
Uses an ephemeral local OAuth server and dedicated headless Chrome profile.
Never uses the caller's Codex credentials or an existing Chrome profile.
"""
import shutil
import base64, fcntl, hashlib, http.server, json, os, pathlib, pty, select, signal, struct, subprocess, sys, tempfile, threading, time, urllib.parse, urllib.request

case = sys.argv[3] if len(sys.argv) > 3 else 'success'
assert case in ('success', 'wrong-state', 'denied')
chrome = pathlib.Path('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
assert chrome.is_file(), 'Google Chrome is required'
root = pathlib.Path(tempfile.mkdtemp(prefix='graftty-browser-oauth-', dir='/private/tmp'))
os.chmod(root, 0o700)
state = {'tokens': [], 'requests': []}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, value, status=200, headers=None):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        for key, value in (headers or {}).items(): self.send_header(key, value)
        self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        state['requests'].append(('GET', path))
        if 'oauth-protected-resource' in path or path == '/resource-metadata':
            self.reply({'resource': base + '/mcp', 'authorization_servers': [base], 'scopes_supported': ['fixture']})
        elif 'oauth-authorization-server' in path or 'openid-configuration' in path:
            self.reply({'issuer': base, 'authorization_endpoint': base + '/authorize', 'token_endpoint': base + '/token', 'registration_endpoint': base + '/register', 'response_types_supported': ['code'], 'grant_types_supported': ['authorization_code'], 'token_endpoint_auth_methods_supported': ['none'], 'code_challenge_methods_supported': ['S256'], 'scopes_supported': ['fixture']})
        elif path == '/authorize':
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            callback = query['redirect_uri'][0]
            fields = {'state': query['state'][0], 'iss': base}
            if case == 'denied': fields['error'] = 'access_denied'
            else: fields['code'] = 'fixture-code'
            if case == 'wrong-state': fields['state'] = 'wrong-state'
            self.send_response(302)
            self.send_header('Location', callback + '?' + urllib.parse.urlencode(fields))
            self.send_header('Content-Length', '0')
            self.end_headers()
        elif path == '/v1/models': self.reply({'data': []})
        else: self.reply({}, 404)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        path = urllib.parse.urlparse(self.path).path
        state['requests'].append(('POST', path))
        if path == '/register':
            registration = json.loads(body)
            self.reply({'client_id': 'fixture-client', 'redirect_uris': registration['redirect_uris'], 'token_endpoint_auth_method': 'none'}, 201)
        elif path == '/token':
            token = urllib.parse.parse_qs(body.decode())
            state['tokens'].append(token)
            self.reply({'access_token': 'fixture-only-access-token', 'token_type': 'Bearer', 'expires_in': 3600, 'scope': 'fixture'})
        elif path == '/mcp':
            if self.headers.get('Authorization') != 'Bearer fixture-only-access-token':
                self.reply({}, 401, {'WWW-Authenticate': 'Bearer resource_metadata="' + base + '/resource-metadata"'})
            else:
                request = json.loads(body)
                method = request.get('method')
                if method == 'initialize': result = {'protocolVersion': '2025-03-26', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'fixture', 'version': '1'}}
                elif method == 'tools/list': result = {'tools': []}
                else: result = {}
                if 'id' in request: self.reply({'jsonrpc': '2.0', 'id': request['id'], 'result': result})
                else: self.reply({}, 202)
        else: self.reply({}, 404)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
base = 'http://127.0.0.1:' + str(server.server_port)
threading.Thread(target=server.serve_forever, daemon=True).start()
home = root / 'home'; home.mkdir()
(home / 'config.toml').write_text('model="gpt-5.4"\nmodel_provider="fixture"\nmcp_oauth_credentials_store="file"\ncli_auth_credentials_store="file"\n[model_providers.fixture]\nname="fixture"\nbase_url="' + base + '/v1"\nwire_api="responses"\nrequires_openai_auth=false\n[mcp_servers.fixture]\nurl="' + base + '/mcp"\nstartup_timeout_sec=5\n[projects.' + json.dumps(str(root)) + ']\ntrust_level="trusted"\n')
helper = root / 'browser-helper'
offer = root / 'offer'
helper.write_text('#!/bin/sh\n[ "$#" -eq 1 ] || exit 9\nprintf "%s" "$1" > "$FIXTURE_OFFER"\n')
helper.chmod(0o700)
# Pass only process necessities; never inherit access tokens, pane hooks, or
# provider configuration from the live agent running this fixture.
env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL') if key in os.environ}
env.update({'CODEX_HOME': str(home), 'CODEX_BROWSER_COMMAND': str(helper), 'FIXTURE_OFFER': str(offer), 'TERM': 'xterm-256color', 'COLORTERM': 'truecolor', 'OPENAI_API_KEY': 'fixture-only-api-key'})
socket = root / 'app.sock'
backend_log = open(root / 'backend.log', 'wb')
backend = None
tui = None
browser = None
master = None
slave = None
raw = bytearray()
def pump(seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not select.select([master], [], [], min(.1, max(0, deadline-time.monotonic())))[0]: continue
        try: data = os.read(master, 65536)
        except OSError: break
        raw.extend(data)
        if b'\x1b[6n' in data: os.write(master, b'\x1b[1;1R')
        if b'\x1b[?u' in data: os.write(master, b'\x1b[?0u')
        if b'\x1b[c' in data: os.write(master, b'\x1b[?1;2c')
        if b'\x1b]11;?' in data: os.write(master, b'\x1b]11;rgb:0000/0000/0000\x1b\\')
try:
    backend = subprocess.Popen([sys.argv[2], 'app-server', '--listen', 'unix://' + str(socket)], env=env, cwd=root, stdin=subprocess.DEVNULL, stdout=backend_log, stderr=backend_log)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, __import__('termios').TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    for _ in range(100):
        if socket.exists(): break
        if backend.poll() is not None: raise RuntimeError('backend exited')
        time.sleep(.05)
    assert socket.exists()
    tui = subprocess.Popen([sys.argv[1], '--remote', 'unix://' + str(socket), '--no-alt-screen'], env=env, cwd=root, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    slave = None
    for _ in range(200):
        pump(.1)
        if b'gpt-5.4 default' in raw: break
    assert b'gpt-5.4 default' in raw, 'TUI did not finish initialization'
    os.write(master, b'/mcp login fixture')
    pump(1)
    os.write(master, b'\r')
    for _ in range(120):
        pump(.1)
        if offer.exists(): break
        if tui.poll() is not None: raise RuntimeError('TUI exited before handoff')
    assert offer.exists(), 'TUI did not hand off URL'
    auth_url = offer.read_text()
    parsed = urllib.parse.urlparse(auth_url)
    assert parsed.scheme == 'http' and parsed.netloc == urllib.parse.urlparse(base).netloc
    query = urllib.parse.parse_qs(parsed.query)
    assert query['code_challenge_method'] == ['S256'] and query['state']
    callback = urllib.parse.urlparse(query['redirect_uri'][0])
    assert callback.hostname in ('127.0.0.1', 'localhost') and callback.port
    # Navigate the original URL in host Chrome, including the real redirect to
    # this same app-server attempt's listener. Each negative case is a fresh
    # attempt because rejected callbacks intentionally retire the listener.
    browser_log = open(root / 'browser.log', 'wb')
    browser = subprocess.Popen([str(chrome), '--headless=new', '--disable-gpu',
        '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
        '--user-data-dir=' + str(root / 'chrome-profile'), auth_url],
        stdout=browser_log, stderr=browser_log, start_new_session=True)
    expected_terminal = {'success': b'Signed in to fixture', 'wrong-state': b'failed to handle OAuth callback', 'denied': b'OAuth provider returned `access_denied`'}[case]
    for _ in range(300):
        pump(.1)
        if expected_terminal in raw: break
    assert state['requests'].count(('GET', '/authorize')) == 1, 'Chrome did not visit the authorization endpoint exactly once'
    if case == 'success':
        assert len(state['tokens']) == 1, 'Expected one real token exchange'
        token = state['tokens'][0]
        verifier = token['code_verifier'][0]
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
        assert challenge == query['code_challenge'][0]
        assert token['code'] == ['fixture-code'] and token['redirect_uri'] == query['redirect_uri']
        assert b'Signed in to fixture' in raw, 'No real login completion rendered by TUI'
    else:
        assert not state['tokens'], 'Rejected callback exchanged a token'
        assert b'Signed in to fixture' not in raw, 'Rejected callback reported success'
        if case == 'denied':
            assert b'OAuth provider returned `access_denied`' in raw, 'No consent rejection rendered by TUI'
        else:
            assert b'failed to handle OAuth callback' in raw, 'No callback rejection rendered by TUI'
            assert 'Authorization state not found' in (root / 'backend.log').read_text(), 'Native backend did not reject the wrong state'
    receipt = {'result': 'passed', 'case': case, 'fixture': str(root),
        'nativeBackend': sys.argv[2], 'patchedTUI': sys.argv[1],
        'urlHandoff': True, 'hostChromeRedirect': True,
        'tokenExchanges': len(state['tokens']), 'completionRendered': case == 'success'}
    (root / 'receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt))
finally:
    # Cleanup precedes evidence writes so a full disk cannot strand test daemons.
    for process in (browser, tui, backend):
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    for descriptor in (master, slave):
        if descriptor is not None:
            os.close(descriptor)
    server.shutdown()
    server.server_close()
    shutil.rmtree(root / 'chrome-profile', ignore_errors=True)
    (root / 'tui.raw').write_bytes(raw)
    (root / 'requests.json').write_text(json.dumps(state['requests']))
    print('Fixture evidence:', root)
