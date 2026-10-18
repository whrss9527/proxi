#!/bin/bash
# 所有发行 App 共同提交一次公证；最终 ZIP 重新解包验证成功，才替换原归档。
#   Scripts/notarize.sh dist/Proxi-macos.zip dist/Proxi-macos-arm64.zip …
set -euo pipefail
# shellcheck source=Scripts/ci/notary-common.sh
source "$(dirname "$0")/ci/notary-common.sh"
[ $# -gt 0 ] || { echo "用法：Scripts/notarize.sh 文件.zip …"; exit 1; }
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/proxi-notary.XXXXXX")
trap 'rm -f "$work/AuthKey.p8"' EXIT

auth=()
if [ -n "${NOTARY_KEY_P8:-}" ]; then
  key="$work/AuthKey.p8"
  if printf '%s' "$NOTARY_KEY_P8" | grep -q "BEGIN PRIVATE KEY"; then
    printf '%s\n' "$NOTARY_KEY_P8" > "$key"
  else
    printf '%s' "$NOTARY_KEY_P8" | tr -d ' \r\n\t' | base64 --decode > "$key"
  fi
  chmod 600 "$key"
  auth=(--key "$key" --key-id "${NOTARY_KEY_ID:?没有设置 NOTARY_KEY_ID}")
  if [ -n "${NOTARY_ISSUER_ID:-}" ]; then auth+=(--issuer "$NOTARY_ISSUER_ID"); fi
elif [ -n "${NOTARY_APPLE_ID:-}" ]; then
  auth=(--apple-id "$NOTARY_APPLE_ID" --password "${NOTARY_PASSWORD:?没有设置 NOTARY_PASSWORD}"
        --team-id "${NOTARY_TEAM_ID:?没有设置 NOTARY_TEAM_ID}")
else
  echo "没有公证凭据：设置 NOTARY_KEY_P8 + NOTARY_KEY_ID（+ NOTARY_ISSUER_ID），或者 NOTARY_APPLE_ID + NOTARY_PASSWORD + NOTARY_TEAM_ID"
  exit 1
fi
json_field() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null || true
}
archives=() apps=() names=()
mkdir -p "$work/submission" "$work/staged"
i=0
for zip in "$@"; do
  [ -f "$zip" ] || { echo "找不到 $zip"; exit 1; }
  archive="$(cd "$(dirname "$zip")" && pwd)/$(basename "$zip")"
  for previous in "${archives[@]+${archives[@]}}"; do
    [ "$previous" != "$archive" ] || { echo "归档重复：$archive"; exit 1; }
  done
  archives+=("$archive")
  names+=("$(basename "$archive")")
  dir="$work/submission/$i"
  mkdir -p "$dir"
  ditto -x -k "$archive" "$dir"
  found=()
  while IFS= read -r app; do found+=("$app"); done < <(find "$dir" -maxdepth 1 -type d -name '*.app')
  [ "${#found[@]}" -eq 1 ] || { echo "$archive 必须只含一个顶层 .app"; exit 1; }
  codesign --verify --deep --strict --all-architectures "${found[0]}"
  apps+=("${found[0]}")
  i=$((i + 1))
done
# 编号目录保留原 App 名称，共同提交覆盖通用、精简和扩展的全部签名。
ditto -c -k --keepParent "$work/submission" "$work/submission.zip"
echo "共同提交 ${#apps[@]} 个发行 App"
if ! xcrun notarytool submit "$work/submission.zip" "${auth[@]}" --output-format json > "$work/submit.json"; then
  cat "$work/submit.json" || true
  echo "共同公证提交失败"; exit 1
fi
id=$(json_field "$work/submit.json" id)
[ -n "$id" ] || { cat "$work/submit.json"; echo "没拿到提交编号"; exit 1; }
echo "提交编号 $id"
wait_result=0
xcrun notarytool wait "$id" "${auth[@]}" --timeout 20m --output-format json > "$work/wait.json" || wait_result=$?
status=$(json_field "$work/wait.json" status)
echo "共同公证结果 ${status:-未知}"
if [ "$wait_result" -ne 0 ] || [ "$status" != "Accepted" ]; then
  cat "$work/wait.json" || true
  xcrun notarytool log "$id" "${auth[@]}" || true
  exit 1
fi
for i in "${!apps[@]}"; do
  app="${apps[$i]}"
  stapler_with_retry staple "$app"
  mkdir -p "$work/staged/$i"
  staged="$work/staged/$i/${names[$i]}"
  ditto -c -k --keepParent "$app" "$staged"
  # 验证准备发布的 ZIP 内容，不以钉票据工作目录代替。
  final="$work/final/$i"
  mkdir -p "$final"
  ditto -x -k "$staged" "$final"
  verify_notarized_app "$final/$(basename "$app")"
  echo "${names[$i]}：最终 ZIP 的签名、票据和 Gatekeeper 验证通过"
done
# 整组失败时保留所有原归档，不留下部分已晋级的发行包。
for i in "${!archives[@]}"; do mv "$work/staged/$i/${names[$i]}" "${archives[$i]}"; done
echo "共同公证完成，诊断保存在 $work"
