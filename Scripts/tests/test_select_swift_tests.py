import contextlib
import importlib.util
import io
import json
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("select_swift_tests", SCRIPTS / "select-swift-tests.py")
selector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(selector)


def target(name, kind="test", dependencies=(), path=None):
    return {"name": name, "type": kind, "dependencies": list(dependencies), "path": path}


class TestSelection(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.enterContext(patch.object(selector, "ROOT", self.root))
        self.enterContext(patch.object(selector.sys, "platform", "linux"))
        self.enterContext(patch.object(selector, "SWIFT", "swift"))
        self.git("init", "-q")
        self.targets = [target("AlphaTests"), target("BetaTests")]
        self.inventory = ["AlphaTests.Example/run()", "AlphaTests.Sibling/testExample", "BetaTests.Other/run()"]
        capture = selector.capture

        def capture_with_swift(*command):
            if command == ("swift", "package", "dump-package"):
                return json.dumps({"targets": self.targets})
            if command == ("swift", "test", "list"):
                return "\n".join(self.inventory)
            return capture(*command)

        self.enterContext(patch.object(selector, "capture", side_effect=capture_with_swift))

    def git(self, *args):
        return subprocess.run(
            ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", *args],
            cwd=self.root, check=True, capture_output=True, text=True,
        ).stdout.strip()

    def write(self, path, content):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "Fixture change")
        return self.git("rev-parse", "HEAD")

    def selected(self, base):
        _, command = selector.selected_plan(base)
        self.assertEqual(command[:-1], ["swift", "test", "--no-parallel", "--skip-build", "--filter"])
        return {test for test in self.inventory if re.search(command[-1], test)}

    def list_plan(self, *arguments):
        with (
            patch.object(selector.sys, "argv", ["selector", *arguments, "--list-only"]),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            self.assertEqual(selector.main(), 0)
        return output.getvalue()

    def test_committed_diff_selects_discovered_suites_even_when_filenames_differ(self):
        file = "Tests/AlphaTests/Suite File.swift"
        self.write(file, "import Testing\n@Suite(.serialized)\nstruct Example { @Test func run() {} }\n")
        base = self.commit()
        with (self.root / file).open("a") as source:
            source.write('struct Secondary { @Test func run() { print("}") } }\n')
        self.commit()
        self.write("Tests/BetaTests/Other.swift", "struct Other {}\n")
        self.inventory += ["AlphaTests.Secondary.Nested/run()", "AlphaTests.ExampleExtra/run()"]
        self.assertEqual(self.selected(base), {"AlphaTests.Example/run()", "AlphaTests.Secondary.Nested/run()"})

    def test_helper_extension_resource_deleted_file_and_unknown_suite_use_module(self):
        cases = [
            ("Example.swift", "struct Example {}\nfunc sharedHelper() {}\n"),
            ("Example.swift", "struct Example {}\nextension Sibling {}\n"),
            ("Example.swift", "struct Example {}\nstruct Undiscovered {}\n"),
            ("Example.swift", None),
            ("Fixtures/input.json", "{}\n"),
            ("Fixtures/input.swift", "struct Example {}\n"),
        ]
        self.targets[0]["resources"] = [{"path": "Fixtures"}]
        self.write("Tests/AlphaTests/Example.swift", "struct Example {}\n")
        original = self.commit()
        for name, content in cases:
            with self.subTest(name=name, content=content):
                self.git("reset", "--hard", original)
                path = f"Tests/AlphaTests/{name}"
                if content is None:
                    (self.root / path).unlink()
                else:
                    self.write(path, content)
                self.commit()
                self.assertEqual(self.selected(original), set(self.inventory[:2]))

    def test_sibling_reference_to_suite_type_uses_module(self):
        self.write("Tests/AlphaTests/Example.swift", "struct Example { static func helper() {} }\n")
        self.write("Tests/AlphaTests/Sibling.swift", "struct Sibling { func testExample() { Example.helper() } }\n")
        base = self.commit()
        self.write("Tests/AlphaTests/Example.swift", "struct Example { static func helper() { print(1) } }\n")
        self.commit()
        self.assertEqual(self.selected(base), set(self.inventory[:2]))

    def test_rename_between_targets_selects_both_modules(self):
        self.write("Tests/AlphaTests/Example.swift", "struct Example { @Test func run() {} }\n")
        self.write("Tests/BetaTests/Other.swift", "struct Other { @Test func run() {} }\n")
        base = self.commit()
        (self.root / "Tests/AlphaTests/Example.swift").rename(self.root / "Tests/BetaTests/Renamed.swift")
        self.commit()
        self.inventory += ["BetaTests.Example/run()"]
        self.assertEqual(self.selected(base), set(self.inventory))

    def test_mixed_diff_unions_suites_and_transitive_runtime_and_declared_consumers(self):
        self.targets += [
            target("computer-mcp-execution-bootstrap", "executable", path="Sources/Bootstrap"),
            target("ComputerMCPPlatformPOSIX", "regular"),
            target("Adapter", "regular", [{"target": ["ComputerMCPPlatformPOSIX", None]}]),
            target("AdapterTests", dependencies=[{"byName": ["Adapter", None]}]),
        ]
        self.inventory += ["AdapterTests.Adapter/run()"]
        self.write("Sources/Bootstrap/main.swift", "print(0)\n")
        self.write("Tests/AlphaTests/Example.swift", "struct Example {}\n")
        base = self.commit()
        self.write("Sources/Bootstrap/main.swift", "print(1)\n")
        self.write("Tests/AlphaTests/Example.swift", "struct Example { @Test func run() {} }\n")
        self.commit()
        self.assertEqual(self.selected(base), {"AdapterTests.Adapter/run()", "AlphaTests.Example/run()"})

    def test_uncertain_baselines_and_paths_use_full_linux_plan(self):
        self.targets += [target("SharedSupport", "regular", path="Tests/SharedSupport"), target("Adapter", "regular")]
        self.write("Tests/AlphaTests/Example.swift", "struct Example {}\n")
        base = self.commit()
        self.assertIn("missing base", self.list_plan("--base"))
        self.assertIn("unavailable", self.list_plan("--base=--bad"))
        self.assertIn("unavailable", self.list_plan("--base", "f" * 40))
        self.assertIn("no changed paths", self.list_plan("--base", base))
        for path in (
            "Package.resolved",
            "Sources/Unknown/file.swift",
            "Sources/Adapter/runtime.toml",
            "Sources/Adapter/Consumerless.swift",
            "Tests/SharedSupport/fixture",
            "Tests/AlphaTests/link.swift",
        ):
            with self.subTest(path=path):
                self.git("reset", "--hard", base)
                if path.endswith("link.swift"):
                    (self.root / path).symlink_to("Example.swift")
                else:
                    self.write(path, "fixture\n")
                self.commit()
                self.assertIn("Command: swift test --no-parallel\n", self.list_plan("--base", base))

    def test_empty_bad_and_nonmatching_inventories_use_full(self):
        self.write("Tests/AlphaTests/Example.swift", "struct Example {}\n")
        base = self.commit()
        self.write("Tests/AlphaTests/Example.swift", "struct Example { @Test func run() {} }\n")
        self.commit()
        for inventory in ([], ["invalid"], ["BetaTests.Other/run()"]):
            with self.subTest(inventory=inventory):
                self.inventory = inventory
                self.assertIn("Full test suite", self.list_plan("--base", base))

    def test_macos_preserves_optimized_runner_when_its_test_is_selected(self):
        optimized = runpy.run_path(str(SCRIPTS / "run-swift-tests.py"))["OPTIMIZED_TEST"]
        module, suite = optimized.split("/")[0].split(".")
        self.targets += [target(module)]
        self.inventory += [optimized, f"{module}.Ordinary/run()"]
        self.write(f"Tests/{module}/{suite}.swift", f"struct {suite} {{}}\n")
        base = self.commit()
        with patch.object(selector.sys, "platform", "darwin"):
            self.write(f"Tests/{module}/Ordinary.swift", "struct Ordinary { @Test func run() {} }\n")
            self.commit()
            self.assertEqual(self.selected(base), {f"{module}.Ordinary/run()"})
            self.write(f"Tests/{module}/{suite}.swift", f"struct {suite} {{ @Test func changed() {{}} }}\n")
            self.commit()
            plan = self.list_plan("--base", base)
            self.assertIn("optimized test", plan)
            self.assertIn("Scripts/run-swift-tests.py", plan)


class TestExecution(unittest.TestCase):
    def test_list_only_prints_without_running_and_execution_returns_test_status(self):
        command = ["swift", "test", "--filter", "^ExampleTests\\.Suite/"]
        with (
            patch.object(selector, "selected_plan", return_value=("ExampleTests.Suite", command)),
            patch.object(selector.subprocess, "run", return_value=subprocess.CompletedProcess(command, 7)) as run,
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            with patch.object(selector.sys, "argv", ["selector", "--base", "HEAD^", "--list-only"]):
                self.assertEqual(selector.main(), 0)
            run.assert_not_called()
            self.assertIn("Command:", output.getvalue())
            with patch.object(selector.sys, "argv", ["selector", "--base", "HEAD^"]):
                self.assertEqual(selector.main(), 7)
            run.assert_called_once_with(command, cwd=selector.ROOT)
