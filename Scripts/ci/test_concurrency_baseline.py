import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("baseline", Path(__file__).with_name("concurrency-baseline.py"))
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)


class ConcurrencyBaselineTests(unittest.TestCase):
    def test_repeated_diagnostics_count_once_and_ignore_echoed_source(self):
        text = """/tmp/base/Sources/Proxi/App.swift:10:3: warning: actor isolation
/tmp/base/Sources/Proxi/App.swift:10:3: warning: actor isolation
   | warning: actor isolation
/tmp/base/Packages/ProxiProcess/Sources/ProxiProcess/ProcessCommand.swift:7:2: warning: Sendable
/tmp/base/Sources/ProxiEngine/App.swift:10:3: warning: actor isolation
"""
        self.assertEqual(len(baseline.warnings(text)), 3)

    def test_checkout_paths_do_not_change_baseline(self):
        diagnostic = "/Sources/Proxi/App.swift:10:3: warning: actor isolation\n"
        self.assertEqual(baseline.warnings("/tmp/base" + diagnostic), baseline.warnings("/work/head" + diagnostic))
