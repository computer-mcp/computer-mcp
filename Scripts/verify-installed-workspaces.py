#!/usr/bin/env python3
"""Exercise the installed App's workspace control plane using one owned directory."""
import argparse
import json
from pathlib import Path
import subprocess

from release import atomic_json, digest


def verify(cli, work):
    def call(*arguments):
        response = json.loads(subprocess.check_output([str(cli), "workspace", *arguments], timeout=20))
        if "error" in response:
            raise ValueError("Workspace operation failed")
        return response.get("result", response)

    fixture = work / "workspace-fixture"
    fixture.mkdir(mode=0o700, parents=True, exist_ok=False)
    fixture = fixture.resolve()
    original = call("list")
    original_by_id = {row["id"]: row for row in original}
    if any(Path(row["root_path"]).resolve() == fixture for row in original):
        raise ValueError("Acceptance directory is already registered")
    identifier = None
    try:
        call("add", str(fixture), "--display-name", "Release acceptance fixture")
        added = [row for row in call("list") if Path(row["root_path"]).resolve() == fixture]
        if len(added) != 1 or added[0]["access"]["status"] != "available":
            raise ValueError("Added workspace is not uniquely available")
        identifier = added[0]["id"]
        atomic_json(work / "workspace-operation.json", {"owned_workspace": identifier, "path": str(fixture)})
        call("add", str(fixture), "--display-name", "Release acceptance fixture")
        repeated = [row for row in call("list") if Path(row["root_path"]).resolve() == fixture]
        if len(repeated) != 1 or repeated[0]["id"] != identifier:
            raise ValueError("Adding the same workspace duplicated its identity")
    finally:
        # A lost add response is resolved by this run's exact owned path before cleanup.
        for row in call("list"):
            if Path(row["root_path"]).resolve() == fixture and row["id"] not in original_by_id:
                call("remove", row["id"])
    final = call("list")
    if any(Path(row["root_path"]).resolve() == fixture for row in final):
        raise ValueError("Acceptance workspace was not removed")
    final_by_id = {row["id"]: row for row in final}
    if any(final_by_id.get(key) != value for key, value in original_by_id.items()):
        raise ValueError("An existing workspace changed during acceptance; inspect concurrent activity")
    fixture.rmdir()
    atomic_json(work / "workspace-operations.json", {
        "status": "passed", "workspace_id": identifier,
        "checks": ["add", "available", "duplicate-add-preserves-identity", "remove", "existing-workspaces-preserved"],
        "original_workspaces_sha256": digest(original),
    })


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    options = parser.parse_args()
    verify(options.cli.resolve(), options.work.resolve())
