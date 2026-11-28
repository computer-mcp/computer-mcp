#!/usr/bin/env python3
"""Run the shared macOS Swift tests with the capacity case optimized."""

import argparse
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
# Swift Testing can append a source location to the test identifier.
OPTIMIZED_PATTERN = "^" + re.escape(OPTIMIZED_TEST) + r"(?:/|$)"


def run_tests(*arguments):
    command = ["/usr/bin/swift", "test", "--no-parallel", *arguments]
    print(shlex.join(command), flush=True)
    subprocess.run(command, check=True)


def main(optimized_only=False):
    if not optimized_only:
        run_tests("--configuration", "debug", "--skip", OPTIMIZED_PATTERN)
    # Swift Build exposes individual test products for the optimized run.
    test_product = OPTIMIZED_TEST.split(".", 1)[0]
    with tempfile.TemporaryDirectory(prefix="swift-test-", dir=os.environ.get("RELEASE_WORK_DIR")) as temporary:
        report = Path(temporary) / "optimized.xml"
        run_tests(
            "--configuration", "release", "--build-system", "swiftbuild", "--test-product", test_product,
            "--disable-xctest", "--filter", OPTIMIZED_PATTERN, "--xunit-output", str(report),
        )
        cases = ET.parse(report).findall(".//testcase")
        identifiers = [f"{case.get('classname')}/{case.get('name')}" for case in cases]
        if identifiers != [OPTIMIZED_TEST] or any(cases[0].find(tag) is not None for tag in ("skipped", "failure", "error")):
            raise ValueError(f"Expected exactly one passing optimized test ({OPTIMIZED_TEST}), got {identifiers}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--optimized-only", action="store_true", help="run and verify the release capacity test")
    try:
        main(parser.parse_args().optimized_only)
    except (OSError, ValueError, subprocess.CalledProcessError, ET.ParseError) as error:
        sys.exit(f"Swift test partition failed: {error}")
