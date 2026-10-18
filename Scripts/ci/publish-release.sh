#!/bin/bash
# 只上传已经通过两架构门禁的固定附件，不重建、重签或覆盖公开版本。
set -euo pipefail
directory="${1:?需要候选目录}"
receipts="${2:?需要回执目录}"
python3 "$(dirname "$0")/release-integrity.py" publish --directory "$directory" --receipts "$receipts" \
  --tag "${TAG:?}" --source-sha "${RELEASE_SOURCE_SHA:?}" --run-id "${GITHUB_RUN_ID:?}" --attempt "${GITHUB_RUN_ATTEMPT:?}"
[ "$(git rev-parse HEAD)" = "$RELEASE_SOURCE_SHA" ] || { echo "源码与候选不一致"; exit 1; }
state_tool="$(dirname "$0")/release-state.py"
lookup=$(python3 "$state_tool" "${GITHUB_REPOSITORY:?}" "$TAG" --json)
state=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' <<< "$lookup")
release_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["releaseId"] or "")' <<< "$lookup")
if [ "$state" = "published" ]; then
  echo "::error::$TAG 已公开，禁止覆盖"; exit 1
fi
version="${TAG#v}"
awk -v header="## ${version}（" '/^## /{if (printing) exit; if (index($0,header)==1) {printing=1;next}} printing' CHANGELOG.md > notes.md
[ -s notes.md ] || { echo "CHANGELOG.md 中没有候选版本"; exit 1; }
if grep -qiE '代理引擎|Proxi-Engine|mihomo|内核|机场|翻墙|科学上网|GFW|VPN|netflix|youtube|chatgpt|telegram|流媒体' notes.md; then
  echo "发布说明含不应公开的文字"; exit 1
fi
printf '\n已用 Developer ID 签名并通过苹果公证，Intel 与 Apple 芯片均通过最终附件安装门禁。\n' >> notes.md
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  git fetch --depth=1 origin "refs/tags/$TAG:refs/tags/$TAG"
  [ "$(git rev-parse "$TAG^{commit}")" = "$RELEASE_SOURCE_SHA" ] || { echo "标签已改变"; exit 1; }
else
  git tag "$TAG" "$RELEASE_SOURCE_SHA"
  git push origin "refs/tags/$TAG"
fi
if [ "$state" = "absent" ]; then
  work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/proxi-draft.XXXXXX")
  python3 - "$TAG" "$RELEASE_SOURCE_SHA" notes.md "$work/payload.json" <<'PYLOAD'
import json
from pathlib import Path
import sys
tag, source, notes, output = sys.argv[1:]
Path(output).write_text(json.dumps({"tag_name": tag, "target_commitish": source, "name": "Proxi " + tag,
    "body": Path(notes).read_text(), "draft": True}))
PYLOAD
  # 创建响应绑定真实 ID，不重新依赖 tags/list 索引发现刚创建的草稿。
  gh api --method POST "repos/$GITHUB_REPOSITORY/releases" --input "$work/payload.json" > "$work/created.json"
  created=$(python3 "$state_tool" "$GITHUB_REPOSITORY" "$TAG" --created-response "$work/created.json" --json)
  release_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["releaseId"])' <<< "$created")
  rm -rf "$work"
fi
# 同时确认状态与 CLI 解析到的对象，避免按标签传输时指向另一个 Release。
confirm_writable_draft() {
  local cli_view
  [ "$(python3 "$state_tool" "$GITHUB_REPOSITORY" "$TAG" --id "$release_id")" = "draft" ] || { echo "::error::无法确认可写草稿"; return 1; }
  cli_view=$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json apiUrl,isDraft,tagName)
  python3 - "$GITHUB_REPOSITORY" "$TAG" "$release_id" "$cli_view" <<'PYIDENTITY'
import json
import sys
repository, tag, release_id, response = sys.argv[1:]
value = json.loads(response)
if not isinstance(value, dict) or value.get("apiUrl") != f"https://api.github.com/repos/{repository}/releases/{release_id}" or value.get("tagName") != tag or value.get("isDraft") is not True:
    sys.exit("GitHub CLI 草稿与绑定的 Release ID 不一致，停止发行")
PYIDENTITY
}
confirm_writable_draft
gh release upload "$TAG" --repo "$GITHUB_REPOSITORY" "$directory"/*.zip "$directory/SHA256SUMS.txt" --clobber
# 核对实际 GitHub 下载的草稿附件与 canonical 摘要一致，再把草稿公开。
downloaded=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/proxi-published.XXXXXX")
trap 'rm -rf "$downloaded"' EXIT
gh release download "$TAG" --repo "$GITHUB_REPOSITORY" --dir "$downloaded"
(cd "$downloaded" && sha256sum -c SHA256SUMS.txt)
cmp "$directory/SHA256SUMS.txt" "$downloaded/SHA256SUMS.txt"
python3 "$(dirname "$0")/release-integrity.py" remote --directory "$directory" --receipts "$downloaded" \
  --tag "$TAG" --source-sha "$RELEASE_SOURCE_SHA" --run-id "$GITHUB_RUN_ID" --attempt "$GITHUB_RUN_ATTEMPT"
newest=$(gh release list --repo "$GITHUB_REPOSITORY" --exclude-drafts --limit 100 --json tagName --jq '.[].tagName' | { cat; echo "$TAG"; } | sort -V | tail -1)
confirm_writable_draft
if [ "$newest" = "$TAG" ]; then gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --draft=false --latest; else gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --draft=false --latest=false; fi
[ "$(python3 "$state_tool" "$GITHUB_REPOSITORY" "$TAG" --id "$release_id")" = "published" ] || { echo "::error::无法确认公开结果"; exit 1; }
echo "已公开 https://github.com/${GITHUB_REPOSITORY}/releases/tag/$TAG"
