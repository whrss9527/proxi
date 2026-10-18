#!/usr/bin/env python3
"""明确区分未发布、草稿和公开；HTTP/API 未知错误一律阻止发行。"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import parse_qs, urlsplit


def request_json(endpoint, allow_missing=False):
    result = subprocess.run(["gh", "api", "--include", "--method", "GET",
                             endpoint],
                            capture_output=True, text=True)
    response = result.stdout.replace("\r\n", "\n")
    header, separator, body = response.partition("\n\n")
    match = re.match(r"HTTP/\S+\s+(\d{3})\b", header)
    status = int(match[1]) if match else None
    if status == 404 and result.returncode != 0 and allow_missing:
        return None, False
    if status != 200 or result.returncode != 0 or not separator:
        raise RuntimeError(f"无法确认 Release 状态（HTTP {status or '未知'}），停止发行")
    value = json.loads(body)
    if value is None:
        raise RuntimeError("Release 响应为空，停止发行")
    return value, has_next_page(header, endpoint)


def has_next_page(header, endpoint):
    # 只读取续页信号；请求仍用同仓库的固定端点，不跟随响应中的任意URL。
    expected_page = int(parse_qs(urlsplit(endpoint).query).get("page", ["1"])[0]) + 1
    next_count = 0
    for links in re.findall(r"^link:[ \t]*([^\r\n]*)$", header, re.IGNORECASE | re.MULTILINE):
        for link in links.split(","):
            match = re.fullmatch(r'\s*<([^<>]+)>\s*;\s*rel="([^"]+)"\s*', link)
            if not match:
                raise RuntimeError("Release 分页头无法确认，停止发行")
            target = urlsplit(match[1])
            if target.scheme != "https" or target.netloc != "api.github.com" or target.fragment:
                raise RuntimeError("Release 分页目标无法确认，停止发行")
            if "next" in match[2].split():
                query = parse_qs(target.query)
                if query.get("page") != [str(expected_page)] or query.get("per_page") != ["100"]:
                    raise RuntimeError("Release 续页编号无法确认，停止发行")
                next_count += 1
    if next_count > 1:
        raise RuntimeError("Release 续页标记重复，停止发行")
    return next_count == 1


def validate_release(value):
    if not isinstance(value, dict) or not isinstance(value.get("tag_name"), str) or type(value.get("draft")) is not bool:
        raise RuntimeError("Release 状态或标签无法确认，停止发行")


def validate_identity(value, tag, release_id=None):
    validate_release(value)
    if value["tag_name"] != tag:
        raise RuntimeError("Release 标签不匹配，停止发行")
    if type(value.get("id")) is not int or value["id"] <= 0:
        raise RuntimeError("Release ID 无法确认，停止发行")
    if release_id is not None and value["id"] != release_id:
        raise RuntimeError("Release ID 已改变，停止发行")
    return value


def find_release(repository, tag, release_id=None):
    if release_id is not None:
        value, _ = request_json(f"repos/{repository}/releases/{release_id}")
        return validate_identity(value, tag, release_id)
    value, _ = request_json(f"repos/{repository}/releases/tags/{tag}", allow_missing=True)
    if value is not None:
        validate_release(value)
        if value["tag_name"] != tag:
            raise RuntimeError("Release 标签不匹配，停止发行")
        return value
    # GitHub 的标签端点会漏掉草稿。不能把这里的 404 直接当成不存在。
    drafts = []
    for page in range(1, 101):
        releases, has_next = request_json(f"repos/{repository}/releases?per_page=100&page={page}")
        if not isinstance(releases, list):
            raise RuntimeError("Release 列表无法确认，停止发行")
        for release in releases:
            validate_release(release)
            if release["tag_name"] == tag:
                if not release["draft"]:
                    return release
                drafts.append(release)
        if has_next and not releases:
            raise RuntimeError("Release 空页仍有续页标记，停止发行")
        if not has_next:
            if len(drafts) > 1:
                raise RuntimeError("同一标签有多个草稿，停止发行")
            return drafts[0] if drafts else None
    raise RuntimeError("Release 分页超出限制，停止发行")


def release_state(repository, tag):
    value = find_release(repository, tag)
    return "absent" if value is None else "draft" if value["draft"] else "published"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository")
    parser.add_argument("tag")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--id", type=int, dest="release_id")
    selection.add_argument("--created-response", type=Path)
    parser.add_argument("--json", action="store_true", dest="json_output")
    args = parser.parse_args()
    if args.release_id is not None and args.release_id <= 0:
        parser.error("Release ID 必须为正整数")
    if args.created_response is not None:
        value = validate_identity(json.loads(args.created_response.read_text()), args.tag)
        if not value["draft"]:
            raise RuntimeError("创建响应不是草稿，停止发行")
    else:
        value = find_release(args.repository, args.tag, args.release_id)
    state = "absent" if value is None else "draft" if value["draft"] else "published"
    if args.json_output:
        if value is not None:
            validate_identity(value, args.tag, args.release_id)
        print(json.dumps({"state": state, "releaseId": None if value is None else value["id"]}))
    else:
        print(state)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as error:
        sys.exit(str(error))
