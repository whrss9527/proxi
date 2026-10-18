#!/usr/bin/env python3
"""把候选归档和两架构回执绑定到版本、源码、运行与摘要；不操作 GitHub。"""
import argparse
import hashlib
import json
from pathlib import Path
import re

# 已公开 Developer ID 发行包的团队，更新安装器要求保持同一团队。
EXPECTED_TEAM_ID = "A56J9KFVGV"

def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            result.update(chunk)
    return result.hexdigest()


def archive_names(tag):
    version = tag[1:]
    return sorted(["Proxi-macos.zip", "Proxi-macos-arm64.zip", "Proxi-macos-x86_64.zip",
                   "ProxySwitch-macos.zip", "ProxySwitch-macos-arm64.zip",
                   "ProxySwitch-macos-x86_64.zip", f"Proxi-Engine-{version}.zip"])


def validate_identity(value):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", value["tag"]):
        raise ValueError("候选标签格式不对")
    if not re.fullmatch(r"[0-9a-f]{40}", value["sourceSha"]):
        raise ValueError("候选源码提交不对")
    if not re.fullmatch(r"[A-Z0-9]{10}", value["teamId"]):
        raise ValueError("候选没有 Developer ID Team ID")
    if value["teamId"] != EXPECTED_TEAM_ID:
        raise ValueError("候选签名团队与已有发行版不同，无法一键更新")
    if not all(re.fullmatch(r"[1-9][0-9]*", value[key]) for key in ["runId", "runAttempt"]):
        raise ValueError("候选运行标识不对")


def make_candidate(directory, tag, source_sha, run_id, attempt, team_id):
    value = {"tag": tag, "sourceSha": source_sha, "runId": run_id,
             "runAttempt": attempt, "teamId": team_id}
    validate_identity(value)
    expected = archive_names(tag)
    actual = sorted(path.name for path in directory.glob("*.zip"))
    if actual != expected:
        raise ValueError("候选归档清单不完整或含额外归档")
    value["archives"] = {name: digest(directory / name) for name in expected}
    for suffix in ["", "-arm64", "-x86_64"]:
        if value["archives"][f"Proxi-macos{suffix}.zip"] != value["archives"][f"ProxySwitch-macos{suffix}.zip"]:
            raise ValueError("旧名称附件不是逐字节副本")
    return value


def check_candidate(directory, identity):
    value = json.loads((directory / "release-candidate.json").read_text())
    for key, expected in identity.items():
        if value.get(key) != expected:
            raise ValueError(f"候选 {key} 与当前运行不一致")
    rebuilt = make_candidate(directory, value["tag"], value["sourceSha"],
                             value["runId"], value["runAttempt"], value["teamId"])
    if rebuilt != value:
        raise ValueError("候选归档在验证后发生变化")
    sums = {}
    for line in (directory / "SHA256SUMS.txt").read_text().splitlines():
        checksum, name = line.split(maxsplit=1)
        name = name.lstrip("*")
        if name in sums:
            raise ValueError("摘要清单包含重复项")
        sums[name] = checksum
    if sums != value["archives"]:
        raise ValueError("SHA256SUMS 与候选归档不一致")
    return value


def check_receipts(candidate, directory):
    for architecture in ["arm64", "x86_64"]:
        receipt = json.loads((directory / f"{architecture}.json").read_text())
        if receipt != {"architecture": architecture, "candidate": candidate}:
            raise ValueError(f"{architecture} 验证回执与候选不一致")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["candidate", "check", "receipt", "publish", "remote"])
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--attempt", required=True)
    parser.add_argument("--team-id")
    parser.add_argument("--architecture", choices=["arm64", "x86_64"])
    parser.add_argument("--receipts", type=Path)
    args = parser.parse_args()
    identity = {"tag": args.tag, "sourceSha": args.source_sha,
                "runId": args.run_id, "runAttempt": args.attempt}
    if args.action == "candidate":
        value = make_candidate(args.directory, args.tag, args.source_sha,
                               args.run_id, args.attempt, args.team_id or "")
        (args.directory / "release-candidate.json").write_text(json.dumps(value, indent=2) + "\n")
    else:
        value = check_candidate(args.directory, identity)
        if args.action == "receipt":
            if args.architecture is None or args.receipts is None:
                parser.error("回执需要架构和输出目录")
            args.receipts.mkdir(parents=True, exist_ok=True)
            (args.receipts / f"{args.architecture}.json").write_text(
                json.dumps({"architecture": args.architecture, "candidate": value}, indent=2) + "\n")
        if args.action == "publish":
            if args.receipts is None:
                parser.error("公开前需要两个架构的验证回执")
            check_receipts(value, args.receipts)
        if args.action == "remote":
            if args.receipts is None:
                parser.error("需要实际下载的附件目录")
            expected = set(value["archives"]) | {"SHA256SUMS.txt"}
            if {path.name for path in args.receipts.iterdir()} != expected:
                raise ValueError("实际下载附件清单与候选不一致")
            if any(digest(args.receipts / name) != sha for name, sha in value["archives"].items()):
                raise ValueError("实际下载附件字节与候选不一致")
        print(value["teamId"])


if __name__ == "__main__":
    main()
