"""Real isolated Gateway host crash, process-group cleanup, and write recovery."""

import json
import errno
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


def wait_for(predicate, description, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("Timed out: " + description)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def append(path, value):
    with path.open("a") as stream:
        stream.write(json.dumps(value) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def records(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def server(root):
    try:
        os.fstat(9)
    except OSError as error:
        assert error.errno == errno.EBADF
    else:
        raise AssertionError("Host ownership descriptor leaked into the native MCP command")
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    worker = subprocess.Popen([sys.executable, __file__, "worker", str(root)])
    wait_for(lambda: (root / "worker-ready").exists(), "worker signal handler")
    append(root / "starts", {
        "server": os.getpid(), "supervisor": os.getppid(),
        "worker": worker.pid, "group": os.getpgrp(),
    })
    def startup_checkpoint(stage):
        selection = root / "startup-stage"
        if (selection.exists() and selection.read_text() == stage
                and len(records(root / "starts")) == 1):
            append(root / "checkpoint", {"stage": stage, "pid": os.getpid()})
            while True:
                time.sleep(1)

    startup_checkpoint("process-entry")
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request["method"]
        if method == "initialize":
            startup_checkpoint("initialize")
            result = {"protocolVersion": request["params"]["protocolVersion"],
                      "capabilities": {"tools": {}},
                      "serverInfo": {"name": "host-crash-fixture", "version": "1"}}
        elif method == "tools/list":
            startup_checkpoint("catalog")
            result = {"tools": [{"name": name, "inputSchema": {"type": "object"}}
                                for name in ("inspect", "write")]}
        elif method == "tools/call":
            if request["params"]["name"] == "write":
                append(root / "writes", {"request": request["id"], "pid": os.getpid()})
                # The side effect is durable, but no result reaches the host.
                continue
            result = {"content": [{"type": "text", "text": "observed"}]}
        else:
            raise AssertionError("Unexpected native method: " + method)
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    while True:
        time.sleep(1)


class Client:
    def __init__(self, root, executable, manifest, generation):
        self.error = (root / ("host-%d.stderr" % generation)).open("wb")
        self.process = subprocess.Popen(
            [executable, "serve", "stdio", "--config", manifest,
             "--database", str(root / "gateway.sqlite"), "--workspace-id", "fixture"],
            cwd=root, env={**os.environ, "TMPDIR": str(root)},
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.error,
            start_new_session=True)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.next_id = 0

    def send(self, method, params):
        self.next_id += 1
        self.process.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.next_id,
                                            "method": method, "params": params}) + "\n").encode())
        self.process.stdin.flush()
        return self.next_id

    def call(self, method, params):
        request_id = self.send(method, params)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                reply = json.loads(line)
                if reply.get("id") == request_id:
                    assert "error" not in reply, reply
                    return reply["result"]
            if self.selector.select(max(0, deadline - time.monotonic())):
                chunk = os.read(self.process.stdout.fileno(), 65536)
                assert chunk, "Host exited: " + Path(self.error.name).read_text()
                self.buffer += chunk
        raise AssertionError("No host reply: " + method)

    def initialize(self):
        self.call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                 "clientInfo": {"name": "crash-test", "version": "1"}})
        self.process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.process.stdin.flush()
        catalog = self.call("tools/list", {})
        assert {"owned.inspect", "owned.write"}.issubset({t["name"] for t in catalog["tools"]})

    def require_pending(self, request_id):
        if self.selector.select(0):
            chunk = os.read(self.process.stdout.fileno(), 65536)
            assert chunk, "Host exited before the native write"
            self.buffer += chunk
        while b"\n" in self.buffer:
            line, self.buffer = self.buffer.split(b"\n", 1)
            reply = json.loads(line)
            assert reply.get("id") != request_id, reply

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)
        self.selector.close()
        self.process.stdin.close()
        self.process.stdout.close()
        self.error.close()


def exited(entry):
    return all(not alive(entry[key]) for key in ("server", "supervisor", "worker", "watchdog")
               if key in entry)


def with_watchdog(entry):
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid="], text=True)
    children = [int(pid) for pid, parent in (line.split() for line in rows.splitlines())
                if int(parent) == entry["supervisor"] and int(pid) != entry["server"]]
    assert len(children) == 1, {"native": entry, "supervisor_children": children}
    return {**entry, "watchdog": children[0]}


