#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
state=$(gh pr view "$PR" --repo "$GITHUB_REPOSITORY" --json state,headRefOid --jq '.state + " " + .headRefOid')
if [ "$state" != "OPEN $HEAD_SHA" ]; then
  echo "合并请求已经关闭，或者又有了新的提交（现在是 ${state}），交给新的那次测试。"
  exit 0
fi
# 测的是「分支合进当时的 main」的结果；main 之后又有了新提交，合并出来的东西就没测过，不合。
tested_base=$(gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA" --jq '.parents[0].sha')
current_base=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$BASE" --jq '.object.sha')
if [ "$tested_base" != "$current_base" ]; then
  echo "::error::测试之后 ${BASE} 又有了新提交（测的是 ${tested_base}，现在是 ${current_base}），没有合并。把 ${BASE} 合进分支再推一次，会重新测试并自动合并。"
  exit 1
fi
# 压成一个提交合进去，main 保持线性；仓库不允许压缩合并时退回普通合并。
if ! gh pr merge "$PR" --repo "$GITHUB_REPOSITORY" --squash --match-head-commit "$HEAD_SHA"; then
  gh pr merge "$PR" --repo "$GITHUB_REPOSITORY" --merge --match-head-commit "$HEAD_SHA"
fi
sha=$(gh pr view "$PR" --repo "$GITHUB_REPOSITORY" --json mergeCommit --jq '.mergeCommit.oid')
[ -n "$sha" ] || { echo "::error::合并后没拿到合并提交"; exit 1; }
echo "已合并：$sha"
echo "sha=$sha" >> "$GITHUB_OUTPUT"
