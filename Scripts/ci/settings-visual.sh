#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
exec > >(tee "$RUNNER_TEMP/settings-visual.log") 2>&1
mkdir -p screenshots
# 此脚本只在专用测试账户中启动这两个进程；成功和失败都清理。
trap 'pkill -x Proxi || true; pkill -x ProxiEngine || true' EXIT
case "${PROXI_TEST_APPEARANCE:-dark}" in
  dark) dark_mode=true ;;
  light) dark_mode=false ;;
  *) printf '%s\n' '未知测试外观' >&2; exit 1 ;;
esac
osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $dark_mode"
support="$HOME/Library/Application Support/Proxi"
mkdir -p "$support/Extensions"
cp -R 'dist/Proxi Engine.app' "$support/Extensions/"
printf '%s' '{"extension":{"enabled":true,"acceptedVersion":1}}' > "$support/state.json"
# 独立 runner 中直接安装本次构建的扩展，不访问发布或启动任何代理配置。
PROXI_TEST_ACCEPT_EXTENSION=1 dist/Proxi.app/Contents/MacOS/Proxi -AppleLanguages '(en)' >/dev/null 2>&1 &
swiftc -parse-as-library Scripts/ci/settings-visual.swift -o "$RUNNER_TEMP/settings-visual"
"$RUNNER_TEMP/settings-visual" "$PWD/screenshots"
