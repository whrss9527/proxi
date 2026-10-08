#!/bin/bash
# 在独立 macOS CI 中比较已发布基线与本次产物。两次都开启系统网速、关闭窗口、禁止自动更新和代理切换。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/ci/common.sh"
require_macos_ci
baseline=${1:?需要基线 Proxi.app}
current=${2:?需要本次 Proxi.app}
settle=${SETTLE:-30}
window=${WINDOW:-60}
support="$HOME/Library/Application Support/Proxi"
mkdir -p "$support"
# 非空配置避免新手引导；仅提供无效测试配置，不开启任何代理。
cat > "$support/config.json" <<'JSON'
{"profiles":[{"id":"6D2F2A1E-0000-4000-8000-000000000099","name":"measurement fixture","color":"#16a34a","kind":"http","host":"127.0.0.1","port":1}],"speedDisplay":"system","healthCheck":false,"autoCheckUpdates":false,"automation":{"networkSwitching":false}}
JSON
printf '{}\n' > "$support/state.json"
app_pid=''
trap 'if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi' EXIT
cpu_seconds() { ps -o time= -p "$1" | awk -F: '{s=0; for(i=1;i<=NF;i++)s=s*60+$i; printf "%.3f",s}'; }
wakeups() { top -l 1 -c e -pid "$1" -stats pid,idlew 2>/dev/null | awk -v pid="$1" '$1==pid {gsub(/[^0-9]/,"",$2); print $2}' || true; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f",time'; }
measure() {
  local label=$1 bundle=$2 start end cpu_start cpu_end wake_start wake_end rss cpu wake='不可用'
  stop_app Proxi
  rm -f "$support/control.sock"
  "$bundle/Contents/MacOS/Proxi" > "$RUNNER_TEMP/footprint-$label.log" 2>&1 &
  app_pid=$!
  wait_json "$bundle/Contents/MacOS/Proxi" '.interface.settingsVisible == false and .interface.panelVisible == false'
  sleep "$settle"
  kill -0 "$app_pid"
  wake_start=$(wakeups "$app_pid")
  start=$(now); cpu_start=$(cpu_seconds "$app_pid")
  sleep "$window"
  cpu_end=$(cpu_seconds "$app_pid"); end=$(now)
  wake_end=$(wakeups "$app_pid"); rss=$(ps -o rss= -p "$app_pid")
  kill -0 "$app_pid"
  cpu=$(awk -v a="$cpu_start" -v b="$cpu_end" -v s="$start" -v e="$end" 'BEGIN{printf "%.3f",100*(b-a)/(e-s)}')
  if [[ -n "$wake_start" && -n "$wake_end" ]]; then
    wake=$(awk -v a="$wake_start" -v b="$wake_end" -v s="$start" -v e="$end" 'BEGIN{printf "%.2f",(b-a)/(e-s)}')
  fi
  rss=$(awk -v k="$rss" 'BEGIN{printf "%.1f",k/1024}')
  printf '| %s | %s %% | %s | %s MB |\n' "$label" "$cpu" "$wake" "$rss" | tee -a "$RUNNER_TEMP/footprint.log"
  stop_app Proxi; wait "$app_pid" || true; app_pid=''
}
printf '| 版本 | CPU（单核） | 空闲唤醒 / 秒 | RSS |\n| --- | --- | --- | --- |\n' > "$RUNNER_TEMP/footprint.log"
measure before "$baseline"
measure after "$current"
cat "$RUNNER_TEMP/footprint.log"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  printf '### Proxi 网速显示常驻开销\n\n同一 runner 顺序测量，各稳定 %s 秒后测 %s 秒；系统后台流量和噪声会影响数值。未修改 #29 的计时器容差。\n\n' "$settle" "$window" >> "$GITHUB_STEP_SUMMARY"
  cat "$RUNNER_TEMP/footprint.log" >> "$GITHUB_STEP_SUMMARY"
fi
