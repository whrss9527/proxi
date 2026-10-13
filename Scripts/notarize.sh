#!/bin/bash
# 把签好名的 zip 提交苹果公证，通过后把公证票据钉（staple）到 .app 上，再重新打成同名的 zip。
# 钉上票据后，用户第一次打开时就算没联网，系统也能确认它经过了公证。
#   Scripts/notarize.sh dist/Proxi-macos.zip dist/Proxi-macos-arm64.zip …
# 凭据二选一（发布流程从 GitHub Secrets 传进来，见 docs/signing.md）：
#   App Store Connect API 密钥：NOTARY_KEY_P8（.p8 文件的内容，或者它的 base64）、NOTARY_KEY_ID、NOTARY_ISSUER_ID（个人密钥不填）
#   Apple ID：NOTARY_APPLE_ID、NOTARY_PASSWORD（App 专用密码）、NOTARY_TEAM_ID
set -euo pipefail

[ $# -gt 0 ] || { echo "用法：Scripts/notarize.sh 文件.zip …"; exit 1; }
work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/proxi-notary"
rm -rf "$work" && mkdir -p "$work"
trap 'rm -f "$work/AuthKey.p8"' EXIT

auth=()
if [ -n "${NOTARY_KEY_P8:-}" ]; then
  key="$work/AuthKey.p8"
  if printf '%s' "$NOTARY_KEY_P8" | grep -q "BEGIN PRIVATE KEY"; then
    printf '%s\n' "$NOTARY_KEY_P8" > "$key"
  else
    printf '%s' "$NOTARY_KEY_P8" | tr -d ' \r\n\t' | base64 --decode > "$key"
  fi
  auth=(--key "$key" --key-id "${NOTARY_KEY_ID:?没有设置 NOTARY_KEY_ID}")
  if [ -n "${NOTARY_ISSUER_ID:-}" ]; then
    auth+=(--issuer "$NOTARY_ISSUER_ID")
  fi
elif [ -n "${NOTARY_APPLE_ID:-}" ]; then
  auth=(--apple-id "$NOTARY_APPLE_ID"
        --password "${NOTARY_PASSWORD:?没有设置 NOTARY_PASSWORD（App 专用密码）}"
        --team-id "${NOTARY_TEAM_ID:?没有设置 NOTARY_TEAM_ID}")
else
  echo "没有公证凭据：设置 NOTARY_KEY_P8 + NOTARY_KEY_ID（+ NOTARY_ISSUER_ID），或者 NOTARY_APPLE_ID + NOTARY_PASSWORD + NOTARY_TEAM_ID"
  exit 1
fi

# notarytool --output-format json 的输出里取一个字段。
json_field() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null || true
}

# CloudKit 取票据/校验偶尔断开（stapler 68）；只重试该错误，其他失败原样返回。
stapler_with_retry() {
  local action="$1" app="$2" attempt result
  for attempt in 1 2 3; do
    if xcrun stapler "$action" "$app"; then
      return 0
    else
      result=$?
    fi
    [ "$result" -eq 68 ] && [ "$attempt" -lt 3 ] || return "$result"
    echo "票据 ${action} 网络查询未完成，5 秒后重试（${attempt}/3）"
    sleep 5
  done
}

# 先把所有包都传上去（苹果那边同时处理），再逐个等结果。
ids=()
for zip in "$@"; do
  [ -f "$zip" ] || { echo "找不到 $zip"; exit 1; }
  name="$(basename "$zip")"
  out="$work/submit-$name.json"
  echo "上传 $name 提交公证"
  if ! xcrun notarytool submit "$zip" "${auth[@]}" --output-format json > "$out"; then
    cat "$out" || true
    echo "提交失败：$name"
    exit 1
  fi
  id="$(json_field "$out" id)"
  [ -n "$id" ] || { cat "$out"; echo "没拿到提交编号：$name"; exit 1; }
  echo "  提交编号 $id"
  ids+=("$id")
done

i=0
for zip in "$@"; do
  id="${ids[$i]}"
  i=$((i + 1))
  name="$(basename "$zip")"
  out="$work/wait-$name.json"
  xcrun notarytool wait "$id" "${auth[@]}" --output-format json > "$out" || true
  status="$(json_field "$out" status)"
  echo "${name}：公证结果 ${status:-未知}"
  if [ "$status" != "Accepted" ]; then
    cat "$out" || true
    echo "===== 公证日志（为什么没通过） ====="
    xcrun notarytool log "$id" "${auth[@]}" || true
    exit 1
  fi
  # 解压、钉票据、确认系统认可，再压回原来的文件。
  dir="$work/staple-${name%.zip}"
  rm -rf "$dir" && mkdir -p "$dir"
  ditto -x -k "$zip" "$dir"
  # 包里的程序：Proxi.app，或者可选扩展的 Proxi Engine.app。
  app="$(find "$dir" -maxdepth 1 -name '*.app' | head -1)"
  [ -n "$app" ] || { echo "$name 里没有 .app"; exit 1; }
  stapler_with_retry staple "$app"
  stapler_with_retry validate "$app"
  # 刚钉上票据时系统可能还认不出来，隔几秒多试几次（次数和间隔可以用 SPCTL_TRIES、SPCTL_INTERVAL 改，CI 自测用）。
  assessed=0
  tries="${SPCTL_TRIES:-6}"
  interval="${SPCTL_INTERVAL:-10}"
  for attempt in $(seq 1 "$tries"); do
    if spctl --assess --type execute --verbose=2 "$app"; then
      assessed=1
      break
    fi
    echo "  第 $attempt 次检查没通过，${interval} 秒后再试"
    sleep "$interval"
  done
  if [ "$assessed" != 1 ]; then
    echo "===== 系统检查没通过，详细信息 ====="
    assessment="$(spctl --assess --type execute -vvv "$app" 2>&1 || true)"
    echo "$assessment"
    codesign -dvvv "$app" 2>&1 || true
    if command -v syspolicy_check >/dev/null; then
      syspolicy_check distribution "$app" 2>&1 || true
    fi
    # 苹果已经通过公证（上面是 Accepted）、票据钉上并核对过、签名完整，只有这台机器的系统检查说「没公证」：
    # 发布用的 macOS 机器上有时这样（0.14.0、0.14.2 都遇到过，同一个镜像别的时候又正常），不拦发布，记一条警告。
    # 别的原因（签名坏了、证书被吊销、票据核对不过……）照样失败。
    if grep -q "source=Unnotarized Developer ID" <<< "$assessment" \
       && codesign --verify --deep --strict "$app" 2>/dev/null \
       && stapler_with_retry validate "$app" >/dev/null 2>&1; then
      echo "::warning::${name}：公证已通过、票据已钉上，但这台机器的系统检查仍说没有公证，照常发布"
    else
      codesign --verify --deep --strict --verbose=2 "$app" 2>&1 || true
      xcrun stapler validate -v "$app" 2>&1 || true
      xcrun notarytool log "$id" "${auth[@]}" || true
      exit 1
    fi
  fi
  target="$(cd "$(dirname "$zip")" && pwd)/$name"
  rm -f "$target"
  (cd "$dir" && ditto -c -k --keepParent "$(basename "$app")" "$target")
  echo "${name}：已钉上公证票据"
done
