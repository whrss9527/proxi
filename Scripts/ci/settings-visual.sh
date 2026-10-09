#!/bin/bash
set -eo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
exec > >(tee "$RUNNER_TEMP/settings-visual.log") 2>&1
mkdir -p screenshots
support="$HOME/Library/Application Support/Proxi"
mkdir -p "$support/Extensions"
cp -R 'dist/Proxi Engine.app' "$support/Extensions/"
printf '%s' '{"extensionState":{"enabled":true,"acceptedVersion":1}}' > "$support/state.json"
# 独立 runner 中直接安装本次构建的扩展，不访问发布或启动任何代理配置。
PROXI_TEST_ACCEPT_EXTENSION=1 dist/Proxi.app/Contents/MacOS/Proxi -AppleLanguages '(en)' >/dev/null 2>&1 &
swiftc -parse-as-library Scripts/ci/settings-visual.swift -o "$RUNNER_TEMP/settings-visual"
"$RUNNER_TEMP/settings-visual" "$PWD/screenshots"
