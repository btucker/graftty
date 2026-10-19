#!/usr/bin/env python3
"""Prove real provider clients accept synthetic streamed model output."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import threading
import time

from fixture import FixtureServer

PROMPT = "Render the scripted test response. Do not use tools."


def is_main_request(request):
    body = request["body"]
    for message in body.get("messages", body.get("input", [])):
        if not isinstance(message, dict) or message.get("role") != "user":
            continue
        content = message.get("content", [])
        if content == PROMPT:
            return True
        if isinstance(content, list) and any(part.get("text") == PROMPT for part in content):
            return True
    return False


def prepare(root, provider, base):
    home = root / provider
    home.mkdir()
    # Allowlist prevents live credentials, hooks, and pane registration leaking in.
    env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL") if key in os.environ}
    env.update(HOME=str(home), TMPDIR=str(home), TERM="xterm-256color",
               COLORTERM="truecolor", USER="graftty-fixture")
    if provider == "codex":
        env.update(CODEX_HOME=str(home), OPENAI_API_KEY="fixture-only")
        (home / "config.toml").write_text(
            'model="gpt-5.4"\nmodel_provider="fixture"\n'
            'cli_auth_credentials_store="file"\ncheck_for_update_on_startup=false\n'
            '[model_providers.fixture]\nname="fixture"\n'
            f'base_url="{base}/v1"\nwire_api="responses"\nrequires_openai_auth=false\n'
            'request_max_retries=0\nstream_max_retries=0\n'
            '[projects.' + json.dumps(str(root)) + ']\ntrust_level="trusted"\n')
    else:
        env.update(CLAUDE_CONFIG_DIR=str(home), CLAUDE_SECURESTORAGE_CONFIG_DIR=str(home),
                   ANTHROPIC_API_KEY="fixture-only", ANTHROPIC_BASE_URL=base,
                   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", DISABLE_AUTOUPDATER="1")
        (home / ".claude.json").write_text(json.dumps({"hasCompletedOnboarding": True,
            "theme": "dark", "customApiKeyResponses": {"approved": ["fixture-only"], "rejected": []},
            "projects": {str(root): {"hasTrustDialogAccepted": True}}}))
    return env


def completed_text(record, provider):
    if provider == "claude" and record.get("type") == "assistant":
        message = record.get("message", {})
        if message.get("stop_reason") == "end_turn":
            return "".join(part["text"] for part in message.get("content", []) if part.get("type") == "text")
    if provider == "codex" and record.get("type") == "event_msg":
        payload = record.get("payload", {})
        if payload.get("type") == "task_complete":
            return payload.get("last_agent_message")
    return None


def tui_smoke(binary, provider, env, root, server):
    """Exercise real TUI redraws. Raw bytes are evidence, not a screen oracle."""
    backend = None
    master = slave = None
    process = None
    raw = bytearray()
    sizes = []
    server.release.clear()
    before = len(server.requests)
    transcript_root = root / provider / ("projects" if provider == "claude" else "sessions")
    offsets = {path: path.stat().st_size for path in transcript_root.rglob("*.jsonl")}
    backend_log = (root / f"{provider}.backend.log").open("wb")
    try:
        if provider == "codex":
            socket = root / "app.sock"
            backend = subprocess.Popen([binary, "app-server", "--listen", "unix://" + str(socket)],
                env=env, cwd=root, stdin=subprocess.DEVNULL, stdout=backend_log, stderr=backend_log,
                start_new_session=True)
            deadline = time.monotonic() + 10
            while not socket.exists():
                if backend.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Codex backend did not create its socket")
                time.sleep(.05)
            command = [binary, "--remote", "unix://" + str(socket)]
        else:
            command = [binary, "--model", "claude-sonnet-4-6", "--tools", "",
                       "--strict-mcp-config", "--setting-sources", ""]
        command.append(PROMPT)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        process = subprocess.Popen(command, env=env, cwd=root, stdin=slave, stdout=slave,
                                   stderr=slave, start_new_session=True)
        os.close(slave)
        slave = None
        queries = {b"\x1b[6n": b"\x1b[1;1R", b"\x1b[?u": b"\x1b[?0u",
                   b"\x1b[c": b"\x1b[?1;2c", b"\x1b]11;?": b"\x1b]11;rgb:0000/0000/0000\x1b\\"}
        answered = {key: 0 for key in queries}
        started = None
        deadline = time.monotonic() + 60
        schedule = [(0, 24, 40), (.3, 30, 90), (.6, 40, 120)]
        while time.monotonic() < deadline:
            if select.select([master], [], [], .05)[0]:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                raw.extend(data)
                for query, answer in queries.items():
                    count = raw.count(query)
                    for _ in range(count - answered[query]):
                        os.write(master, answer)
                    answered[query] = count
            if started is None and any(r["path"] in ("/v1/messages", "/v1/responses") and is_main_request(r)
                                       for r in server.requests[before:]):
                started = time.monotonic()
            if started is not None and len(sizes) < len(schedule):
                delay, rows, columns = schedule[len(sizes)]
                if time.monotonic() - started >= delay:
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
                    os.killpg(process.pid, signal.SIGWINCH)
                    sizes.append({"rows": rows, "columns": columns})
                    server.release.set()
            if len(sizes) == len(schedule) and raw:
                for path in transcript_root.rglob("*.jsonl"):
                    with path.open("rb") as transcript:
                        transcript.seek(offsets.get(path, 0))
                        for line in transcript:
                            try:
                                record = json.loads(line)
                            except json.JSONDecodeError:
                                continue  # Writer may still be appending this line.
                            if completed_text(record, provider) == server.text:
                                return {"nativeTranscriptExact": True, "ptyBytes": len(raw), "sizes": sizes,
                                        "remoteAppServer": provider == "codex"}
            if process.poll() is not None:
                break
        raise RuntimeError(f"{provider} TUI did not record exact completed output after resizing; inspect {root}")
    finally:
        server.release.set()
        for child in (process, backend):
            if child is not None and child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
        for fd in (master, slave):
            if fd is not None:
                os.close(fd)
        backend_log.close()
        (root / f"{provider}.pty").write_bytes(raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", type=Path, required=True, help="Unwrapped Codex executable")
    parser.add_argument("--claude", type=Path, required=True, help="Unwrapped Claude executable")
    parser.add_argument("--tui", action="store_true", help="Also resize real TUIs; Codex uses app-server")
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix="graftty-endpoint-", dir="/private/tmp"))
    print(f"Artifacts: {root}", flush=True)
    receipt = {"scope": "exact print/exec and TUI transcript text; no Graftty renderer or messaging", "providers": {}}
    with FixtureServer(root, rows=20, delay=.03 if args.tui else .002) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for provider, binary in (("codex", args.codex), ("claude", args.claude)):
                env = prepare(root, provider, server.base_url)
                binary = str(binary.resolve(strict=True))
                version = subprocess.check_output([binary, "--version"], env=env, cwd=root, text=True).strip()
                prompt = PROMPT
                command = ([binary, "exec", "--skip-git-repo-check", "--json", prompt] if provider == "codex"
                           else [binary, "--print", "--model", "claude-sonnet-4-6", "--tools", "",
                                 "--strict-mcp-config", "--setting-sources", "", prompt])
                result = subprocess.run(command, env=env, cwd=root, stdin=subprocess.DEVNULL,
                                        capture_output=True, timeout=60)
                (root / f"{provider}.stdout").write_bytes(result.stdout)
                (root / f"{provider}.stderr").write_bytes(result.stderr)
                if provider == "codex":
                    messages = [json.loads(line) for line in result.stdout.splitlines()]
                    output = "\n".join(m["item"]["text"] for m in messages
                                       if m.get("type") == "item.completed" and m["item"].get("type") == "agent_message")
                else:
                    output = result.stdout.decode().strip()
                exact = output == server.text
                receipt["providers"][provider] = {"version": version, "exitCode": result.returncode,
                    "exactText": exact, "expectedCharacters": len(server.text), "actualCharacters": len(output)}
                print(json.dumps({provider: receipt["providers"][provider]}), flush=True)
                if result.returncode or not exact:
                    raise RuntimeError(f"{provider} did not return exact fixture text; inspect {root}")
                if args.tui:
                    receipt["providers"][provider]["tui"] = tui_smoke(binary, provider, env, root, server)
                    print(json.dumps({provider: receipt["providers"][provider]["tui"]}), flush=True)
        finally:
            server.shutdown()
            thread.join()
            (root / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS: both real clients completed using the local endpoint", flush=True)


if __name__ == "__main__":
    main()
