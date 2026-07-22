#!/usr/bin/env python3
"""Generate polish-tests.json from polish-tests.yaml for the Swift test suite.

polish-tests.yaml is the source of truth for the polish scenario tests. The
Swift tests load the generated polish-tests.json. Run this after editing the
YAML, or once on a clean checkout before running the default test lane.

Usage:
    python3 generate_test_data.py
"""

import json
from pathlib import Path

import yaml

HERE = Path(__file__).parent


def main():
    tests_yaml = HERE / "polish-tests.yaml"
    tests_json = HERE / "polish-tests.json"
    scenarios = yaml.safe_load(tests_yaml.read_text())
    for s in scenarios:
        s["accepted"] = [a.rstrip("\n") for a in s["accepted"]]
    tests_json.write_text(
        json.dumps(scenarios, indent=2, ensure_ascii=False) + "\n")
    print(f"Wrote {tests_json.name}: {len(scenarios)} scenarios")


if __name__ == "__main__":
    main()
