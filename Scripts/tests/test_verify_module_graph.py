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
            {"name": "residual", "targets": ["Shared"]},
            {"name": "front", "targets": ["Tool"]},
        ],
        "allow": [],
        "macos_only": [],
        "macos_imports": ["AppKit"],
        "executables": ["Tool"],
        "residual": "Shared",
        "files": {"^Low": "Low", "^High": "High", "^Peer": "Peer"},
    }
    value.update(overrides)
    return value


class PlanModeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.sources = Path(self.temporary.name)
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id: String\n}\n")
        self.write("Shared/High.swift", "package struct HighService {\n  let value: LowValue\n}\n")

    def write(self, relative, text):
        path = self.sources / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def problems(self, **overrides):
        return module_graph.plan(graph(**overrides), self.sources)

    def test_downward_reference_passes(self):
        self.assertEqual(self.problems(), [])

    def test_upward_reference_and_cycle_fail(self):
        self.write("Shared/Low.swift", "package struct LowValue {\n  let owner: HighService?\n}\n")
        problems = self.problems()
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in problems))
        self.assertTrue(any(p.startswith("cycle:") for p in problems))

    def test_cut_removes_the_edge(self):
        self.write("Shared/Low.swift", "package struct LowValue {\n  let owner: HighService?\n}\n")
        self.assertEqual(self.problems(cuts=["LowValue->HighService"]), [])

    def test_same_layer_dependency_requires_permission(self):
        self.write("Shared/Peer.swift", "package struct PeerValue {\n  let service: HighService\n}\n")
        self.assertIn("same-layer dependency not permitted: Peer -> High",
                      [p.split(":")[0] + ":" + p.split(":")[1] for p in self.problems()])
        self.assertEqual(self.problems(allow=["Peer->High"]), [])

    def test_free_function_reference_counts(self):
        self.write("Shared/High.swift", "package struct HighService {\n  let value: LowValue\n}\n"
                   "package func makeHigh() -> HighService { HighService(value: LowValue(id: \"\")) }\n")
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id: String\n  func build() { _ = makeHigh() }\n}\n")
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in self.problems()))

    def test_private_free_function_and_member_access_do_not_count(self):
        self.write("Shared/High.swift", "package struct HighService {\n  let value: LowValue\n}\n"
                   "private func json() -> Int { 1 }\n")
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id: String\n  func json() -> Int { 2 }\n"
                   "  func use() { _ = json() }\n}\n")
        self.assertEqual(self.problems(), [])

    def test_string_interpolation_reference_counts(self):
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id: String\n"
                   "  var label: String { \"\\(HighService.self)\" }\n}\n")
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in self.problems()))

    def test_plain_string_text_does_not_count(self):
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id = \"HighService\"\n}\n")
        self.assertEqual(self.problems(), [])

    def test_extracted_target_keeps_its_references(self):
        self.write("Low/Low.swift", "package struct LowValue {\n  let owner: HighService?\n}\n")
        (self.sources / "Shared/Low.swift").unlink()
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in self.problems()))

    def test_macos_import_in_extracted_neutral_target_fails(self):
        self.write("Low/Low.swift", "import AppKit\npackage struct LowValue {\n  let id: String\n}\n")
        (self.sources / "Shared/Low.swift").unlink()
        self.assertIn("macOS import in neutral target: Low/Low.swift imports AppKit", self.problems())

    def test_attributed_and_declaration_imports_are_macos_imports(self):
        (self.sources / "Shared/Low.swift").unlink()
        for line in ("@_spi(Private) import AppKit", "import struct AppKit.NSImage",
                     "@preconcurrency import AppKit"):
            self.write("Low/Low.swift", line + "\npackage struct LowValue {\n  let id: String\n}\n")
            self.assertIn("macOS import in neutral target: Low/Low.swift imports AppKit",
                          self.problems(), line)

    def test_conditional_macos_framework_import_fails(self):
        self.write("Low/Low.swift", "#if canImport(AppKit)\nimport AppKit\n#endif\npackage struct LowValue {\n  let id: String\n}\n")
        (self.sources / "Shared/Low.swift").unlink()
        self.assertIn("macOS import in neutral target: Low/Low.swift imports AppKit", self.problems())

    def test_platform_c_library_is_allowed_only_inside_a_condition(self):
        (self.sources / "Shared/Low.swift").unlink()
        overrides = {"macos_imports": ["AppKit", "Darwin"], "conditional_macos_imports": ["Darwin"]}
        self.write("Low/Low.swift", "#if canImport(Darwin)\nimport Darwin\n#elseif canImport(Glibc)\nimport Glibc\n#endif\npackage struct LowValue {\n  let id: String\n}\n")
        self.assertEqual(self.problems(**overrides), [])
        self.write("Low/Low.swift", "import Darwin\npackage struct LowValue {\n  let id: String\n}\n")
        self.assertIn("macOS import in neutral target: Low/Low.swift imports Darwin", self.problems(**overrides))

    def test_relocation_moves_a_file_of_an_extracted_target(self):
        self.write("Low/Native.swift", "import AppKit\npackage struct NativeValue {\n  let id: String\n}\n")
        self.assertTrue(self.problems())
        overrides = {"macos_only": ["Native"], "relocations": {"Low/Native.swift": "Native"}}
        overrides["layers"] = graph()["layers"] + [{"name": "native", "targets": ["Native"]}]
        self.assertEqual(self.problems(**overrides), [])

    def test_executable_declarations_never_own_references(self):
        self.write("Tool/Main.swift", "package struct LowValue2 {}\npackage struct App {}\n")
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id: String\n  var app: App? { nil }\n}\n")
        self.assertEqual(self.problems(), [])

    def test_nested_name_does_not_hide_another_declarations_reference(self):
        self.write("Shared/Low.swift", "package struct Container {\n  struct HighService {}\n}\n"
                   "package struct LowValue {\n  let owner: HighService?\n}\n")
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in self.problems()))

    def test_extension_sees_nested_names_of_its_type(self):
        self.write("Shared/Low.swift", "package struct LowValue {\n  struct HighService {}\n}\n"
                   "extension LowValue {\n  func use() -> HighService { HighService() }\n}\n")
        self.assertEqual(self.problems(), [])

    def test_deeply_nested_name_does_not_hide_a_member_reference(self):
        self.write("Shared/Low.swift", "package struct LowValue {\n  struct Container {\n    struct HighService {}\n  }\n"
                   "  let owner: HighService?\n}\n")
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in self.problems()))

    def test_nested_type_from_a_sibling_extension_resolves_locally(self):
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id: String\n}\n"
                   "extension LowValue {\n  struct HighService {}\n}\n"
                   "extension LowValue {\n  func use() -> HighService { HighService() }\n}\n")
        self.assertEqual(self.problems(), [])

    def test_local_binding_shadows_a_free_function(self):
        self.write("Shared/High.swift", "package struct HighService {\n  let value: LowValue\n}\n"
                   "package func makeHigh() -> HighService { HighService(value: LowValue(id: \"\")) }\n")
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id: String\n"
                   "  func count() -> Int {\n    let makeHigh = 42\n    return makeHigh\n  }\n}\n")
        self.assertEqual(self.problems(), [])

    def test_extension_of_a_nested_type_does_not_hide_outer_references(self):
        self.write("Shared/Low.swift", "package struct LowValue {\n  struct Container {}\n  let owner: HighService?\n}\n"
                   "extension LowValue.Container {\n  struct HighService {}\n}\n")
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in self.problems()))

    def test_binding_in_one_method_does_not_hide_a_call_in_another(self):
        self.write("Shared/High.swift", "package struct HighService {\n  let value: LowValue\n}\n"
                   "package func makeHigh() -> HighService { HighService(value: LowValue(id: \"\")) }\n")
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id: String\n"
                   "  func count() -> Int {\n    let makeHigh = 42\n    return makeHigh\n  }\n"
                   "  func build() {\n    _ = makeHigh()\n  }\n}\n")
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in self.problems()))

    def test_capitalized_free_function_counts(self):
        self.write("Shared/High.swift", "package struct HighService {\n  let value: LowValue\n}\n"
                   "package func MakeHigh() -> HighService { HighService(value: LowValue(id: \"\")) }\n")
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id: String\n  func build() { _ = MakeHigh() }\n}\n")
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in self.problems()))

    def test_function_reference_without_call_counts(self):
        self.write("Shared/High.swift", "package struct HighService {\n  let value: LowValue\n}\n"
                   "package func makeHigh() -> HighService { HighService(value: LowValue(id: \"\")) }\n")
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id: String\n  static let factory = makeHigh\n}\n")
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in self.problems()))

    def test_interpolation_after_url_scheme_counts(self):
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id: String\n"
                   "  var url: String { \"https://\\(HighService.self)\" }\n}\n")
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in self.problems()))

    def test_raw_string_interpolation_counts(self):
        self.write("Shared/Low.swift", "package struct LowValue {\n  let id: String\n"
                   "  var label: String { #\"\\#(HighService.self)\"# }\n}\n")
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in self.problems()))

    def test_module_qualified_reference_counts_and_member_qualified_does_not(self):
        self.write("Shared/Low.swift", "package struct LowValue {\n  let owner: High.HighService?\n}\n")
        self.assertTrue(any(p.startswith("upward: Low -> High") for p in self.problems()))
        self.write("Shared/Low.swift", "package struct LowValue {\n  let owner: Other.HighService?\n}\n")
        self.assertEqual(self.problems(), [])

    def test_unranked_source_directory_fails(self):
        self.write("Unknown/Thing.swift", "import AppKit\npackage struct Thing {}\n")
        self.assertIn("unranked target directory: Unknown", self.problems())

    def test_missing_sources_fail(self):
        empty = tempfile.TemporaryDirectory()
        self.addCleanup(empty.cleanup)
        self.assertTrue(module_graph.plan(graph(), Path(empty.name))[0].startswith("no Swift sources"))

    def test_unallocated_declaration_fails(self):
        self.write("Shared/Stray.swift", "package struct Stray {}\n")
        self.assertIn("unallocated: Shared/Stray.swift:Stray", self.problems())


class TestAllocationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sources = self.root / "Sources"
        (self.sources / "Shared").mkdir(parents=True)
        (self.sources / "Shared/Low.swift").write_text("struct LowValue {}\n")
        self.tests = self.root / "Tests/ComputerMCPTests"
        (self.tests / "Nested").mkdir(parents=True)
        (self.tests / "Nested/ValueTests.swift").write_text("import Testing\n")
        (self.tests / "TestingSupport.swift").write_text("struct Fixture {}\n")
        self.allocations = {"Nested/ValueTests.swift": "LowTests", "TestingSupport.swift": "HighTests"}

    def check(self, allocations):
        return module_graph.plan(graph(tests=allocations), self.sources)

    def test_complete_allocation_to_layer_targets_passes(self):
        self.assertEqual(self.check(self.allocations), [])

    def test_missing_test_and_support_allocations_fail(self):
        self.assertEqual(self.check({}), ["unallocated test: Nested/ValueTests.swift",
                                        "unallocated test: TestingSupport.swift"])

    def test_unknown_target_and_missing_test_suffix_fail(self):
        for target in ("UnknownTests", "Low", "LowTestsTests", None):
            with self.subTest(target=target):
                allocations = dict(self.allocations, **{"Nested/ValueTests.swift": target})
                self.assertIn(f"invalid test target: Nested/ValueTests.swift -> {target}",
                              self.check(allocations))

    def test_stale_allocation_fails(self):
        self.assertIn("test allocation has no source: MissingTests.swift",
                      self.check(dict(self.allocations, **{"MissingTests.swift": "LowTests"})))

    def test_copied_swift_fixture_is_not_a_test_source(self):
        (self.tests / "Fixtures").mkdir()
        (self.tests / "Fixtures/server.swift").write_text("print(1)\n")
        self.assertEqual(self.check(self.allocations), [])

    def test_explicit_test_directory_is_checked(self):
        moved = self.root / "OtherTests"
        moved.mkdir()
        (moved / "Extra.swift").write_text("struct Extra {}\n")
        self.assertEqual(module_graph.plan(graph(tests={"Extra.swift": "LowTests"}), self.sources, moved), [])
        self.assertIn("unallocated test: Extra.swift", module_graph.plan(graph(), self.sources, moved))

    def test_nested_fixture_directory_still_contains_test_sources(self):
        (self.tests / "Nested/Fixtures").mkdir()
        (self.tests / "Nested/Fixtures/Helper.swift").write_text("struct Helper {}\n")
        self.assertIn("unallocated test: Nested/Fixtures/Helper.swift", self.check(self.allocations))


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
