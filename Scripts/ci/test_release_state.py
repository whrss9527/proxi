import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location("release_state",Path(__file__).with_name("release-state.py"))
state=importlib.util.module_from_spec(spec);spec.loader.exec_module(state)


class ReleaseStateTests(unittest.TestCase):
    def response(self,code=200,exit_code=0,body=None):
        value=body if body is not None else {"tag_name":"v0.17.0","draft":True}
        return SimpleNamespace(returncode=exit_code,stdout=f"HTTP/2.0 {code} Status\n\n"+json.dumps(value),stderr="")

    def test_confirmed_draft_and_published_are_distinct(self):
        for draft,expected in [(True,"draft"),(False,"published")]:
            with self.subTest(draft=draft),patch.object(state.subprocess,"run",return_value=self.response(body={"tag_name":"v0.17.0","draft":draft})):
                self.assertEqual(state.release_state("example/proxi","v0.17.0"),expected)

    def test_only_confirmed_404_can_be_absent(self):
        with patch.object(state.subprocess,"run",return_value=self.response(404,1)):
            self.assertEqual(state.release_state("example/proxi","v0.17.0"),"absent")
        with patch.object(state.subprocess,"run",return_value=self.response(404,0)):
            with self.assertRaises(RuntimeError):state.release_state("example/proxi","v0.17.0")

    def test_auth_server_and_unknown_errors_are_hard_failures(self):
        for code in [401,403,429,500,503]:
            with self.subTest(code=code),patch.object(state.subprocess,"run",return_value=self.response(code,1)):
                with self.assertRaises(RuntimeError):state.release_state("example/proxi","v0.17.0")
        with patch.object(state.subprocess,"run",return_value=SimpleNamespace(returncode=1,stdout="",stderr="network error")):
            with self.assertRaises(RuntimeError):state.release_state("example/proxi","v0.17.0")

    def test_tag_draft_type_and_exit_code_must_all_be_valid(self):
        for value in [{"tag_name":"v0.16.11","draft":True},{"tag_name":"v0.17.0"},{"tag_name":"v0.17.0","draft":"true"}]:
            with self.subTest(value=value),patch.object(state.subprocess,"run",return_value=self.response(body=value)):
                with self.assertRaises(RuntimeError):state.release_state("example/proxi","v0.17.0")
        with patch.object(state.subprocess,"run",return_value=self.response(200,45)):
            with self.assertRaises(RuntimeError):state.release_state("example/proxi","v0.17.0")
