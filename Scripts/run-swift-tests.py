#!/usr/bin/env python3
"""Run the shared macOS Swift tests with the capacity case optimized."""

import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


OPTIMIZED_TEST = (
    "ComputerMCPMacOSTests.MCPHostInvocationTests/"
    "backgroundWorkKeepsExactContextThroughDerivedWorkAndReleasesItAtCompletion()"
)


def run_tests(*arguments):
    command = ["/usr/bin/swift", "test", "--no-parallel", *arguments]
    print(shlex.join(command), flush=True)
    subprocess.run(command, check=True)


def main():
    # Swift Testing's filter identifier can include a source location after the test name.
    pattern = "^" + re.escape(OPTIMIZED_TEST) + r"(?:/|$)"
    run_tests("--configuration", "debug", "--skip", pattern)
    # Swift Build exposes individual test products for the optimized run.
    test_product = OPTIMIZED_TEST.split(".", 1)[0]
    with tempfile.TemporaryDirectory(prefix="swift-test-", dir=os.environ.get("RELEASE_WORK_DIR")) as temporary:
        report = Path(temporary) / "optimized.xml"
        run_tests(
            "--configuration", "release", "--build-system", "swiftbuild", "--test-product", test_product,
            "--disable-xctest", "--filter", pattern, "--xunit-output", str(report),
        )
        cases = ET.parse(report).findall(".//testcase")
        identifiers = [f"{case.get('classname')}/{case.get('name')}" for case in cases]
        if identifiers != [OPTIMIZED_TEST] or any(cases[0].find(tag) is not None for tag in ("skipped", "failure", "error")):
            raise ValueError(f"Expected exactly one passing optimized test ({OPTIMIZED_TEST}), got {identifiers}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, ET.ParseError) as error:
        sys.exit(f"Swift test partition failed: {error}")
