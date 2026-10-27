"""Probe standalone native admission without owner-issued execution authority."""

import json
from pathlib import Path
import subprocess
import sys
import selectors
import time


def server(root):
    (root / "native-started").write_text("started")
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request["method"]
        if method == "initialize":
            result = {"protocolVersion": request["params"]["protocolVersion"],
                      "capabilities": {"tools": {}}, "serverInfo": {"name": "admission", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "write", "inputSchema": {"type": "object"}}]}
        elif method == "tools/call":
            (root / "write-dispatched").write_text("dispatched")
            result = {"content": []}
        else:
            raise AssertionError("Unexpected native method: " + method)
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


def driver(root, executable, manifest):
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "admission-probe", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
            "name": "owned.write", "arguments": {"project_id": "fixture"}}},
    ]
    process = subprocess.Popen(
        [executable, "serve", "stdio", "--config", manifest,
         "--database", str(root / "gateway.sqlite"), "--project-id", "fixture"],
        cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)

    def reply(request_id):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if not selector.select(max(0, deadline - time.monotonic())):
                break
            line = process.stdout.readline()
            if not line:
                break
            value = json.loads(line)
            if value.get("id") == request_id:
                return value
        raise AssertionError("Missing standalone reply " + str(request_id))

    try:
        process.stdin.write(json.dumps(requests[0]) + "\n")
        process.stdin.flush()
        assert "result" in reply(1)
        process.stdin.write("".join(json.dumps(item) + "\n" for item in requests[1:]))
        process.stdin.flush()
        write = reply(2)
    finally:
        selector.close()
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    assert not (root / "native-started").exists(), process.stderr.read()
    assert not (root / "write-dispatched").exists()
    assert "error" in write or write.get("result", {}).get("isError") is True, write
    print(json.dumps({"native_started": False, "write_refused": True}))


if __name__ == "__main__":
    mode, directory = sys.argv[1:3]
    root = Path(directory)
    if mode == "server":
        server(root)
    elif mode == "driver":
        driver(root, *sys.argv[3:])
    else:
        raise AssertionError("Unknown fixture mode")
