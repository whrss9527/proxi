#!/bin/bash
# 公证查询只对 CloudKit 错误 68 有限重试，签名和 Gatekeeper 失败不能放行。
stapler_with_retry() {
  local action="$1" app="$2" attempt result
  for attempt in 1 2 3; do
    if xcrun stapler "$action" "$app"; then return 0; else result=$?; fi
    [ "$result" -eq 68 ] && [ "$attempt" -lt 3 ] || return "$result"
    echo "票据 ${action} 网络查询未完成，5 秒后重试（${attempt}/3）"
    sleep 5
  done
}

verify_notarized_app() {
  local app="$1" attempt assessment policy
  codesign --verify --deep --strict --all-architectures "$app" || return $?
  stapler_with_retry validate "$app" || return $?
  policy=$(spctl --status 2>&1) || return $?
  [ "$policy" = "assessments enabled" ] || { echo "::error::Gatekeeper 状态未知或未启用，禁止发布"; return 1; }
  for attempt in $(seq 1 "${SPCTL_TRIES:-6}"); do
    if assessment=$(spctl --assess --type execute --verbose=2 "$app" 2>&1); then
      printf '%s\n' "$assessment"
      # 成功退出但来源未知，也不能晋级正式发行包。
      if grep -q '^source=Notarized Developer ID$' <<< "$assessment" && ! grep -qi 'override\|security disabled' <<< "$assessment"; then return 0; fi
    else
      printf '%s\n' "$assessment"
    fi
    if [ "$attempt" -lt "${SPCTL_TRIES:-6}" ]; then
      echo "第 ${attempt} 次 Gatekeeper 检查未通过，${SPCTL_INTERVAL:-10} 秒后重试"
      sleep "${SPCTL_INTERVAL:-10}"
    fi
  done
  echo "::error::Gatekeeper 未确认公证，禁止发布：${app}"
  codesign -dvvv "$app" 2>&1 || true
  if command -v syspolicy_check >/dev/null; then syspolicy_check distribution "$app" 2>&1 || true; fi
  return 1
}
