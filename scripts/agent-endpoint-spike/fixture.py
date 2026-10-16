#!/usr/bin/env python3
"""Loopback-only scripted Messages and Responses SSE endpoint. No upstream calls."""
import argparse
import http.server
import json
from pathlib import Path
import threading
import time
from urllib.parse import urlsplit


def scenario_text(rows=100):
    samples = ["short line", "wrap " * 45, "漢字 café 👩🏽‍💻 e\u0301 " * 12,
               "`path/with/a/very/long/component/" + "x" * 140 + "`",
               "| column | value |\n| --- | --- |\n| width | 1234567890 |"]
    body = "\n".join(f"ROW-{i:06d} {samples[i % len(samples)]}" for i in range(rows))
    return f"BEGIN-GRAFTTY-FIXTURE\n\n{body}\n\nEND-GRAFTTY-FIXTURE"


def anthropic_events(text, model):
    yield {"type": "message_start", "message": {"id": "msg_fixture", "type": "message",
           "role": "assistant", "model": model, "content": [], "stop_reason": None,
           "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 0}}}
    yield {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}
    for line in text.splitlines(keepends=True):
        yield {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": line}}
    yield {"type": "content_block_stop", "index": 0}
    yield {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
           "usage": {"output_tokens": max(1, len(text) // 4)}}
    yield {"type": "message_stop"}


def response_events(text, model):
    item = {"id": "msg_fixture", "type": "message", "role": "assistant", "status": "in_progress", "content": []}
    response = {"id": "resp_fixture", "object": "response", "created_at": 0,
                "model": model, "status": "in_progress", "output": []}
    events = [{"type": "response.created", "response": response},
              {"type": "response.in_progress", "response": response},
              {"type": "response.output_item.added", "output_index": 0, "item": item},
              {"type": "response.content_part.added", "item_id": item["id"], "output_index": 0,
               "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}}]
    for line in text.splitlines(keepends=True):
        events.append({"type": "response.output_text.delta", "item_id": item["id"],
                       "output_index": 0, "content_index": 0, "delta": line})
    part = {"type": "output_text", "text": text, "annotations": []}
    done = {**item, "status": "completed", "content": [part]}
    events.extend([
        {"type": "response.output_text.done", "item_id": item["id"], "output_index": 0,
         "content_index": 0, "text": text},
        {"type": "response.content_part.done", "item_id": item["id"], "output_index": 0,
         "content_index": 0, "part": part},
        {"type": "response.output_item.done", "output_index": 0, "item": done},
        {"type": "response.completed", "response": {**response, "status": "completed", "output": [done],
         "usage": {"input_tokens": 10, "output_tokens": max(1, len(text) // 4),
                   "total_tokens": 10 + max(1, len(text) // 4)}}}])
    for sequence, event in enumerate(events):
        yield {**event, "sequence_number": sequence}


class FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, directory, rows=100, delay=.01, gated=False):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.text = scenario_text(rows)
        self.delay = delay
        self.release = threading.Event()
        if not gated:
            self.release.set()
        self.lock = threading.Lock()
        self.requests = []
        super().__init__(("127.0.0.1", 0), Handler)

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.server_port}"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self.reply({"ready": True})
        else:
            self.reply({"error": "unexpected path", "path": self.path}, 404)

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == "/release":
            self.server.release.set()
            self.reply({"released": True})
            return
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        except (ValueError, json.JSONDecodeError):
            self.reply({"error": "invalid JSON"}, 400)
            return
        # Store synthetic request bodies only; deliberately exclude auth headers.
        with self.server.lock:
            request = {"path": path, "body": body}
            self.server.requests.append(request)
            with (self.server.directory / "requests.jsonl").open("a") as log:
                log.write(json.dumps(request) + "\n")
        if path == "/v1/messages/count_tokens":
            self.reply({"input_tokens": 10})
            return
        if path not in ("/v1/messages", "/v1/responses"):
            self.reply({"error": "unexpected path", "path": path}, 404)
            return
        if not body.get("stream"):
            self.reply({"error": "spike supports streaming only"}, 400)
            return
        events = (anthropic_events if path == "/v1/messages" else response_events)(
            self.server.text, body.get("model", "fixture"))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            for event in events:
                if event["type"] in ("content_block_delta", "response.output_text.delta"):
                    # Bounded barrier lets a future UI driver resize before releasing output.
                    if not self.server.release.wait(60):
                        return
                    time.sleep(self.server.delay)
                payload = f'event: {event["type"]}\ndata: {json.dumps(event)}\n\n'
                self.wfile.write(payload.encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.close_connection = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rows", type=int, default=100)
    parser.add_argument("--delay", type=float, default=.01)
    parser.add_argument("--gated", action="store_true")
    args = parser.parse_args()
    with FixtureServer(args.output, args.rows, args.delay, args.gated) as server:
        print(server.base_url, flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
