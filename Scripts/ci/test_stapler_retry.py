import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
tool, args = Path(sys.argv[0]).name, sys.argv[1:]
state_file = Path(os.environ["FAKE_STATE"])
state = json.loads(state_file.read_text())
def save(): state_file.write_text(json.dumps(state))
if tool == "xcrun" and args[0] == "notarytool":
    if args[1] == "submit":
        state["submissions"] = state.get("submissions", 0) + 1
        state["submitted_apps"] = sorted(str(p.relative_to(Path(args[2]).parent)) for p in (Path(args[2]).parent/"submission").glob("*/*.app"))
        save()
        if os.environ.get("FAKE_SUBMIT_FAIL") == "1": sys.exit(1)
        print('{"id":"test"}')
    elif args[1] == "wait":
        state["waits"] = state.get("waits", 0) + 1
        state["bounded_wait"] = "--timeout" in args and "20m" in args
        save()
        print(json.dumps({"status":os.environ["FAKE_NOTARY_STATUS"]}))
        sys.exit(int(os.environ.get("FAKE_WAIT_EXIT", "0")))
    else: print('{"issues":[{"message":"fake notary issue"}]}')
elif tool == "xcrun" and args[0] == "stapler":
    action = args[1]
    calls = state.get(action, 0)
    state[action] = calls + 1
    state.setdefault("actions", []).append(action)
    results = json.loads(os.environ["FAKE_" + action.upper() + "_RESULTS"])
    save()
    sys.exit(results[min(calls, len(results)-1)])
elif tool == "ditto":
    if args[0] == "-x": (Path(args[-1]) / "Sample.app").mkdir()
    else: Path(args[-1]).write_bytes(b"repacked")
elif tool == "codesign":
    if "--verify" in args:
        state.setdefault("verified", []).append(args[-1]); save()
        if os.environ.get("FAKE_FINAL_SIGNATURE_FAIL") == "1" and "/final/" in args[-1]: sys.exit(42)
elif tool == "spctl":
    if args == ["--status"]:
        print("assessments disabled" if os.environ.get("FAKE_DISABLED") == "1" else "assessments enabled")
        sys.exit(0)
    state["assessments"] = state.get("assessments", 0) + 1; save()
    status = os.environ.get("FAKE_SPCTL", "accepted")
    print("source=" + {"accepted":"Notarized Developer ID","unnotarized":"Unnotarized Developer ID","unknown":"Unknown"}[status])
    if os.environ.get("FAKE_OVERRIDE") == "1": print("override=security disabled")
    sys.exit(3 if status == "unnotarized" else 0)
elif tool == "sleep":
    state["sleeps"] = state.get("sleeps", 0) + 1; save()
