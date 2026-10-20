import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "verify_module_graph", Path(__file__).resolve().parents[1] / "verify-module-graph.py")
module_graph = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module_graph)


def graph(**overrides):
    value = {
        "layers": [
            {"name": "base", "targets": ["Low"]},
            {"name": "upper", "targets": ["High", "Peer"]},
            {"name": "front", "targets": ["Tool"]},
        ],
        "allow": [],
        "macos_only": [],
        "macos_imports": ["AppKit"],
    }
    value.update(overrides)
    return value


class NeutralImportTests(unittest.TestCase):
    def test_attributed_and_declaration_imports_are_macos_imports(self):
        for line in ("import AppKit", "@_spi(Private) import AppKit", "import struct AppKit.NSImage",
                     "@preconcurrency import AppKit"):
            with self.subTest(line=line):
                self.assertEqual(module_graph.macos_imports(line, graph()), {"AppKit"})

    def test_import_text_inside_a_string_literal_is_not_an_import(self):
        text = 'let script = """\n  import AppKit\n  """\n'
        self.assertEqual(module_graph.macos_imports(text, graph()), set())

    def test_conditional_macos_framework_import_fails(self):
        text = "#if canImport(AppKit)\nimport AppKit\n#endif\n"
        self.assertEqual(module_graph.macos_imports(text, graph()), {"AppKit"})

    def test_platform_c_library_is_allowed_only_inside_a_selection(self):
        rules = graph(macos_imports=["AppKit", "Darwin"], conditional_macos_imports=["Darwin"])
        for library in ("Glibc", "Musl"):
            with self.subTest(library=library):
                text = f"#if canImport(Darwin)\nimport Darwin\n#elseif canImport({library})\nimport {library}\n#endif\n"
                self.assertEqual(module_graph.macos_imports(text, rules), set())
        for text in ("import Darwin\n", "#if os(macOS)\nimport Darwin\n#endif\n"):
            with self.subTest(text=text):
                self.assertEqual(module_graph.macos_imports(text, rules), {"Darwin"})


class NeutralPathTests(unittest.TestCase):
    def test_macos_locations_fail_and_standard_posix_paths_pass(self):
        rules = {"macos_path_prefixes": ["/Applications/", "/usr/bin/"], "posix_paths": ["/usr/bin/env"]}
        text = 'let a = "/usr/bin/env"\nlet b = "/usr/bin/git"\nlet c = "/Applications/X.app"\nlet d = "/bin/sh"\n'
        self.assertEqual(module_graph.macos_paths(text, rules), [(2, "/usr/bin/git"), (3, "/Applications/X.app")])
        interpolated = 'let e = "/Applications/\\(name).app"\n'
        self.assertEqual(module_graph.macos_paths(interpolated, rules), [(1, "/Applications/\\(name).app")])


class PackageModeTests(unittest.TestCase):
    def check(self, targets, **overrides):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump({"targets": targets}, handle)
        self.addCleanup(Path(handle.name).unlink)
        return module_graph.package(graph(**overrides), handle.name)

    def test_dependency_on_lower_layer_passes(self):
        targets = [{"name": "Low", "type": "regular", "dependencies": []},
                   {"name": "High", "type": "regular", "dependencies": [{"byName": ["Low", None]}]}]
        self.assertEqual(self.check(targets), [])

    def test_dependency_on_higher_layer_fails(self):
        targets = [{"name": "Low", "type": "regular", "dependencies": [{"byName": ["High", None]}]},
                   {"name": "High", "type": "regular", "dependencies": []}]
        self.assertIn("upward: Low -> High", self.check(targets))

    def test_same_layer_dependency_requires_permission(self):
        targets = [{"name": "High", "type": "regular", "dependencies": []},
                   {"name": "Peer", "type": "regular", "dependencies": [{"target": ["High", None]}]}]
        self.assertIn("same-layer dependency not permitted: Peer -> High", self.check(targets))
        self.assertEqual(self.check(targets, allow=["Peer->High"]), [])

    def test_unranked_target_without_dependencies_fails(self):
        targets = [{"name": "Stray", "type": "regular", "dependencies": []}]
        self.assertIn("unranked target: Stray", self.check(targets))

    def test_tests_and_products_are_ignored(self):
        targets = [{"name": "LowTests", "type": "test", "dependencies": [{"byName": ["Tool", None]}]},
                   {"name": "Low", "type": "regular", "dependencies": [{"product": ["NIOCore", "swift-nio", None, None]}]}]
        self.assertEqual(self.check(targets), [])

    def test_neutral_target_on_macos_target_fails(self):
        targets = [{"name": "Low", "type": "regular", "dependencies": []},
                   {"name": "High", "type": "regular", "dependencies": [{"byName": ["Low", None]}]}]
        self.assertIn("neutral to macOS: High -> Low", self.check(targets, macos_only=["Low"]))

    def test_test_support_serves_only_test_targets(self):
        targets = [{"name": "Low", "type": "regular", "dependencies": []},
                   {"name": "Support", "type": "regular", "dependencies": [{"byName": ["Low", None]}]},
                   {"name": "LowTests", "type": "test", "dependencies": [{"byName": ["Support", None]}]}]
        self.assertEqual(self.check(targets, test_support=["Support"]), [])
        targets.append({"name": "High", "type": "regular", "dependencies": [{"byName": ["Support", None]}]})
        self.assertIn("test support outside tests: High -> Support",
                      self.check(targets, test_support=["Support"]))

    def test_test_support_stays_neutral(self):
        targets = [{"name": "Native", "type": "regular", "dependencies": []},
                   {"name": "Support", "type": "regular", "dependencies": [{"byName": ["Native", None]}]}]
        self.assertIn("neutral test support to macOS: Support -> Native",
                      self.check(targets, test_support=["Support"], macos_only=["Native"]))


if __name__ == "__main__":
    unittest.main()
