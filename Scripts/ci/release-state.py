#!/usr/bin/env python3
"""明确区分未发布、草稿和公开；HTTP/API 未知错误一律阻止发行。"""
import json
import re
import subprocess
import sys


def release_state(repository, tag):
    result = subprocess.run(["gh", "api", "--include", "--method", "GET",
                             f"repos/{repository}/releases/tags/{tag}"],
                            capture_output=True, text=True)
    response = result.stdout.replace("\r\n", "\n")
    header, separator, body = response.partition("\n\n")
    match = re.match(r"HTTP/\S+\s+(\d{3})\b", header)
    status = int(match[1]) if match else None
    if status == 404 and result.returncode != 0:
        return "absent"
    if status != 200 or result.returncode != 0 or not separator:
        raise RuntimeError(f"无法确认 Release 状态（HTTP {status or '未知'}），停止发行")
    value = json.loads(body)
    if value.get("tag_name") != tag or type(value.get("draft")) is not bool:
        raise RuntimeError("Release 状态或标签无法确认，停止发行")
    return "draft" if value["draft"] else "published"


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("需要仓库和标签")
    try:
        print(release_state(sys.argv[1], sys.argv[2]))
    except (RuntimeError, ValueError) as error:
        sys.exit(str(error))
