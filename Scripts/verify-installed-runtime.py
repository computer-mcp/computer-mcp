#!/usr/bin/env python3
"""Fixed MCP cases against an explicit installed CLI, with the source tree denied."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import tempfile
import threading
import time
import uuid


class Client:
    def __init__(self, command, cwd, log):
        self.process = subprocess.Popen(command, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=log, text=True, bufsize=1, start_new_session=True)
        self.inbox = queue.Queue()
        self.pending = {}
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        try:
            while True:
                line = self.process.stdout.readline(8 * 1024 * 1024 + 1)
                if not line:
                    break
                if len(line) > 8 * 1024 * 1024:
                    raise ValueError("MCP response exceeds the acceptance frame limit")
                self.inbox.put(json.loads(line))
        except (OSError, ValueError) as error:
            self.inbox.put(error)
        finally:
            self.inbox.put(EOFError("MCP transport closed"))

    def send(self, method, params=None, identifier=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if identifier is not None:
            message["id"] = identifier
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def receive(self, identifier):
        deadline = time.monotonic() + 10
        while identifier not in self.pending:
            if time.monotonic() >= deadline:
                raise TimeoutError("MCP request exceeded its deadline")
            response = self.inbox.get(timeout=max(0.01, deadline - time.monotonic()))
            if isinstance(response, Exception):
                raise response
            if "id" in response:
                if response["id"] in self.pending:
                    raise ValueError("Duplicate response identifier")
                self.pending[response["id"]] = response
        return self.pending.pop(identifier)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait()
            raise
        finally:
            self.reader.join(timeout=2)
            self.process.stdout.close()


def success(response):
    if "error" in response or response.get("result", {}).get("isError", False):
        raise ValueError("Expected successful fixed-case response: " + json.dumps(response))
    return response["result"]


def verify(cli, denied_source, output):
    cli = cli.resolve()
    denied_source = denied_source.resolve()
    if cli.is_relative_to(denied_source):
        raise ValueError("Use a packaged CLI outside the source tree")
    records = []
    with tempfile.TemporaryDirectory(prefix="computer-mcp-installed-acceptance-") as temporary:
        root = Path(temporary)
        workspace = root / "workspace"
        workspace.mkdir()
        nonce = uuid.uuid4().hex
        (workspace / "nonce.txt").write_text(nonce)
        configuration = root / "gateway.toml"
        configuration.write_text(f'''schema_version = 1
[runtime]
caller = "local-mcp"
profile = "acceptance"
[policy]
shell_enabled = false
default_timeout_ms = 2000
[[workspaces]]
id = "acceptance"
display_name = "Fixed release acceptance"
path = {json.dumps(str(workspace))}
[[profiles]]
id = "acceptance"
mode = "read-only"
confirmation_policy = "risk-based"
capabilities = ["system.info", "file.read", "workspace.list"]
workspaces = ["acceptance"]
allowed_callers = ["local-mcp"]
[builtin]
enabled = ["system.info", "file.read"]
''')
        sandbox = root / "isolation.sb"
        sandbox.write_text('(version 1)\n(allow default)\n(deny file-read* (subpath ' + json.dumps(str(denied_source)) + '))\n')
        # Prove the isolation rule is effective, not only present in configuration.
        denied = subprocess.run(["/usr/bin/sandbox-exec", "-f", str(sandbox), "/bin/cat", str(denied_source / "Package.swift")],
                                capture_output=True, timeout=5)
        if denied.returncode == 0:
            raise ValueError("The source-denial sandbox did not deny the source tree")
        for cycle in range(3):
            log_path = output.with_name(output.stem + f"-cycle-{cycle}.log")
            with log_path.open("w") as log:
                client = Client(["/usr/bin/sandbox-exec", "-f", str(sandbox), str(cli), "serve", "stdio",
                                 "--config", str(configuration), "--database", str(root / "runtime.sqlite")], root, log)
                started = time.monotonic()
                try:
                    initialize = {"protocolVersion": "2025-11-25", "capabilities": {},
                                  "clientInfo": {"name": "fixed-release-acceptance", "version": "1"}}
                    client.send("initialize", initialize, 0)
                    handshake = success(client.receive(0))
                    if "protocolVersion" not in handshake:
                        raise ValueError("Initialization did not return protocol identity")
                    client.send("notifications/initialized")
                    client.send("tools/call", {"name": "system.info", "arguments": {}}, 0)
                    client.send("tools/call", {"name": "file.read", "arguments": {
                        "workspace_id": "acceptance", "path": "nonce.txt", "max_bytes": 256}}, 1)
                    client.send("initialize", initialize, 2)
                    system = success(client.receive(0))
                    file = success(client.receive(1))
                    repeated = success(client.receive(2))
                    if nonce not in json.dumps(file) or repeated.get("protocolVersion") != handshake["protocolVersion"]:
                        raise ValueError("Concurrent request results or repeated initialization were mismatched")
                    if "protocolVersion" in system:
                        raise ValueError("Tool response was replaced by an initialization response")
                    client.send("notifications/cancelled", {"requestId": "completed-or-unknown"})
                    client.send("ping", {}, 3)
                    success(client.receive(3))
                    client.send("tools/call", {"name": "file.read", "arguments": {
                        "workspace_id": "acceptance", "path": "../outside.txt"}}, 4)
                    denied_read = client.receive(4)
                    if "error" not in denied_read and not denied_read.get("result", {}).get("isError"):
                        raise ValueError("Workspace boundary was not enforced")
                    records.append({"cycle": cycle, "concurrent_ids": [0, 1, 2], "initialization": "passed",
                                    "workspace_read": "passed", "boundary_denial": "passed", "ping_after_cancel": "passed",
                                    "duration_seconds": round(time.monotonic() - started, 3)})
                finally:
                    client.close()
                if client.process.returncode != 0:
                    raise ValueError("Installed gateway did not shut down cleanly")
        output.write_text(json.dumps({"status": "passed", "cli_sha256": hashlib.sha256(cli.read_bytes()).hexdigest(),
                                      "source_and_build_unavailable": True, "cycles": records}, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--deny-source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    options = parser.parse_args()
    verify(options.cli, options.deny_source, options.output)
