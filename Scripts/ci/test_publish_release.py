import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec=importlib.util.spec_from_file_location("release_integrity",Path(__file__).with_name("release-integrity.py"))
integrity=importlib.util.module_from_spec(spec);spec.loader.exec_module(integrity)

MOCK=r'''#!/usr/bin/env python3
import json,os,shutil,sys
from pathlib import Path
tool,args=Path(sys.argv[0]).name,sys.argv[1:]
state_path=Path(os.environ["FAKE_STATE"]);state=json.loads(state_path.read_text())
state.setdefault("calls",[]).append([tool,*args]);state_path.write_text(json.dumps(state))
if tool=="git":
    if args[0]=="rev-parse":print(os.environ["RELEASE_SOURCE_SHA"])
    elif args[0]=="ls-remote":sys.exit(2)
elif tool=="gh":
    if args[0]=="api":
        if "--method" in args and args[args.index("--method")+1]=="POST":
            value=json.loads(Path(args[args.index("--input")+1]).read_text())
            value["id"]=411323629
            if os.environ["FAKE_CREATED_PUBLIC"]=="1":value["draft"]=False
            state["created"]=True;state_path.write_text(json.dumps(state))
            print(json.dumps(value));sys.exit(0)
        queries=sum(c[:2]==["gh","api"] and "--include" in c for c in state["calls"])
        if os.environ["FAKE_API_ERROR"]=="1" and queries==1:
            print('HTTP/2.0 503 Service Unavailable\n\n{}');sys.exit(1)
        public=os.environ["FAKE_PUBLIC"]=="1" or state.get("published",False) or (os.environ["FAKE_SECOND_PUBLIC"]=="1" and queries>=2) or (os.environ["FAKE_PUBLIC_AFTER_UPLOAD"]=="1" and state.get("uploaded",False))
        value={"id":411323629,"tag_name":"v0.17.0","draft":not public}
        if os.environ["FAKE_ID_MISMATCH"]=="1" and args[-1].endswith("/411323629"):value["id"]=411323630
        if (os.environ["FAKE_TAG_MISSES_DRAFT"]=="1" or os.environ["FAKE_DELAYED_VISIBILITY"]=="1") and "/releases/tags/" in args[-1]:
            print('HTTP/2.0 404 Not Found\n\n{}');sys.exit(1)
        if "/releases?" in args[-1]:value=[] if os.environ["FAKE_DELAYED_VISIBILITY"]=="1" else [value]
        print('HTTP/2.0 200 OK\n\n'+json.dumps(value))
    elif args[:2]==["release","view"]:
        release_id=411323630 if os.environ["FAKE_CLI_ID_MISMATCH"]=="1" else 411323629
        print(json.dumps({"apiUrl":f"https://api.github.com/repos/example/proxi/releases/{release_id}","tagName":"v0.17.0","isDraft":not state.get("published",False)}))
    elif args[:2]==["release","create"]:
        state["created"]=True;state_path.write_text(json.dumps(state))
    elif args[:2]==["release","upload"]:
        state["uploaded"]=True;state_path.write_text(json.dumps(state))
    elif args[:2]==["release","edit"]:
        state["published"]=True;state_path.write_text(json.dumps(state))
    elif args[:2]==["release","download"]:
        target=Path(args[args.index("--dir")+1])
        source=Path(os.environ["FAKE_CANDIDATE"])
        for name in [p.name for p in source.glob("*.zip")]+["SHA256SUMS.txt"]:
            shutil.copyfile(source/name,target/name)
        if os.environ["FAKE_CORRUPT"]=="1":(target/"Proxi-macos.zip").write_bytes(b"changed after upload")
        if os.environ["FAKE_EXTRA"]=="1":(target/"unexpected.zip").write_bytes(b"extra attachment")
    elif args[:2]==["release","list"]:print("v0.16.11")
'''

