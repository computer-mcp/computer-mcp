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
                    "let child: Process = .init()\ntry child.run()",
                    "Process.launchedProcess(launchPath: path, arguments: [])",
                    "[NSTask launchedTaskWithLaunchPath:path arguments:@[]];",
                    "posix_spawn(&pid)", "posix_spawnp(&pid)", "pid_t child = fork();",
                    "Subprocess.\nrun(command)", "import Subprocess\ntry await run(command)",
                    'let pid = "\\(fork())"', 'let a = "/*"; Process(); let b = "*/"',
                    'let m = """\nexited \\(Process())\n"""', 'let r = #"raw \\#(Process())"#',
                    'let n = "a \\("b \\(Process())") c"', 'let s = #"a \\#"# text"#; fork()']
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            caller = root / "Sources/Service/Launch.swift"
            caller.parent.mkdir(parents=True)
            for launch in launches:
                caller.write_text(launch)
                self.assertTrue(list(gate.violations(root)), launch)
            caller.write_text(
                "// Process trees end with the execution.\n"
                "/* outer /* nested */ Process() */\n"
                "let message = \"Process exited \\\" Process()\"\n"
                "let raw = #\"\\(Process())\"#\n"
                "let quoted = #\"a \\#\"# fork()\"#\n"
                "let info = ProcessInfo.processInfo\n"
                "try await launcher.start(command)")
            self.assertEqual(list(gate.violations(root)), [])
            for name in gate.IMPLEMENTATION:
                implementation = root / name
                implementation.parent.mkdir(parents=True, exist_ok=True)
                implementation.write_text("\n".join(launches))
            self.assertEqual(list(gate.violations(root)), [])

    def test_c_sources_skip_character_and_string_literals(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/CBridge/bridge.c"
            source.parent.mkdir(parents=True)
            source.write_text("char quote = '\"'; printf(\"fork()\");")
            self.assertEqual(list(gate.violations(root)), [])
            source.write_text("char quote = '\"'; pid_t child = fork();")
            self.assertTrue(list(gate.violations(root)))
