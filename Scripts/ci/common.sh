#!/bin/bash
# 所有轮询都有截止时间；失败时直接失败，不把超时当成测试通过。
wait_for() {
  local seconds=$1 label=$2
  shift 2
  local deadline=$((SECONDS + seconds))
  while ! "$@"; do
    if ((SECONDS >= deadline)); then
      printf '::error::等待超时：%s（%s 秒）\n' "$label" "$seconds" >&2
      return 1
    fi
    sleep 0.25
  done
}

require_macos_ci() {
  if [[ $(uname -s) != Darwin ]] || [[ ${GITHUB_ACTIONS:-} != true && ${PROXI_CI_ALLOW_GUI:-} != 1 ]]; then
    printf '%s\n' '这项检查会启动应用并改变测试机器的设置；只在 macOS CI 或显式设置 PROXI_CI_ALLOW_GUI=1 的专用测试账户中运行。' >&2
    return 1
  fi
  : "${RUNNER_TEMP:?需要独立的测试临时目录}"
}

mark_pass() { touch "$RUNNER_TEMP/ci-$1.passed"; }
not_running() { ! pgrep -x "$1" >/dev/null; }
stop_app() {
  pkill -x "$1" || true
  wait_for 30 "$1 退出" not_running "$1"
}
json_match() {
  local binary=$1 query=$2 result
  # CLI 会在程序未运行时启动 GUI；等待启动期间只询问已存在的实例。
  pgrep -x "$(basename "$binary")" >/dev/null || return 1
  result=$(python3 Scripts/ci/read-status.py "$binary") || return 1
  printf '%s\n' "$result" > "$RUNNER_TEMP/status-last.json"
  printf '%s\n' "$result" | jq -e "$query" >/dev/null
}
wait_json() {
  local binary=$1 query=$2 timeout=${3:-30}
  wait_for "$timeout" "状态：$query" json_match "$binary" "$query"
}
show_settings() {
  local page=$1 binary=${2:-dist/Proxi.app/Contents/MacOS/Proxi}
  open "proxi://settings?page=$page"
  wait_json "$binary" ".interface.settingsVisible == true and .interface.settingsPage == \"$page\""
}
show_panel() {
  local binary=${1:-dist/Proxi.app/Contents/MacOS/Proxi}
  open 'proxi://panel'
  wait_json "$binary" '.interface.visibleWindows > 0'
}
file_contains() { grep -q -- "$2" "$1"; }
file_not_contains() { ! grep -q -- "$2" "$1"; }
proxy_matches() { [[ $(git config --global --includes --get http.proxy || true) == "$1" ]]; }
forwarding_matches() { [[ $(sysctl -n net.inet.ip.forwarding) == "$1" ]]; }
has_tun() { ifconfig | grep -q 'inet 198\.18\.'; }
no_tun() { ! has_tun; }
fixture_server() {
  local port=$1 directory=$2
  python3 Scripts/ci/fixture-server.py --port "$port" --directory "$directory" --requests "$RUNNER_TEMP/fixture-requests-$port.jsonl" > "$RUNNER_TEMP/fixture-$port.log" 2>&1 &
  echo "$!" > "$RUNNER_TEMP/fixture-$port.pid"
}
fixture_requested() {
  local port=$1 path=$2
  [[ -f "$RUNNER_TEMP/fixture-requests-$port.jsonl" ]] || return 1
  jq -e -s --arg path "$path" 'any(.[]; .path == $path and .status == 200)' "$RUNNER_TEMP/fixture-requests-$port.jsonl" >/dev/null
}
file_json_match() { [[ -f "$1" ]] && jq -e "$2" "$1" >/dev/null; }
assert_for() {
  local seconds=$1 label=$2
  shift 2
  local deadline=$((SECONDS + seconds))
  while ((SECONDS < deadline)); do
    "$@" || { printf '::error::观察期间条件失效：%s\n' "$label" >&2; return 1; }
    sleep 0.25
  done
}
