#!/usr/bin/env python3
"""明确区分未发布、草稿和公开；HTTP/API 未知错误一律阻止发行。"""
import json
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


def release_state(repository, tag):
    value, _ = request_json(f"repos/{repository}/releases/tags/{tag}", allow_missing=True)
    if value is not None:
        validate_release(value)
        if value["tag_name"] != tag:
            raise RuntimeError("Release 标签不匹配，停止发行")
        return "draft" if value["draft"] else "published"
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
                    return "published"
                drafts.append(release)
        if has_next and not releases:
            raise RuntimeError("Release 空页仍有续页标记，停止发行")
        if not has_next:
            if len(drafts) > 1:
                raise RuntimeError("同一标签有多个草稿，停止发行")
            return "draft" if drafts else "absent"
    raise RuntimeError("Release 分页超出限制，停止发行")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("需要仓库和标签")
    try:
        print(release_state(sys.argv[1], sys.argv[2]))
    except (RuntimeError, ValueError) as error:
        sys.exit(str(error))
