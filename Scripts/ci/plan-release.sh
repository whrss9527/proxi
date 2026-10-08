#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# 只认最上面一节，标题必须是「## 0.8.0（2026-09-28）」：写错了（v0.8.0、0.8.0-beta）就报错，不悄悄发错版本或者不发。
first=$(grep -m1 '^## ' CHANGELOG.md || true)
version=$(printf '%s\n' "$first" | sed -n 's/^## \([0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\)（.*/\1/p')
[ -n "$version" ] || { echo "::error::CHANGELOG.md 最上面一节的标题要写成「## 0.8.0（2026-09-28）」，现在是：${first}"; exit 1; }
# 发布过（有正式的 Release，不是草稿）才算：标签在、发布却失败了的版本下次合并时再发。
if [ "$(gh release view "v${version}" --repo "$GITHUB_REPOSITORY" --json isDraft --jq '.isDraft' 2>/dev/null || true)" = "false" ]; then
  echo "v${version} 已经发布过，这次不发版。要发版就在 CHANGELOG.md 最上面加一节新版本。"
  exit 0
fi
echo "发布 v${version}，提交 $(git rev-parse HEAD)"
echo "tag=v${version}" >> "$GITHUB_OUTPUT"
echo "sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
