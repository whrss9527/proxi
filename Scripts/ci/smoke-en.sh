#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
exec > >(tee "$RUNNER_TEMP/smoke-en.log") 2>&1
support="$HOME/Library/Application Support/Proxi"
domain=com.whrss9527.proxyswitch
app=dist/Proxi.app/Contents/MacOS/Proxi
# 通过控制接口确认启动和实际界面语言。
wait_started() { wait_json "$app" '.interface.english == true'; }
# 设置里选了 English：只在 Proxi 自己的偏好设置里写 AppleLanguages，界面、菜单和命令行都是英文。
defaults write "$domain" AppleLanguages -array en
"$app" help | tee "$RUNNER_TEMP/help-en.txt" | head -3
grep -q "^Usage: proxi <command>" "$RUNNER_TEMP/help-en.txt" || { echo "英文界面下命令行的用法应该是英文"; exit 1; }
: > "$support/proxi.log"
"$app" >/dev/null 2>&1 &
wait_started
wait_json "$app" '.interface.language == "english"'
show_panel
screencapture -x screenshots/en-panel.png || true
for page in profiles general automation sync extensions about; do
  show_settings $page
  screencapture -x "screenshots/en-$page.png" || true
done
# 命令行经正在运行的程序拿到的文字也是英文。
"$app" status
# 代理引擎的界面文字也有英文（Proxi 启动它时按自己的界面语言传过去；这里直接看它的命令行用法）。
defaults write com.whrss9527.proxyswitch.engine AppleLanguages -array en
"dist/Proxi Engine.app/Contents/MacOS/ProxiEngine" help | tee "$RUNNER_TEMP/engine-help-en.txt" | head -2
grep -q "^Usage: <engine app binary>" "$RUNNER_TEMP/engine-help-en.txt" || { echo "代理引擎的英文用法不对"; exit 1; }
defaults delete com.whrss9527.proxyswitch.engine AppleLanguages || true
stop_app Proxi
# 跟随系统：删掉 Proxi 自己的选择，runner 的系统语言是英文，界面就是英文。
# 同时测「立即重新启动」打开的新实例会先等旧的退出：带上一个还在运行的进程号，它退出前不该启动。
defaults delete "$domain" AppleLanguages
gate="$RUNNER_TEMP/relaunch-gate"
mkfifo "$gate"
(read -r _ < "$gate") & waiter=$!
: > "$support/proxi.log"
"$app" --relaunch-after "$waiter" >/dev/null 2>&1 &
not_started() { [[ ! -S "$support/control.sock" ]]; }
assert_for 3 "旧实例退出前不启动" not_started
printf 'go\n' > "$gate"
wait "$waiter" || true
wait_started
wait_json "$app" '.interface.language == "system"'
stop_app Proxi
# 同一 runner 测已发布版本和本次产物，复用 Meno 的 CPU 时间 / idlew 增量方法。
baseline="$RUNNER_TEMP/footprint-baseline"
mkdir -p "$baseline"
curl -fsSL --max-time 120 --retry 3 https://github.com/whrss9527/proxi/releases/download/v0.16.4/Proxi-macos.zip -o "$baseline/Proxi-macos.zip"
curl -fsSL --max-time 120 --retry 3 https://github.com/whrss9527/proxi/releases/download/v0.16.4/SHA256SUMS.txt -o "$baseline/SHA256SUMS.txt"
(cd "$baseline" && grep '  Proxi-macos.zip$' SHA256SUMS.txt | shasum -a 256 -c -)
ditto -x -k "$baseline/Proxi-macos.zip" "$baseline/unpacked"
codesign --verify --deep --strict "$baseline/unpacked/Proxi.app"
xattr -dr com.apple.quarantine "$baseline/unpacked/Proxi.app" || true
bash Scripts/measure-footprint.sh "$baseline/unpacked/Proxi.app" dist/Proxi.app
# 后面的步骤用回中文。
defaults write "$domain" AppleLanguages -array zh-Hans
ls -la screenshots

mark_pass smoke-en
