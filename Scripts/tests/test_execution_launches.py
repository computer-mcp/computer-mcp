import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "execution_launches", Path(__file__).resolve().parents[1] / "verify-execution-launches.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ExecutionLaunchGateTests(unittest.TestCase):
    def test_only_launcher_implementation_can_launch(self):
        launches = ["Process()", "Foundation.Process.init()", "Process.run(executableURL: url)",
                    "posix_spawn(&pid)", "posix_spawnp(&pid)", "Subprocess.\nrun(command)",
                    "import Subprocess\ntry await run(command)"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            caller = root / "Sources/Service/Launch.swift"
            caller.parent.mkdir(parents=True)
            for launch in launches:
                caller.write_text(launch)
                self.assertTrue(list(gate.violations(root)), launch)
            caller.write_text("try await launcher.start(command)")
            for name in gate.IMPLEMENTATION:
                implementation = root / name
                implementation.parent.mkdir(parents=True, exist_ok=True)
                implementation.write_text("\n".join(launches))
            self.assertEqual(list(gate.violations(root)), [])
