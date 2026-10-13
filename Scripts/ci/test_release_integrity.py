import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_integrity", Path(__file__).with_name("release-integrity.py"))
integrity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(integrity)


class ReleaseIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in integrity.archive_names("v0.17.0"):
            (self.root / name).write_bytes(name.replace("ProxySwitch", "Proxi").encode())
        self.candidate = integrity.make_candidate(self.root, "v0.17.0", "a" * 40, "123", "1", "A56J9KFVGV")
        (self.root / "release-candidate.json").write_text(json.dumps(self.candidate))
        (self.root / "SHA256SUMS.txt").write_text("".join(f"{sha}  {name}\n" for name, sha in self.candidate["archives"].items()))
        self.identity = {key:self.candidate[key] for key in ["tag", "sourceSha", "runId", "runAttempt"]}
        self.receipts = self.root / "receipts"; self.receipts.mkdir()

    def write_receipt(self, arch, candidate=None):
        (self.receipts / f"{arch}.json").write_text(json.dumps({"architecture":arch,"candidate":candidate or self.candidate}))

    def test_same_fixed_bytes_and_both_architectures_are_required(self):
        self.assertEqual(integrity.check_candidate(self.root, self.identity), self.candidate)
        for arch in ["arm64","x86_64"]: self.write_receipt(arch)
        integrity.check_receipts(self.candidate, self.receipts)

    def test_changed_zip_is_rejected_even_if_checksum_file_is_updated(self):
        name = "Proxi-macos.zip"; (self.root/name).write_bytes(b"changed")
        sums = dict(self.candidate["archives"]); sums[name] = integrity.digest(self.root/name)
        (self.root/"SHA256SUMS.txt").write_text("".join(f"{sha}  {n}\n" for n,sha in sums.items()))
        with self.assertRaises(ValueError): integrity.check_candidate(self.root,self.identity)

    def test_missing_receipt_and_old_run_receipt_cannot_publish(self):
        self.write_receipt("arm64")
        with self.assertRaises(FileNotFoundError): integrity.check_receipts(self.candidate,self.receipts)
        self.write_receipt("x86_64",dict(self.candidate,runAttempt="2"))
        with self.assertRaises(ValueError): integrity.check_receipts(self.candidate,self.receipts)

    def test_receipt_architecture_cannot_be_substituted(self):
        self.write_receipt("arm64")
        (self.receipts/"x86_64.json").write_text((self.receipts/"arm64.json").read_text())
        with self.assertRaises(ValueError): integrity.check_receipts(self.candidate,self.receipts)

    def test_source_tag_and_attempt_must_match_current_run(self):
        for field in ["tag","sourceSha","runId","runAttempt"]:
            wrong=dict(self.identity);wrong[field]+="1"
            with self.subTest(field=field),self.assertRaises(ValueError):integrity.check_candidate(self.root,wrong)

    def test_legacy_names_are_exact_copies(self):
        (self.root/"ProxySwitch-macos.zip").write_bytes(b"repacked")
        with self.assertRaises(ValueError):integrity.make_candidate(self.root,"v0.17.0","a"*40,"123","1","A56J9KFVGV")

    def test_missing_or_extra_archives_cannot_form_candidate(self):
        (self.root/"other.zip").write_bytes(b"extra")
        with self.assertRaises(ValueError):integrity.make_candidate(self.root,"v0.17.0","a"*40,"123","1","A56J9KFVGV")
        (self.root/"other.zip").unlink();(self.root/"Proxi-macos-arm64.zip").unlink()
        with self.assertRaises(ValueError):integrity.make_candidate(self.root,"v0.17.0","a"*40,"123","1","A56J9KFVGV")

    def test_duplicate_checksum_entry_cannot_be_accepted(self):
        path=self.root/"SHA256SUMS.txt";path.write_text(path.read_text()*2)
        with self.assertRaises(ValueError):integrity.check_candidate(self.root,self.identity)

    def test_missing_team_and_invalid_tag_are_rejected(self):
        for tag,team in [("v0.17.0",""),("v0.17.0-beta.1","A56J9KFVGV"),("v0.17.0","ABCDE12345")]:
            with self.subTest(tag=tag,team=team),self.assertRaises(ValueError):
                integrity.make_candidate(self.root,tag,"a"*40,"123","1",team)
