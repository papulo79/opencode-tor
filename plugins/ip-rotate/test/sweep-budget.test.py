#!/usr/bin/env python3
# plugins/ip-rotate/test/sweep-budget.test.py
import importlib.util
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parent.parent / "exit-sweep-daemon.py"
spec = importlib.util.spec_from_file_location("exit_sweep_daemon", MODULE_PATH)
daemon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(daemon)


class TestSelectBatch(unittest.TestCase):
    def test_prioritizes_ok_then_new_then_rest(self):
        known = {"A": {"verdict": "ok"}, "B": {"verdict": "limited"}}
        onionoo = ["A", "B", "C"]
        result = daemon.select_batch(known, onionoo, budget_count=10)
        self.assertEqual(result, ["A", "C", "B"])

    def test_respects_budget_count(self):
        known = {"A": {"verdict": "ok"}, "B": {"verdict": "ok"}}
        result = daemon.select_batch(known, ["A", "B"], budget_count=1)
        self.assertEqual(result, ["A"])

    def test_no_duplicates_when_known_fp_also_in_onionoo(self):
        known = {"A": {"verdict": "limited"}}
        result = daemon.select_batch(known, ["A"], budget_count=10)
        self.assertEqual(result, ["A"])


if __name__ == "__main__":
    unittest.main()