def driver(root, executable, manifest, pause_cleanup=False):
    clients = []
    watched = []
    paused = None
    try:
        first = Client(root, executable, manifest, 1)
        clients.append(first)
        first.initialize()
        wait_for(lambda: len(records(root / "starts")) == 1, "first native process receipt")
        old = with_watchdog(records(root / "starts")[0])
        watched.append(old)
        assert old["group"] == old["server"]
        assert all(alive(old[key]) for key in ("server", "supervisor", "worker", "watchdog"))
        arguments = {"workspace_id": "fixture"}
        prepared = first.call("tools/call", {"name": "operations.prepare", "arguments": {
            "tool": "owned.write", "arguments": arguments}})
        assert not prepared.get("isError", False), prepared
        assert prepared["structuredContent"]["result"]["state"] == "prepared", prepared
        ticket = prepared["structuredContent"]["result"]["ticket_id"]
        commit = {"name": "operations.commit", "arguments": {
            "ticket_id": ticket, "tool": "owned.write", "arguments": arguments}}
        request_id = first.send("tools/call", commit)

        def write_started():
            first.require_pending(request_id)
            return len(records(root / "writes")) == 1

        wait_for(write_started, "unacknowledged native write")
        if pause_cleanup:
            parent = int(subprocess.check_output(
                ["/bin/ps", "-p", str(old["supervisor"]), "-o", "ppid="], text=True).strip())
            assert parent == first.process.pid, (parent, first.process.pid)
            os.kill(old["watchdog"], signal.SIGSTOP)
            paused = old["watchdog"]
            wait_for(lambda: "T" in subprocess.check_output(
                ["/bin/ps", "-p", str(paused), "-o", "stat="], text=True), "owned watchdog paused")
        first.process.kill()
        assert first.process.wait(timeout=5) == -signal.SIGKILL
        if pause_cleanup:
            blocked = Client(root, executable, manifest, 2)
            clients.append(blocked)
            try:
                blocked.initialize()
            except AssertionError:
                assert "mcp.cleanup_pending" in Path(blocked.error.name).read_text()
            else:
                raise AssertionError("New host started while the orphan MCP process lock was held")
            assert len(records(root / "starts")) == 1
            assert alive(old["server"]) and alive(old["worker"])
            blocked.close()
            os.kill(paused, signal.SIGCONT)
            paused = None
        # No termination signal is sent to the native tree by this test before this assertion.
        wait_for(lambda: exited(old), "watchdog cleanup after abrupt host death")
        (root / "worker-ready").unlink()
        second = Client(root, executable, manifest, 3 if pause_cleanup else 2)
        clients.append(second)
        second.initialize()
        assert len(records(root / "starts")) == 2
        watched.append(with_watchdog(records(root / "starts")[1]))
        assert exited(old)
        observed = second.call("tools/call", {"name": "owned.inspect", "arguments": arguments})
        assert not observed.get("isError", False), observed
        rejected = second.call("tools/call", commit)
        assert rejected.get("isError", False), rejected
        assert rejected["structuredContent"]["error"]["code"] == "operations.ticket_expired_or_used", rejected
        assert len(records(root / "writes")) == 1, "Write replayed after restart"
        second.process.stdin.close()
        assert second.process.wait(timeout=10) == 0
        wait_for(lambda: all(exited(entry) for entry in watched), "normal host exit cleanup")
        print(json.dumps({"generations": 2, "writes": 1, "owned_processes_exited": True,
                          "consumed_ticket_rejected": True, "pending_cleanup_blocked": pause_cleanup}))
    finally:
        cleanup_fixture(root, clients, watched, paused)


