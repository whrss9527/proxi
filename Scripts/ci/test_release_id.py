import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location("release_id_state",Path(__file__).with_name("release-state.py"))
state=importlib.util.module_from_spec(spec);spec.loader.exec_module(state)
DRAFT=json.loads((Path(__file__).parent/"fixtures/github-created-draft.json").read_text())


class ReleaseIDTests(unittest.TestCase):
    def response(self,code=200,exit_code=0,value=None):
        return SimpleNamespace(returncode=exit_code,stdout=f"HTTP/2.0 {code} Status\n\n"+json.dumps(DRAFT if value is None else value),stderr="")

    def test_known_id_reads_only_that_resource(self):
        with patch.object(state.subprocess,"run",return_value=self.response()) as api:
            self.assertEqual(state.find_release("example/proxi","v0.17.4",416322962),DRAFT)
            self.assertEqual(api.call_count,1)
            self.assertEqual(api.call_args.args[0][-1],"repos/example/proxi/releases/416322962")

    def test_unknown_id_and_api_errors_do_not_fall_back_to_indexes(self):
        for code in [401,403,404,429,503]:
            with self.subTest(code=code),patch.object(state.subprocess,"run",return_value=self.response(code,1)) as api:
                with self.assertRaises(RuntimeError):state.find_release("example/proxi","v0.17.4",416322962)
                self.assertEqual(api.call_count,1)

    def test_id_tag_and_draft_types_are_not_coerced(self):
        invalid=[{**DRAFT,"id":v} for v in [None,0,-1,True,"416322962",1.5]]
        invalid += [{**DRAFT,"tag_name":"v0.17.3"},{**DRAFT,"draft":"true"}]
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(RuntimeError):state.validate_identity(value,"v0.17.4")
        with self.assertRaises(RuntimeError):state.validate_identity(DRAFT,"v0.17.4",416322963)

    def test_created_response_requires_no_index_query(self):
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp)/"created.json";p.write_text(json.dumps(DRAFT));out=io.StringIO()
            with patch.object(state.sys,"argv",["release-state.py","example/proxi","v0.17.4","--created-response",str(p),"--json"]),patch.object(state.subprocess,"run") as api,contextlib.redirect_stdout(out):state.main()
            api.assert_not_called()
            self.assertEqual(json.loads(out.getvalue()),{"state":"draft","releaseId":416322962})

    def test_invalid_created_response_cannot_authorize_a_draft(self):
        for value in [{**DRAFT,"draft":False},{**DRAFT,"id":None},{**DRAFT,"tag_name":"v0.17.3"}]:
            with self.subTest(value=value),tempfile.TemporaryDirectory() as temp:
                p=Path(temp)/"created.json";p.write_text(json.dumps(value))
                with patch.object(state.sys,"argv",["release-state.py","example/proxi","v0.17.4","--created-response",str(p)]):
                    with self.assertRaises(RuntimeError):state.main()

    def test_json_lookup_refuses_missing_id(self):
        with patch.object(state.sys,"argv",["release-state.py","example/proxi","v0.17.4","--json"]),patch.object(state.subprocess,"run",return_value=self.response(value={"tag_name":"v0.17.4","draft":True})):
            with self.assertRaises(RuntimeError):state.main()
