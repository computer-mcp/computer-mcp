"""Loopback Responses fixture; only the native Codex process executes test commands."""

import http.server
import json
from pathlib import Path
import sys
import threading
import time
import uuid

root = Path(sys.argv[1])
consumed = set()
calls = {}
lock = threading.Lock()
finish = threading.Event()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path != "/probe":
            self.send_error(404)
            return
        data = (root / "network-token").read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.headers.get("Authorization"):
            self.send_error(400, "Authentication is not part of this fixture")
            return
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 4_194_304 or self.path != "/v1/responses":
            self.send_error(400)
            return
        payload = json.loads(self.rfile.read(length))
        recipe = json.loads((root / "response.json").read_text())
        phase = recipe["id"]
        item = {
            "id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant",
            "status": "completed",
            "content": [{"type": "output_text", "text": "Fixture complete.", "annotations": []}],
        }
        with lock:
            for entry in payload.get("input", []):
                phase_id = calls.get(entry.get("call_id"))
                if entry.get("type") == "function_call_output" and phase_id is not None:
                    target = root / ("result-" + phase_id + ".json")
                    temporary = target.with_suffix(".tmp")
                    temporary.write_text(json.dumps(entry), encoding="utf-8")
                    temporary.replace(target)
            if recipe.get("command") and phase not in consumed:
                names = [tool.get("name", tool.get("function", {}).get("name")) for tool in payload.get("tools", [])]
                if "exec_command" not in names:
                    self.send_error(400, "Native exec_command unavailable")
                    return
                consumed.add(phase)
                item = {
                    "id": "fc_" + uuid.uuid4().hex, "type": "function_call", "name": "exec_command",
                    "call_id": "call_" + uuid.uuid4().hex,
                    "arguments": json.dumps({
                        "cmd": recipe["command"], "shell": "/bin/sh", "login": False,
                        "yield_time_ms": 10000, "max_output_tokens": 1000,
                    }),
                }
                calls[item["call_id"]] = phase
            (root / ("started-" + phase)).touch()
        if item["type"] == "message" and recipe.get("hold_after_command"):
            # Keep the turn unfinished after the native command has returned its result.
            finish.wait()
            return
        response = {
            "id": "resp_" + uuid.uuid4().hex, "object": "response", "created_at": int(time.time()),
            "model": "acceptance-fixture", "status": "completed", "output": [item],
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
        }
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.event("response.created", {"response": dict(response, status="in_progress", output=[])})
            self.event("response.output_item.added", {"output_index": 0, "item": item})
            if item["type"] == "message":
                self.event("response.output_text.delta", {
                    "item_id": item["id"], "output_index": 0, "content_index": 0, "delta": "Fixture complete.",
                })
            self.event("response.output_item.done", {"output_index": 0, "item": item})
            self.event("response.completed", {"response": response})
        except (BrokenPipeError, ConnectionResetError):
            pass

    def event(self, kind, fields):
        data = json.dumps(dict(fields, type=kind)).encode()
        self.wfile.write(b"event: " + kind.encode() + b"\ndata: " + data + b"\n\n")
        self.wfile.flush()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
worker = threading.Thread(target=server.serve_forever, daemon=True)
worker.start()
print(json.dumps({"port": server.server_port}), flush=True)
try:
    for _ in sys.stdin:
        pass
finally:
    finish.set()
    server.shutdown()
    server.server_close()
    worker.join(timeout=2)