def startup_driver(root, executable, manifest, stage, failure):
    clients, watched = [], []
    paused = None
    (root / "startup-stage").write_text(stage)
    try:
        first = Client(root, executable, manifest, 1)
        clients.append(first)
        request_id = first.send("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "startup-crash-test", "version": "1"}})
        wait_for(lambda: len(records(root / "checkpoint")) == 1, "native startup checkpoint")
        first.require_pending(request_id)
        old = with_watchdog(records(root / "starts")[0])
        watched.append(old)
        checkpoint = records(root / "checkpoint")[0]
        assert checkpoint == {"stage": stage, "pid": old["server"]}, checkpoint
        parent = int(subprocess.check_output(
            ["/bin/ps", "-p", str(old["supervisor"]), "-o", "ppid="], text=True).strip())
        assert parent == first.process.pid
        assert old["group"] == old["server"] == os.getpgid(old["worker"])
        if failure == "host":
            paused = old["watchdog"]
            os.kill(paused, signal.SIGSTOP)
            wait_for(lambda: "T" in subprocess.check_output(
                ["/bin/ps", "-p", str(paused), "-o", "stat="], text=True), "watchdog paused")
            first.process.kill()
            assert first.process.wait(timeout=5) == -signal.SIGKILL
            blocked = Client(root, executable, manifest, 2)
            clients.append(blocked)
            try:
                blocked.initialize()
            except AssertionError:
                assert "mcp.cleanup_pending" in Path(blocked.error.name).read_text()
            else:
                raise AssertionError("Startup admitted an orphaned process generation")
            assert len(records(root / "starts")) == 1
            assert alive(old["server"]) and alive(old["worker"])
            blocked.close()
            os.kill(paused, signal.SIGCONT)
            paused = None
        else:
            assert failure == "native"
            os.kill(old["server"], signal.SIGKILL)
            assert first.process.wait(timeout=10) != 0
        wait_for(lambda: exited(old), "startup crash cleans the owned process tree")
        (root / "worker-ready").unlink()
        second = Client(root, executable, manifest, 3)
        clients.append(second)
        second.initialize()
        assert len(records(root / "starts")) == 2
        watched.append(with_watchdog(records(root / "starts")[1]))
        observed = second.call("tools/call", {"name": "owned.inspect", "arguments": {
            "workspace_id": "fixture"}})
        assert not observed.get("isError", False), observed
        assert not records(root / "writes")
        second.process.stdin.close()
        assert second.process.wait(timeout=10) == 0
        wait_for(lambda: all(exited(entry) for entry in watched), "recovered host cleanup")
        remaining = [p for p in (root / "gateway.sqlite.mcp-processes").glob("*/*")
                     if p.name != "scope.lock"]
        assert remaining == [], remaining
        print(json.dumps({"stage": stage, "failure": failure, "generations": 2,
                          "writes": 0, "initial_catalog_published": False,
                          "owned_processes_exited": True, "receipts_remaining": 0}))
    except Exception:
        pids = {client.process.pid for client in clients}
        for entry in watched:
            pids.update(entry[key] for key in ("server", "supervisor", "worker", "watchdog")
                        if key in entry)
        if pids:
            state = subprocess.run(
                ["/bin/ps", "-p", ",".join(str(pid) for pid in sorted(pids)),
                 "-o", "pid,ppid,pgid,stat,etime,comm"],
                capture_output=True, text=True, timeout=5)
            print("Startup failure process state:\n" + state.stdout + state.stderr, file=sys.stderr)
        for client in clients:
            print("Host stderr:\n" + Path(client.error.name).read_text(), file=sys.stderr)
        raise
    finally:
        cleanup_fixture(root, clients, watched, paused)


def cleanup_fixture(root, clients, watched, paused):
    if paused is not None and alive(paused):
        os.kill(paused, signal.SIGCONT)
    for client in clients:
        client.close()
    # Failure cleanup only targets process groups receipted by this fixture.
    for entry in records(root / "starts"):
        if entry["group"] == entry["server"]:
            try:
                if any(alive(entry[key]) and os.getpgid(entry[key]) == entry["group"]
                       for key in ("server", "worker")):
                    os.killpg(entry["group"], signal.SIGKILL)
            except ProcessLookupError:
                pass
    wait_for(lambda: all(exited(entry) for entry in records(root / "starts")), "fixture teardown")
    wait_for(lambda: all(exited(entry) for entry in watched), "watchdog teardown")


if __name__ == "__main__":
    mode, directory = sys.argv[1:3]
    root = Path(directory)
    if mode == "worker":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        (root / "worker-ready").write_text("ready")
        while True:
            time.sleep(1)
    elif mode == "server":
        server(root)
    elif mode == "driver":
        driver(root, *sys.argv[3:])
    elif mode == "driver-pending":
        driver(root, *sys.argv[3:], pause_cleanup=True)
    elif mode == "driver-startup":
        startup_driver(root, *sys.argv[3:])
    else:
        raise AssertionError("Unknown fixture mode")