class PublishReleaseTests(unittest.TestCase):
    def run_publish(self,public=False,corrupt=False,api_error=False,second_public=False,extra=False,tag_misses_draft=False,delayed_visibility=False,created_public=False,public_after_upload=False,id_mismatch=False,cli_id_mismatch=False):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);candidate=root/"candidate";candidate.mkdir()
            for name in integrity.archive_names("v0.17.0"):
                (candidate/name).write_bytes(name.replace("ProxySwitch","Proxi").encode())
            identity=integrity.make_candidate(candidate,"v0.17.0","a"*40,"123","1","A56J9KFVGV")
            (candidate/"release-candidate.json").write_text(json.dumps(identity))
            (candidate/"SHA256SUMS.txt").write_text("".join(f"{sha}  {name}\n" for name,sha in identity["archives"].items()))
            receipts=root/"receipts";receipts.mkdir()
            for arch in ["arm64","x86_64"]:(receipts/f"{arch}.json").write_text(json.dumps({"architecture":arch,"candidate":identity}))
            (root/"CHANGELOG.md").write_text("## 0.17.0（2026-10-13）\n\n- 修正发行包安装验证。\n")
            tools=root/"bin";tools.mkdir();mock=tools/"mock.py";mock.write_text(MOCK);mock.chmod(0o755)
            for name in ["git","gh"]:(tools/name).symlink_to(mock)
            state=root/"state.json";state.write_text("{}")
            env=dict(os.environ,PATH=str(tools)+os.pathsep+os.environ["PATH"],FAKE_STATE=str(state),
                     FAKE_PUBLIC="1" if public else "0",FAKE_CORRUPT="1" if corrupt else "0",
                     FAKE_API_ERROR="1" if api_error else "0",FAKE_SECOND_PUBLIC="1" if second_public else "0",
                     FAKE_EXTRA="1" if extra else "0",
                     FAKE_TAG_MISSES_DRAFT="1" if tag_misses_draft else "0",
                     FAKE_DELAYED_VISIBILITY="1" if delayed_visibility else "0",
                     FAKE_CREATED_PUBLIC="1" if created_public else "0",
                     FAKE_PUBLIC_AFTER_UPLOAD="1" if public_after_upload else "0",
                     FAKE_ID_MISMATCH="1" if id_mismatch else "0",
                     FAKE_CLI_ID_MISMATCH="1" if cli_id_mismatch else "0",
                     FAKE_CANDIDATE=str(candidate),RUNNER_TEMP=str(root),TAG="v0.17.0",RELEASE_SOURCE_SHA="a"*40,
                     GITHUB_RUN_ID="123",GITHUB_RUN_ATTEMPT="1",GITHUB_REPOSITORY="example/proxi")
            script=Path(__file__).with_name("publish-release.sh").resolve()
            result=subprocess.run(["bash",str(script),str(candidate),str(receipts)],env=env,cwd=root,capture_output=True,text=True,timeout=10)
            return result,json.loads(state.read_text())["calls"]

    def test_only_verified_uploaded_bytes_can_be_made_public(self):
        result,calls=self.run_publish()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        upload=next(i for i,c in enumerate(calls) if c[:3]==["gh","release","upload"])
        download=next(i for i,c in enumerate(calls) if c[:3]==["gh","release","download"])
        publish=next(i for i,c in enumerate(calls) if c[:3]==["gh","release","edit"])
        self.assertLess(upload,download);self.assertLess(download,publish)

    def test_draft_missing_from_tag_endpoint_can_still_be_published(self):
        result,calls=self.run_publish(tag_misses_draft=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue(any(c[:3]==["gh","release","upload"] for c in calls))
        self.assertTrue(any(c[:3]==["gh","release","edit"] for c in calls))
        self.assertFalse(any(c[:3]==["gh","release","create"] for c in calls), "真实草稿存在时不再创建一个")

    def test_existing_public_release_cannot_receive_any_mutation(self):
        result,calls=self.run_publish(public=True)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[0]=="git" and c[1] in ["tag","push"] for c in calls))
        self.assertFalse(any(c[:2]==["gh","release"] and c[2] in ["create","upload","edit"] for c in calls))

    def test_corrupt_remote_draft_attachment_remains_private(self):
        result,calls=self.run_publish(corrupt=True)
        self.assertNotEqual(result.returncode,0)
        self.assertTrue(any(c[:3]==["gh","release","download"] for c in calls))
        self.assertFalse(any(c[:3]==["gh","release","edit"] for c in calls))

    def test_api_failure_never_becomes_permission_to_overwrite(self):
        result,calls=self.run_publish(api_error=True,second_public=True)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:3]==["gh","release","upload"] for c in calls))
        self.assertFalse(any(c[0]=="git" and c[1] in ["tag","push"] for c in calls))

    def test_publication_before_upload_is_detected(self):
        result,calls=self.run_publish(second_public=True)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:3]==["gh","release","upload"] for c in calls))

    def test_unexpected_remote_attachment_cannot_be_made_public(self):
        result,calls=self.run_publish(extra=True)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:3]==["gh","release","edit"] for c in calls))


    def test_created_draft_is_bound_by_id_when_indexes_still_miss_it(self):
        result,calls=self.run_publish(delayed_visibility=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        creation=next(i for i,c in enumerate(calls) if c[:2]==["gh","api"] and "POST" in c)
        reads=[c for c in calls[creation+1:] if c[:2]==["gh","api"]]
        self.assertGreaterEqual(len(reads),3)
        self.assertTrue(all(c[-1].endswith("/releases/411323629") for c in reads))

    def test_known_draft_state_is_pinned_to_its_id(self):
        result,calls=self.run_publish(tag_misses_draft=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue(any(c[:2]==["gh","api"] and c[-1].endswith("/releases/411323629") for c in calls))
        self.assertFalse(any(c[:2]==["gh","api"] and "POST" in c for c in calls))

    def test_created_public_response_cannot_authorize_upload(self):
        result,calls=self.run_publish(delayed_visibility=True,created_public=True)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:3]==["gh","release","upload"] for c in calls))

    def test_id_changed_before_upload_stops_publication(self):
        result,calls=self.run_publish(id_mismatch=True)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:3]==["gh","release","upload"] for c in calls))

    def test_publication_after_upload_is_detected_before_edit(self):
        result,calls=self.run_publish(public_after_upload=True)
        self.assertNotEqual(result.returncode,0)
        self.assertTrue(any(c[:3]==["gh","release","upload"] for c in calls))
        self.assertFalse(any(c[:3]==["gh","release","edit"] for c in calls))


    def test_cli_must_resolve_the_same_private_release_before_transport(self):
        result,calls=self.run_publish(cli_id_mismatch=True)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:3]==["gh","release","upload"] for c in calls))
        self.assertFalse(any(c[:3]==["gh","release","edit"] for c in calls))
