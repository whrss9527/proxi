import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
state_file = Path(os.environ["FAKE_STATE"])
state = json.loads(state_file.read_text())
if tool == "xcrun" and args[0] == "notarytool":
    if args[1] == "submit": print('{"id":"test"}')
    elif args[1] == "wait": print(json.dumps({"status":os.environ["FAKE_NOTARY_STATUS"]}))
    else: print('{}')
elif tool == "xcrun" and args[0] == "stapler":
    action = args[1]
    calls = state.get(action, 0)
    state[action] = calls + 1
    state.setdefault("actions", []).append(action)
    results = json.loads(os.environ["FAKE_" + action.upper() + "_RESULTS"])
    state_file.write_text(json.dumps(state))
    sys.exit(results[min(calls, len(results)-1)])
elif tool == "ditto":
    if args[0] == "-x": (Path(args[-1]) / "Sample.app").mkdir()
    else: Path(args[-1]).write_bytes(b"repacked")
elif tool == "sleep":
    state["sleeps"] = state.get("sleeps", 0) + 1
    state_file.write_text(json.dumps(state))
'''


class StaplerRetryTests(unittest.TestCase):
    def run_notary(self, staple=(0,), validate=(0,), status="Accepted"):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tools = root / "bin"
            tools.mkdir()
            mock = tools / "mock.py"
            mock.write_text(MOCK)
            mock.chmod(0o755)
            for name in ("xcrun", "ditto", "spctl", "codesign", "sleep"):
                (tools / name).symlink_to(mock)
            state = root / "state.json"
            state.write_text("{}")
            archive = root / "Sample.zip"
            archive.write_bytes(b"original")
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                       RUNNER_TEMP=str(root / "runner"), NOTARY_KEY_P8="",
                       NOTARY_APPLE_ID="test@example.invalid", NOTARY_PASSWORD="test-only",
                       NOTARY_TEAM_ID="ABCDE12345", FAKE_STATE=str(state),
                       FAKE_STAPLE_RESULTS=json.dumps(staple),
                       FAKE_VALIDATE_RESULTS=json.dumps(validate), FAKE_NOTARY_STATUS=status)
            script = Path(__file__).resolve().parents[1] / "notarize.sh"
            result = subprocess.run(["bash", str(script), str(archive)], env=env,
                                    capture_output=True, text=True)
            return result, json.loads(state.read_text()), archive.read_bytes()

    def test_network_failures_retry_both_actions_then_publishable_archive(self):
        result, state, archive = self.run_notary(staple=(68, 0), validate=(68, 0))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state["actions"], ["staple", "staple", "validate", "validate"])
        self.assertEqual(state["sleeps"], 2)
        self.assertEqual(archive, b"repacked")

    def test_repeated_staple_network_failure_stops_after_three_and_keeps_archive(self):
        result, state, archive = self.run_notary(staple=(68,))
        self.assertEqual(result.returncode, 68)
        self.assertEqual(state["actions"], ["staple"] * 3)
        self.assertEqual(state["sleeps"], 2)
        self.assertEqual(archive, b"original")

    def test_repeated_validate_network_failure_keeps_original_archive(self):
        result, state, archive = self.run_notary(validate=(68,))
        self.assertEqual(result.returncode, 68)
        self.assertEqual(state["actions"], ["staple"] + ["validate"] * 3)
        self.assertEqual(archive, b"original")

    def test_non_network_failure_stops_immediately(self):
        result, state, archive = self.run_notary(validate=(65,))
        self.assertEqual(result.returncode, 65)
        self.assertEqual(state["actions"], ["staple", "validate"])
        self.assertNotIn("sleeps", state)
        self.assertEqual(archive, b"original")

    def test_rejected_notarization_never_attempts_to_staple(self):
        result, state, archive = self.run_notary(status="Invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("actions", state)
        self.assertEqual(archive, b"original")
