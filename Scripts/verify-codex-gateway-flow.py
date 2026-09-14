"""Verify an explicitly selected Gateway executable with isolated native Codex state."""

import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("cli")
parser.add_argument("adapter")
parser.add_argument("vendor")
parser.add_argument("model_source")
options = parser.parse_args()
cli, adapter, vendor, model_source = (options.cli, options.adapter, options.vendor, options.model_source)
for executable in (cli, adapter, vendor):
    if not os.path.isabs(executable) or not os.access(executable, os.X_OK):
        parser.error("Executable paths must be absolute and executable")
root = Path(tempfile.mkdtemp(prefix="computer-mcp-installed-flow-"))
home = root / "codex-home"
home.mkdir()
for name in ("primary", "other"):
    (root / name).mkdir()
(root / "response.json").write_text(json.dumps({"id": "text"}))
(root / "network-token").write_text("unused-isolated-probe")
model = subprocess.Popen(["/usr/bin/python3", model_source, str(root)],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=(root / "model.log").open("w"), text=True)
port = json.loads(model.stdout.readline())["port"]
(home / "config.toml").write_text(f'''model = "acceptance-fixture"
model_provider = "fixture"
cli_auth_credentials_store = "file"
approval_policy = "never"
sandbox_mode = "workspace-write"
web_search = "disabled"
[model_providers.fixture]
name = "Isolated installed acceptance"
base_url = "http://127.0.0.1:{port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
[analytics]
enabled = false
[otel]
metrics_exporter = "none"
''')
(root / "adapter.json").write_text(json.dumps({
    "enabled": True, "executable": vendor, "app_server_enabled": True,
    "exec_enabled": False, "mcp_enabled": False, "sandbox": "workspace-write",
    "approval_policy": "never", "app_server_request_timeout_seconds": 30,
}))
risks = {"thread.start": "workspace-write", "turn.start": "workspace-write",
         "thread.release": "workspace-write", "status": "read-only",
         "events.read": "read-only", "goal.set": "workspace-write", "goal.get": "read-only"}
names = ["codex.app." + n for n in risks]
q = json.dumps
policy = ", ".join(q("codex.app." + n) + " = " + q(r) for n, r in risks.items())
(root / "gateway.toml").write_text(f'''schema_version = 1
[runtime]
caller = "local-mcp"
profile = "chatgpt-operate"
[[workspaces]]
id = "primary"
display_name = "Installed acceptance"
path = {q(str(root / "primary"))}
[[workspaces]]
id = "other"
display_name = "Unselected acceptance"
path = {q(str(root / "other"))}
[[profiles]]
id = "chatgpt-operate"
capabilities = ["mcp.tools.call", "workspace.list"]
workspaces = ["primary"]
allowed_callers = ["local-mcp"]
[[mcp.servers]]
id = "native-codex"
transport = "stdio"
command = {q(adapter)}
args = ["--config", {q(str(root / "adapter.json"))}, "--state-directory", {q(str(root / "adapter-state"))}]
exposure = "reexport"
prefix = ""
allowed_tools = {q(names)}
host_services = true
tool_risks = {{ {policy} }}
startup_timeout_ms = 10000
request_timeout_ms = 45000
[mcp.servers.env]
CODEX_HOME = {q(str(home))}
''')
host = None
results = []
pids = set()
try:
    host = subprocess.Popen([cli, "serve", "stdio", "--config", str(root / "gateway.toml"),
                             "--database", str(root / "host.sqlite")],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=(root / "gateway.log").open("w"), text=True, bufsize=1)
    inbox = queue.Queue()
    def read_responses():
        for line in host.stdout:
            try:
                inbox.put(json.loads(line))
            except ValueError:
                inbox.put({"invalid_line": line})
        inbox.put({"eof": True})
    threading.Thread(target=read_responses, daemon=True).start()
    request_id = 0
    def send(method, params=None, notification=False):
        global request_id
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notification:
            request_id += 1
            message["id"] = request_id
        host.stdin.write(json.dumps(message) + "\n")
        host.stdin.flush()
        if notification:
            return
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            response = inbox.get(timeout=max(0.01, deadline - time.monotonic()))
            if response.get("id") == request_id:
                results.append({"request": message, "response": response})
                assert "error" not in response, response
                return response["result"]
            assert not response.get("eof") and "invalid_line" not in response, response
        raise TimeoutError("Unknown result; writes must not be replayed")
    send("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                        "clientInfo": {"name": "installed-flow-acceptance", "version": "1"}})
    send("notifications/initialized", notification=True)
    catalog = {}
    cursor = None
    while True:
        page = send("tools/list", {"cursor": cursor} if cursor else {})
        catalog.update({t["name"]: t for t in page["tools"]})
        cursor = page.get("nextCursor")
        if not cursor:
            break
    assert catalog["mcp.tools.call"]["inputSchema"]["properties"]["workspace_id"]["type"] == "string"
    def call(name, arguments=None):
        full = "codex.app." + name
        arguments = arguments or {}
        assert set(arguments) <= set(catalog[full]["inputSchema"]["properties"])
        outer = {"server": "native-codex", "tool": full,
                 "workspace_id": "primary", "arguments": arguments}
        assert set(outer) <= set(catalog["mcp.tools.call"]["inputSchema"]["properties"])
        result = send("tools/call", {"name": "mcp.tools.call", "arguments": outer})
        assert not result.get("isError"), result
        result = result["structuredContent"]["result"]
        assert not result.get("isError"), result
        return result["structuredContent"]["result"]
    thread = call("thread.start")["thread"]["id"]
    objective = "Preserve installed acceptance Goal"
    call("goal.set", {"thread_id": thread, "objective": objective, "status": "paused"})
    turn = call("turn.start", {"thread_id": thread, "prompt": "Return the isolated fixture response."})["turn"]["id"]
    cursor = 0
    complete = False
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and not complete:
        page = call("events.read", {"after_cursor": cursor})
        assert page["missed_events"] == 0
        cursor = page["next_cursor"]
        for event in page["events"]:
            payload = event.get("payload", {})
            state = payload.get("params", {}).get("turn", {})
            if payload.get("method") == "turn/completed" and state.get("id") == turn:
                assert state["status"] == "completed", state
                complete = True
        if not complete:
            time.sleep(0.1)
    assert complete
    assert call("goal.get", {"thread_id": thread})["goal"]["objective"] == objective
    process = call("status")["process"]
    pids.update(process[k] for k in ("process_id", "supervisor_process_id", "parent_process_id"))
    released = call("thread.release", {"thread_id": thread})
    assert released["externally_claimable"] and not released["computer_mcp_writer_ownership_remaining"]
    assert released["goal_preservation"] == "persisted-and-unchanged"
    print(json.dumps({"flow_passed": True, "thread": thread, "turn": turn, "evidence": str(root)}), flush=True)
finally:
    (root / "protocol-results.json").write_text(json.dumps(results, indent=2))
    for process in (host, model):
        if process is not None:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=10)
    print(json.dumps({"host_exit": host.returncode if host else None,
                      "model_exit": model.returncode, "evidence": str(root)}), flush=True)
for pid in pids:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        continue
    raise RuntimeError(f"Owned process {pid} still present; evidence retained at {root}")
assert host.returncode == 0 and model.returncode == 0
print("INSTALLED_GENERIC_FLOW_AND_CLEANUP_OK", flush=True)
