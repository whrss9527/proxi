#!/bin/bash
# 同一个专用 macOS runner、同一种 Release 构建，顺序比较 main 基线与修复版本。
set -euo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
: "${CI_BASE_SHA:?需要 PR 基线（main 推送使用上一提交）}"
exec > >(tee "$RUNNER_TEMP/idle-power.log") 2>&1
baseline_dir=$(mktemp -d "$RUNNER_TEMP/power-base.XXXXXX")
app_pid=''
cleanup() {
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; wait "$app_pid" || true; fi
  rm -rf "$baseline_dir"
}
trap cleanup EXIT
git fetch --no-tags origin "$CI_BASE_SHA"
git archive "$CI_BASE_SHA" | tar -x -C "$baseline_dir"
if ! (cd "$baseline_dir" && VERSION=0.0.0 ARCHS="" Scripts/build-app.sh) > "$RUNNER_TEMP/power-base-build.log" 2>&1; then
  tail -60 "$RUNNER_TEMP/power-base-build.log"
  exit 1
fi

settle=${SETTLE:-30}
window=${WINDOW:-60}
support="$HOME/Library/Application Support/Proxi"
export PROXI_ENGINE_DIR="$RUNNER_TEMP/power-engine"
mkdir -p "$support" "$PROXI_ENGINE_DIR"
cpu_seconds() { ps -o time= -p "$1" | awk -F: '{s=0; for(i=1;i<=NF;i++)s=s*60+$i; printf "%.3f",s}'; }
wakeups() { top -l 1 -c e -pid "$1" -stats pid,idlew 2>/dev/null | awk -v pid="$1" '$1==pid {gsub(/[^0-9]/,"",$2); print $2}' || true; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f",time'; }
printf '| 场景 | 版本 | CPU（单核） | 空闲唤醒 / 秒 | RSS（MB） |\n| --- | --- | --- | --- | --- |\n' > "$RUNNER_TEMP/footprint.log"

measure() {
  local scenario=$1 label=$2 bundle=$3 name=Proxi identifier=com.whrss9527.proxyswitch
  local start end cpu_start cpu_end wake_start wake_end rss cpu wake=unavailable
  stop_app Proxi
  stop_app ProxiEngine
  # 只在专用 CI 账户中替换测试配置；不启用代理、不自动更新、不联网同步。
  printf '{"profiles":[{"name":"measurement fixture","host":"127.0.0.1","port":1}],"speedDisplay":"%s","healthCheck":true,"autoCheckUpdates":false,"automation":{"networkSwitching":false}}\n' "$scenario" > "$support/config.json"
  printf '{}\n' > "$support/state.json"
  printf '{"autoCheckUpdates":false,"engine":{"enabled":false}}\n' > "$PROXI_ENGINE_DIR/config.json"
  printf '{}\n' > "$PROXI_ENGINE_DIR/state.json"
  if [[ "$scenario" == engine ]]; then name=ProxiEngine; identifier+=.engine; fi
  local binary="$bundle/Contents/MacOS/$name"
  "$binary" > "$RUNNER_TEMP/power-$scenario-$label.log" 2>&1 &
  app_pid=$!
  wait_json "$binary" '.proxy.state == "off"'
  sleep "$settle"
  kill -0 "$app_pid"
  if dist/ci-window-ready "$identifier"; then
    printf '::error::测量时出现了窗口（%s / %s）\n' "$scenario" "$label"
    exit 1
  fi
  if pgrep -x nettop >/dev/null; then
    echo '::error::空闲时不应启动逐应用网络采样'
    exit 1
  fi
  wake_start=$(wakeups "$app_pid")
  start=$(now)
  cpu_start=$(cpu_seconds "$app_pid")
  sleep "$window"
  cpu_end=$(cpu_seconds "$app_pid")
  end=$(now)
  wake_end=$(wakeups "$app_pid")
  rss=$(ps -o rss= -p "$app_pid")
  kill -0 "$app_pid"
  cpu=$(awk -v a="$cpu_start" -v b="$cpu_end" -v s="$start" -v e="$end" 'BEGIN{printf "%.3f",100*(b-a)/(e-s)}')
  if [[ -n "$wake_start" && -n "$wake_end" && "$wake_end" -ge "$wake_start" ]]; then
    wake=$(awk -v a="$wake_start" -v b="$wake_end" -v s="$start" -v e="$end" 'BEGIN{printf "%.2f",(b-a)/(e-s)}')
  fi
  rss=$(awk -v k="$rss" 'BEGIN{printf "%.1f",k/1024}')
  printf '| %s | %s | %s %% | %s | %s |\n' "$scenario" "$label" "$cpu" "$wake" "$rss" | tee -a "$RUNNER_TEMP/footprint.log"
  printf '::notice title=空闲开销::%s / %s: CPU=%s%%, wakeups/s=%s, RSS=%s MB\n' "$scenario" "$label" "$cpu" "$wake" "$rss"
  if [[ "$label" == after ]]; then
    if awk -v c="$cpu" -v r="$rss" -v w="$wake" 'BEGIN{exit !(c>1 || r>200 || (w!="unavailable" && w>8))}'; then
      echo '::error::空闲开销超过预算：单核 CPU 1%、RSS 200 MB、每秒唤醒 8 次'
      exit 1
    fi
  fi
  stop_app "$name"
  wait "$app_pid" || true
  app_pid=''
}
for scenario in none system engine; do
  bundle=Proxi.app
  if [[ "$scenario" == engine ]]; then bundle='Proxi Engine.app'; fi
  measure "$scenario" before "$baseline_dir/dist/$bundle"
  measure "$scenario" after "dist/$bundle"
done
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  printf '### 空闲性能对比\n\n同一 runner 的 Release 构建；各稳定 %s 秒后测 %s 秒。系统后台流量会影响网速和 CPU，数据不能等同于电池续航。基线：%s。\n\n' "$settle" "$window" "$CI_BASE_SHA" >> "$GITHUB_STEP_SUMMARY"
  cat "$RUNNER_TEMP/footprint.log" >> "$GITHUB_STEP_SUMMARY"
fi
mark_pass idle-power
