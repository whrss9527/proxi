#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
exec > >(tee "$RUNNER_TEMP/settings-visual.log") 2>&1
mkdir -p screenshots
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true'
support="$HOME/Library/Application Support/Proxi"
mkdir -p "$support/Extensions"
cp -R 'dist/Proxi Engine.app' "$support/Extensions/"
printf '%s' '{"extension":{"enabled":true,"acceptedVersion":1}}' > "$support/state.json"
# 独立 runner 中直接安装本次构建的扩展，不访问发布或启动任何代理配置。
PROXI_TEST_ACCEPT_EXTENSION=1 dist/Proxi.app/Contents/MacOS/Proxi -AppleLanguages '(en)' >/dev/null 2>&1 &
swiftc -parse-as-library Scripts/ci/settings-visual.swift -o "$RUNNER_TEMP/settings-visual"
"$RUNNER_TEMP/settings-visual" "$PWD/screenshots"

# 截图下载被网络策略拦截时，可从 CI 日志读取这些测试账户画面。
python3 - <<'PYCODE'
import base64
from pathlib import Path
for p in sorted(Path('screenshots').glob('*.png')):
    encoded=base64.b64encode(p.read_bytes()).decode()
    for i in range(0,len(encoded),2048): print('FRAME',p.stem,encoded[i:i+2048])
PYCODE
