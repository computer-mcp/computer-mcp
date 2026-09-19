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
vendor_path = Path(vendor)
wrapper = root / "configured-codex"
wrapper.write_text(f'''#!/usr/bin/python3
import json, os, sys
keys = ("COMPUTER_MCP_HOST_CONTEXT", "COMPUTER_MCP_HOST_FD", "CODEX_THREAD_ID")
assert not any(key in os.environ for key in keys), "Parent session authority leaked"
assert os.environ.get("COMPUTER_MCP_FIXTURE_VALUE") == "preserved", "Ordinary environment was lost"
with open({str(root / "launches.jsonl")!r}, "a") as receipt:
    receipt.write(json.dumps({{"mode": sys.argv[1], "cwd": os.getcwd(), "argv": sys.argv[1:]}}) + "\\n")
os.execv({str(vendor_path)!r}, [{str(vendor_path)!r}] + sys.argv[1:])
''')
wrapper.chmod(0o700)
for name in ("primary", "other"):
    (root / name).mkdir()
    subprocess.run(["/usr/bin/git", "init", "--quiet", str(root / name)], check=True,
                   env={**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"})
(root / "response.json").write_text(json.dumps({"id": "text"}))
(root / "network-token").write_text("unused-isolated-probe")
host = None
model = None
results = []
pids = set()
try:
    model = subprocess.Popen(["/usr/bin/python3", model_source, str(root)],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=(root / "model.log").open("w"), text=True)
    ready = queue.Queue()
    threading.Thread(target=lambda: ready.put(model.stdout.readline(65536)), daemon=True).start()
    port = json.loads(ready.get(timeout=5))["port"]
    (home / "config.toml").write_text(f'''model = "acceptance-fixture"
    model_provider = "fixture"
    cli_auth_credentials_store = "file"
    approval_policy = "on-request"
    sandbox_mode = "danger-full-access"
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
        "enabled": True, "executable": wrapper.name, "app_server_enabled": True,
        "exec_enabled": True, "app_server_request_timeout_seconds": 30,
    }))
    risks = {"thread.start": "workspace-write", "turn.start": "workspace-write",
             "thread.release": "workspace-write", "status": "read-only",
             "events.read": "read-only", "goal.set": "workspace-write", "goal.get": "read-only"}
    names = ["codex.app." + n for n in risks]
    extra_risks = {"codex.exec.start": "workspace-write", "codex.exec.result": "read-only",
                   "codex.exec.list": "read-only"}
    names.extend(extra_risks)
    q = json.dumps
    policy = ", ".join(q(n) + " = " + q(r) for n, r in
                       ({"codex.app." + n: r for n, r in risks.items()} | extra_risks).items())
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
    mode = "workspace-operations"
    confirmation_policy = "risk-based"
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
    PATH = {q(str(root) + os.pathsep + os.environ.get("PATH", ""))}
    CODEX_THREAD_ID = "fixture-parent-session"
    COMPUTER_MCP_FIXTURE_VALUE = "preserved"
    ''')
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
    seen_cursors = set()
    while True:
        page = send("tools/list", {"cursor": cursor} if cursor else {})
        catalog.update({t["name"]: t for t in page["tools"]})
        cursor = page.get("nextCursor")
        if not cursor:
            break
        assert cursor not in seen_cursors, "Cyclic tool catalog"
        seen_cursors.add(cursor)
    assert catalog["mcp.tools.call"]["inputSchema"]["properties"]["workspace_id"]["type"] == "string"
    def call(name, arguments=None):
        full = name if name.startswith("codex.") else "codex.app." + name
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
    start = call("thread.start")
    assert start["sandbox"]["type"] == "dangerFullAccess", start
    thread = start["thread"]["id"]
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
    for native_options in (None, {"sandbox": "workspace-write", "approval_policy": "never"}):
        arguments = {"prompt": "Return the isolated fixture response."}
        if native_options is not None:
            arguments["options"] = native_options
        started = call("codex.exec.start", arguments)
        deadline = time.monotonic() + 45
        while True:
            sessions = call("codex.exec.list")["sessions"]
            current = next(s for s in sessions if s["session_id"] == started["session_id"])
            if current["state"] in ("completed", "failed", "cancelled"):
                result = call("codex.exec.result", {"session_id": started["session_id"]})
                assert result["state"] == "completed", result
                assert "Fixture complete." in json.dumps(result), result
                break
            assert time.monotonic() < deadline, current
            time.sleep(0.05)
    launches = [json.loads(line) for line in (root / "launches.jsonl").read_text().splitlines()]
    expected_modes = {"app-server", "exec"}
    assert {entry["mode"] for entry in launches} == expected_modes, launches
    assert all(Path(entry["cwd"]).resolve() == (root / "primary").resolve() for entry in launches)
    exec_launches = [entry for entry in launches if entry["mode"] == "exec"]
    assert len(exec_launches) == 2, exec_launches
    inherited, explicit = (entry["argv"] for entry in exec_launches)
    assert all("--ignore-user-config" not in entry["argv"] for entry in exec_launches)
    assert "--sandbox" not in inherited and not any("approval_policy=" in arg for arg in inherited), inherited
    assert "workspace-write" in explicit and 'approval_policy="never"' in explicit, explicit
    print(json.dumps({"flow_passed": True,
                      "completed_providers": ["app-server", "exec"],
                      "native_permissions": ["inherited-full-access", "explicit-exec-override"],
                      "thread": thread, "turn": turn, "evidence": str(root)}), flush=True)
finally:
    (root / "protocol-results.json").write_text(json.dumps(results, indent=2))
    cleanup_errors = []
    for process in (host, model):
        if process is not None:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        cleanup_errors.append(process.pid)
    print(json.dumps({"host_exit": host.returncode if host else None,
                      "model_exit": model.returncode if model else None, "cleanup_unconfirmed": cleanup_errors,
                      "evidence": str(root)}), flush=True)
    if cleanup_errors:
        raise RuntimeError(f"Owned process cleanup unconfirmed: {cleanup_errors}")
for pid in pids:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        continue
    raise RuntimeError(f"Owned process {pid} still present; evidence retained at {root}")
assert host.returncode == 0 and model.returncode == 0
print("INSTALLED_GENERIC_FLOW_AND_CLEANUP_OK", flush=True)