'''


class StaplerRetryTests(unittest.TestCase):
    def run_notary(self, staple=(0,), validate=(0,), status="Accepted", count=1, **extra):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); tools = root / "bin"; tools.mkdir()
            mock = tools / "mock.py"; mock.write_text(MOCK); mock.chmod(0o755)
            for name in ("xcrun", "ditto", "spctl", "codesign", "sleep"): (tools / name).symlink_to(mock)
            state = root / "state.json"; state.write_text("{}")
            archives = [root / f"Sample-{i}.zip" for i in range(count)]
            for archive in archives: archive.write_bytes(b"original")
            runner = root / "runner"; runner.mkdir()
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                       RUNNER_TEMP=str(runner), NOTARY_KEY_P8="", NOTARY_APPLE_ID="test@example.invalid",
                       NOTARY_PASSWORD="test-only", NOTARY_TEAM_ID="ABCDE12345", FAKE_STATE=str(state),
                       FAKE_STAPLE_RESULTS=json.dumps(staple), FAKE_VALIDATE_RESULTS=json.dumps(validate),
                       FAKE_NOTARY_STATUS=status, SPCTL_TRIES="2", SPCTL_INTERVAL="0", **extra)
            script = Path(__file__).resolve().parents[1] / "notarize.sh"
            result = subprocess.run(["bash", str(script), *map(str, archives)], env=env,
                                    capture_output=True, text=True, timeout=15)
            return result, json.loads(state.read_text()), [p.read_bytes() for p in archives]

    def test_network_failures_retry_both_actions_then_publishable_archive(self):
        result, state, archives = self.run_notary(staple=(68, 0), validate=(68, 0))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state["actions"], ["staple", "staple", "validate", "validate"])
        self.assertEqual(state["sleeps"], 2)
        self.assertEqual(archives, [b"repacked"])

    def test_four_apps_use_one_bounded_common_notary_request(self):
        result, state, archives = self.run_notary(count=4)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state["submissions"], 1); self.assertEqual(state["waits"], 1)
        self.assertTrue(state["bounded_wait"])
        self.assertEqual(state["submitted_apps"], [f"submission/{i}/Sample.app" for i in range(4)])
        self.assertEqual(archives, [b"repacked"] * 4)
        self.assertEqual(sum("/final/" in p for p in state["verified"]), 4)

    def test_repeated_staple_network_failure_stops_after_three_and_keeps_archive(self):
        result, state, archives = self.run_notary(staple=(68,))
        self.assertEqual(result.returncode, 68); self.assertEqual(state["actions"], ["staple"] * 3)
        self.assertEqual(state["sleeps"], 2); self.assertEqual(archives, [b"original"])

    def test_repeated_validate_network_failure_keeps_original_archive(self):
        result, state, archives = self.run_notary(validate=(68,))
        self.assertEqual(result.returncode, 68)
        self.assertEqual(state["actions"], ["staple"] + ["validate"] * 3)
        self.assertEqual(archives, [b"original"])

    def test_non_network_failure_stops_immediately(self):
        result, state, archives = self.run_notary(validate=(65,))
        self.assertEqual(result.returncode, 65); self.assertEqual(state["actions"], ["staple", "validate"])
        self.assertNotIn("sleeps", state); self.assertEqual(archives, [b"original"])

    def test_rejected_notarization_never_attempts_to_staple(self):
        result, state, archives = self.run_notary(status="Invalid")
        self.assertNotEqual(result.returncode, 0); self.assertNotIn("actions", state)
        self.assertEqual(archives, [b"original"])

    def test_unnotarized_developer_id_cannot_be_publishable(self):
        result, state, archives = self.run_notary(FAKE_SPCTL="unnotarized")
        self.assertNotEqual(result.returncode, 0); self.assertEqual(state["assessments"], 2)
        self.assertIn("禁止发布", result.stdout); self.assertEqual(archives, [b"original"])

    def test_success_exit_with_unknown_assessment_is_not_enough(self):
        result, state, archives = self.run_notary(FAKE_SPCTL="unknown")
        self.assertNotEqual(result.returncode, 0); self.assertEqual(state["assessments"], 2)
        self.assertEqual(archives, [b"original"])

    def test_final_zip_signature_failure_preserves_entire_input_set(self):
        result, state, archives = self.run_notary(count=4, FAKE_FINAL_SIGNATURE_FAIL="1")
        self.assertEqual(result.returncode, 42); self.assertTrue(any("/final/" in p for p in state["verified"]))
        self.assertEqual(archives, [b"original"] * 4)

    def test_later_archive_failure_does_not_promote_earlier_successes(self):
        result, state, archives = self.run_notary(count=4, validate=(0, 65))
        self.assertEqual(result.returncode, 65); self.assertEqual(state["assessments"], 1)
        self.assertEqual(archives, [b"original"] * 4)

    def test_failed_common_submission_never_staples(self):
        result, state, archives = self.run_notary(count=4, FAKE_SUBMIT_FAIL="1")
        self.assertNotEqual(result.returncode, 0); self.assertEqual(state["submissions"], 1)
        self.assertNotIn("actions", state); self.assertEqual(archives, [b"original"] * 4)

    def test_accepted_text_does_not_override_failed_wait(self):
        result, state, archives = self.run_notary(FAKE_WAIT_EXIT="45")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("actions", state)
        self.assertEqual(archives, [b"original"])

    def test_disabled_gatekeeper_and_override_cannot_publish(self):
        for extra in [{"FAKE_DISABLED":"1"}, {"FAKE_OVERRIDE":"1"}]:
            with self.subTest(extra=extra):
                result, state, archives = self.run_notary(**extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(archives, [b"original"])
