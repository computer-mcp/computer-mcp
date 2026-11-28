import importlib.util
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET


SPEC = importlib.util.spec_from_file_location("run_swift_tests", Path(__file__).parents[1] / "run-swift-tests.py")
swift_tests = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(swift_tests)


class SwiftTestPartition(unittest.TestCase):
    def test_serial_configurations_share_one_exact_selector(self):
        module_suite, method = swift_tests.OPTIMIZED_TEST.split("/")
        with tempfile.TemporaryDirectory() as work, patch.dict("os.environ", {"RELEASE_WORK_DIR": work}):
            def swift(command, *, check):
                self.assertTrue(check)
                if "--xunit-output" in command:
                    report = Path(command[-1])
                    self.assertTrue(report.is_relative_to(work))
                    suite = ET.Element("testsuite")
                    ET.SubElement(suite, "testcase", classname=module_suite, name=method)
                    ET.ElementTree(suite).write(report)

            with patch.object(swift_tests.subprocess, "run", side_effect=swift) as invoke:
                swift_tests.main()
            debug, optimized = (call.args[0] for call in invoke.call_args_list)
            self.assertEqual(debug[:-1], ["/usr/bin/swift", "test", "--no-parallel", "--configuration", "debug", "--skip"])
            selector = debug[-1]
            self.assertEqual(optimized[:-1], [
                "/usr/bin/swift", "test", "--no-parallel", "--configuration", "release", "--build-system", "swiftbuild",
                "--test-product", module_suite.split(".")[0], "--disable-xctest", "--filter", selector, "--xunit-output",
            ])
            self.assertRegex(swift_tests.OPTIMIZED_TEST, selector)
            self.assertRegex(swift_tests.OPTIMIZED_TEST + "/Source.swift:1:1", selector)
            self.assertIsNone(re.search(selector, f"{module_suite}/{method[:-2]}Suffix()"))
            self.assertEqual(list(Path(work).iterdir()), [])

    def test_optimized_only_run_requires_exactly_one_passing_case(self):
        module_suite, method = swift_tests.OPTIMIZED_TEST.split("/")
        for cases in ([], ["wrong()"], [method, "other()"], [method, method], [method, "skipped"]):
            with self.subTest(cases=cases):
                def run(*arguments):
                    self.assertIn("--xunit-output", arguments)
                    self.assertIn("release", arguments)
                    suite = ET.Element("testsuite")
                    for name in cases:
                        if name == "skipped":
                            ET.SubElement(suite[0], "skipped")
                        else:
                            ET.SubElement(suite, "testcase", classname=module_suite, name=name)
                    ET.ElementTree(suite).write(arguments[-1])

                with patch.object(swift_tests, "run_tests", side_effect=run):
                    with self.assertRaisesRegex(ValueError, "exactly one passing optimized test"):
                        swift_tests.main(optimized_only=True)
