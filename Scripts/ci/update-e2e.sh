#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
# 输出另存一份：失败时最后一步把末尾打在日志最后（前面是几万行截图）。
exec > >(tee "$RUNNER_TEMP/update.log") 2>&1
support="$HOME/Library/Application Support/Proxi"
# 留一份原版，后面测「从临时位置运行」时用。
rm -rf relocate-src && mkdir -p relocate-src && ditto dist/Proxi.app relocate-src/Proxi.app
# 用打包好的程序造一个 9.9.9 版本，放到本地 HTTP 服务器上当作 GitHub 的最新发布：通用包和 arm64 精简包各一份。
bash Scripts/ci/make-update-feed.sh
fixture_server 8765 feed
# 服务器起来要一会儿（runner 忙的时候会超过一秒），能访问了再往下走。
wait_for 30 "本地假发布" curl --connect-timeout 1 --max-time 2 -sf -o /dev/null http://127.0.0.1:8765/latest.json
curl -sSf -o /dev/null http://127.0.0.1:8765/latest.json || { echo "本地的假发布服务器没有起来"; exit 1; }
: > "$support/proxi.log"
PROXI_UPDATE_URL=http://127.0.0.1:8765/latest.json dist/Proxi.app/Contents/MacOS/Proxi >/dev/null 2>&1 &
# 启动 5 秒后自动检查，等它发现新版本。
wait_json dist/Proxi.app/Contents/MacOS/Proxi '.update.version == "9.9.9"' 
show_settings about
screencapture -x screenshots/about.png || true
show_panel
screencapture -x screenshots/panel-update.png || true
open "proxi://update"
# 等下载、替换和重新启动完成。
wait_json dist/Proxi.app/Contents/MacOS/Proxi '.version == "9.9.9"' 60
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/Proxi.app/Contents/Info.plist)
show_settings about
screencapture -x screenshots/about-after.png || true
echo "===== 日志 ====="
cat "$support/proxi.log" || true
echo "================"
[ "$version" = "9.9.9" ] || { echo "程序没有被替换成 9.9.9（现在是 ${version}）"; exit 1; }
fixture_requested 8765 /Proxi-macos-arm64.zip || { echo "没有请求本机架构的精简包"; exit 1; }
pgrep -x Proxi >/dev/null || { echo "更新后程序没有在运行"; exit 1; }
codesign --verify --deep --strict dist/Proxi.app
ls -la dist
stop_app Proxi
rm -rf dist/Proxi.app

# 再模拟「在下载文件夹里直接打开、被系统搬到只读的临时位置运行」：更新应该装进「应用程序」、旧的那份移到废纸篓、从新位置重新打开。
rm -rf /Applications/Proxi.app
: > "$support/proxi.log"
PROXI_UPDATE_URL=http://127.0.0.1:8765/latest.json PROXI_TEST_TRANSLOCATED=1 relocate-src/Proxi.app/Contents/MacOS/Proxi >/dev/null 2>&1 &
wait_json relocate-src/Proxi.app/Contents/MacOS/Proxi '.update.version == "9.9.9"' 
app="$PWD/relocate-src/Proxi.app"
show_settings about "$app/Contents/MacOS/Proxi"
screencapture -x screenshots/about-relocate.png || true
open -a "$app" "proxi://update"
wait_for 60 "安装到应用程序" test -d /Applications/Proxi.app
wait_json /Applications/Proxi.app/Contents/MacOS/Proxi '.version == "9.9.9"' 60
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/Proxi.app/Contents/Info.plist)
echo "===== 日志（从临时位置运行） ====="
cat "$support/proxi.log" || true
echo "================"
[ "$version" = "9.9.9" ] || { echo "没有装进「应用程序」（/Applications 里的版本是 ${version}）"; exit 1; }
[ ! -e "$app" ] || { echo "旧的那份没有移到废纸篓"; exit 1; }
pgrep -f "/Applications/Proxi.app/Contents/MacOS/Proxi" >/dev/null || { echo "没有从「应用程序」重新打开"; exit 1; }
codesign --verify --deep --strict /Applications/Proxi.app
if xattr /Applications/Proxi.app | grep -q com.apple.quarantine; then echo "新程序还带着隔离标记"; exit 1; fi
stop_app Proxi
rm -rf /Applications/Proxi.app
echo "更新测试通过"

mark_pass update-e2e
