#!/bin/bash
# 两种芯片下载同一候选附件，验证通用包、本机精简包与可选扩展。
set -euo pipefail
# shellcheck source=Scripts/ci/notary-common.sh
source "$(dirname "$0")/notary-common.sh"
directory="${1:?需要候选附件目录}"
version="${2:?需要版本号}"
expected="${3:?需要本机架构}"
[ "$(uname -m)" = "$expected" ] || { echo "runner 架构与门禁不一致"; exit 1; }
directory="$(cd "$directory" && pwd)"
integrity="$(dirname "$0")/release-integrity.py"
identity=(--directory "$directory" --tag "v$version" --source-sha "${RELEASE_SOURCE_SHA:?}"
          --run-id "${GITHUB_RUN_ID:?}" --attempt "${GITHUB_RUN_ATTEMPT:?}")
team=$(python3 "$integrity" check "${identity[@]}")
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/proxi-release-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT
for name in Proxi-macos.zip "Proxi-macos-${expected}.zip" "Proxi-Engine-${version}.zip"; do
  target="$work/${name%.zip}"
  mkdir -p "$target"
  ditto -x -k "$directory/$name" "$target"
  apps=()
  while IFS= read -r app; do apps+=("$app"); done < <(find "$target" -maxdepth 1 -type d -name '*.app')
  [ "${#apps[@]}" -eq 1 ] || { echo "$name 必须只含一个顶层 .app"; exit 1; }
  app="${apps[0]}"
  actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
  [ "$actual_version" = "$version" ] || { echo "$name 的版本不对：$actual_version"; exit 1; }
  identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
  if [[ "$name" == Proxi-Engine-* ]]; then expected_id=com.whrss9527.proxyswitch.engine; else expected_id=com.whrss9527.proxyswitch; fi
  [ "$identifier" = "$expected_id" ] || { echo "$name 的程序标识不对"; exit 1; }
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
  archs=$(lipo -archs "$app/Contents/MacOS/$executable")
  if [ "$name" = "Proxi-macos-${expected}.zip" ]; then
    [ "$archs" = "$expected" ] || { echo "精简包架构不对：$archs"; exit 1; }
  else
    [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || { echo "$name 不是通用包"; exit 1; }
  fi
  info=$(codesign -dvv "$app" 2>&1)
  grep -q "^TeamIdentifier=$team$" <<< "$info" || { echo "$name 的签名团队不对"; exit 1; }
  grep -q '^Authority=Developer ID Application:' <<< "$info" || { echo "$name 没有 Developer ID 签名"; exit 1; }
  grep -q 'flags=.*runtime' <<< "$info" || { echo "$name 没有 hardened runtime"; exit 1; }
  grep -q '^Timestamp=' <<< "$info" || { echo "$name 没有安全时间戳"; exit 1; }
  # 保留真实下载的隔离语义；不移除 quarantine，也不禁用 Gatekeeper。
  xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Proxi release verification;" "$app"
  verify_notarized_app "$app"
  echo "$expected 下载验证通过：$name"
done
# 回执只能在所有原生验证通过之后写出，绑定本次源码、归档摘要和运行编号。
python3 "$integrity" receipt "${identity[@]}" --architecture "$expected" --receipts "${RELEASE_RECEIPTS_DIR:?}"
