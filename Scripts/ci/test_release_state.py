import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location("release_state",Path(__file__).with_name("release-state.py"))
state=importlib.util.module_from_spec(spec);spec.loader.exec_module(state)


class ReleaseStateTests(unittest.TestCase):
    def response(self,code=200,exit_code=0,body=None,next_page=False,link=None):
        value=body if body is not None else {"tag_name":"v0.17.0","draft":True}
        if next_page:link = '<https://api.github.com/repositories/123/releases?per_page=100&page=2>; rel="next"'
        header = f"HTTP/2.0 {code} Status\n" + (f"Link: {link}\n" if link is not None else "")
        return SimpleNamespace(returncode=exit_code,stdout=header+"\n"+json.dumps(value),stderr="")

    def test_confirmed_draft_and_published_are_distinct(self):
        for draft,expected in [(True,"draft"),(False,"published")]:
            with self.subTest(draft=draft),patch.object(state.subprocess,"run",return_value=self.response(body={"tag_name":"v0.17.0","draft":draft})):
                self.assertEqual(state.release_state("example/proxi","v0.17.0"),expected)

    def test_only_confirmed_404_can_be_absent(self):
        with patch.object(state.subprocess,"run",side_effect=[self.response(404,1),self.response(body=[])]):
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

    def test_tag_endpoint_missing_draft_falls_back_to_release_list(self):
        for draft, expected in [(True, "draft"), (False, "published")]:
            with self.subTest(draft=draft), patch.object(state.subprocess, "run", side_effect=[
                self.response(404, 1), self.response(body=[{"tag_name":"v0.17.0", "draft":draft}])
            ]) as api:
                self.assertEqual(state.release_state("example/proxi", "v0.17.0"), expected)
                self.assertIn("releases?per_page=100&page=1", api.call_args.args[0][-1])

    def test_draft_can_be_found_on_later_pages(self):
        first = [{"tag_name":f"v1.0.{i}", "draft":False} for i in range(100)]
        with patch.object(state.subprocess, "run", side_effect=[
            self.response(404, 1), self.response(body=first,next_page=True),
            self.response(body=[{"tag_name":"v0.17.0", "draft":True}])
        ]) as api:
            self.assertEqual(state.release_state("example/proxi", "v0.17.0"), "draft")
            self.assertIn("page=2", api.call_args.args[0][-1])

    def test_failed_or_unknown_release_list_cannot_be_absent(self):
        responses = [self.response(403, 1), self.response(404, 1), self.response(503, 1),
                     self.response(body={}), self.response(body=[{}]),
                     self.response(body=[{"tag_name":"v0.17.0", "draft":"true"}]),
                     self.response(body=[{"tag_name":"v0.17.0", "draft":True}] * 2)]
        for response in responses:
            with self.subTest(response=response), patch.object(state.subprocess, "run", side_effect=[self.response(404,1), response]):
                with self.assertRaises(RuntimeError):state.release_state("example/proxi", "v0.17.0")


    def test_short_page_with_next_must_reach_later_draft(self):
        first=[{"tag_name":"v0.16.11","draft":False}]
        with patch.object(state.subprocess,"run",side_effect=[self.response(404,1),self.response(body=first,next_page=True),self.response(body=[{"tag_name":"v0.17.0","draft":True}])]) as api:
            self.assertEqual(state.release_state("example/proxi","v0.17.0"),"draft")
            self.assertEqual(api.call_count,3)
            self.assertEqual(api.call_args.args[0][-1],"repos/example/proxi/releases?per_page=100&page=2")

    def test_full_page_without_next_is_the_last_page(self):
        first=[{"tag_name":f"v1.0.{i}","draft":False} for i in range(100)]
        with patch.object(state.subprocess,"run",side_effect=[self.response(404,1),self.response(body=first)]) as api:
            self.assertEqual(state.release_state("example/proxi","v0.17.0"),"absent")
            self.assertEqual(api.call_count,2)

    def test_empty_next_page_or_failed_later_page_are_not_absence(self):
        first=[{"tag_name":"v0.16.11","draft":False}]
        sequences=[
            [self.response(404,1),self.response(body=[],next_page=True)],
            [self.response(404,1),self.response(body=first,next_page=True),self.response(503,1)],
        ]
        for responses in sequences:
            with self.subTest(responses=responses),patch.object(state.subprocess,"run",side_effect=responses):
                with self.assertRaises(RuntimeError):state.release_state("example/proxi","v0.17.0")

    def test_duplicate_draft_on_two_short_pages_is_rejected(self):
        value=[{"tag_name":"v0.17.0","draft":True}]
        with patch.object(state.subprocess,"run",side_effect=[self.response(404,1),self.response(body=value,next_page=True),self.response(body=value)]):
            with self.assertRaises(RuntimeError):state.release_state("example/proxi","v0.17.0")

    def test_malformed_foreign_or_repeated_next_links_are_rejected(self):
        valid='<https://api.github.com/repositories/123/releases?per_page=100&page=2>; rel="next"'
        invalid=["", "invalid",valid.replace("api.github.com","example.com"),valid.replace("page=2>","page=1>"),valid+", "+valid]
        for link in invalid:
            with self.subTest(link=link),patch.object(state.subprocess,"run",side_effect=[self.response(404,1),self.response(body=[],link=link)]):
                with self.assertRaises(RuntimeError):state.release_state("example/proxi","v0.17.0")
