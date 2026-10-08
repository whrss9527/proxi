#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
# 输出另存一份：失败时最后一步把末尾打在日志最后（前面是几万行截图）。
exec > >(tee "$RUNNER_TEMP/legacy.log") 2>&1
# 真实的旧版本经本地假发布更新到这次的程序：它找的是旧名字的包（发布流程里另存的副本），装好后还叫 ProxySwitch.app；
# 新程序第一次启动时把数据目录挪到 Proxi、把自己改名为 Proxi.app 再重新打开，并改好改名前装的命令行工具。
old_support="$HOME/Library/Application Support/ProxySwitch"
support="$HOME/Library/Application Support/Proxi"
rm -rf "$support" "$old_support"
bash Scripts/ci/make-update-feed.sh
work="$RUNNER_TEMP/legacy-update"
rm -rf "$work" && mkdir -p "$work/apps" "$work/feed"
curl -fsSL --retry 3 --retry-delay 3 -o "$work/old.zip" "https://github.com/${GITHUB_REPOSITORY}/releases/download/v0.10.0/ProxySwitch-macos-arm64.zip"
ditto -x -k "$work/old.zip" "$work/apps"
old_app="$work/apps/ProxySwitch.app"
new_app="$work/apps/Proxi.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$old_app/Contents/Info.plist")" = "0.10.0" ] || { echo "下载的不是 0.10.0"; exit 1; }
# 和发布流程一样：新名字的包另存几份旧名字的副本，校验和都列上。包是上一步造的 9.9.9。
for name in Proxi-macos.zip Proxi-macos-arm64.zip ProxySwitch-macos.zip ProxySwitch-macos-arm64.zip; do
  cp feed/Proxi-macos.zip "$work/feed/$name"
done
(cd "$work/feed" && shasum -a 256 *.zip > SHA256SUMS.txt && cat SHA256SUMS.txt)
size=$(stat -f %z "$work/feed/Proxi-macos.zip")
assets=""
for name in Proxi-macos.zip Proxi-macos-arm64.zip ProxySwitch-macos.zip ProxySwitch-macos-arm64.zip; do
  assets="$assets{\"name\":\"$name\",\"size\":$size,\"browser_download_url\":\"http://127.0.0.1:8766/$name\"},"
done
cat > "$work/feed/latest.json" <<JSON
{"tag_name":"v9.9.9","html_url":"http://127.0.0.1:8766/latest.json","published_at":"2026-01-01T00:00:00Z",
 "body":"改名后的第一个版本（CI 里的假发布）",
 "assets":[$assets{"name":"SHA256SUMS.txt","size":100,"browser_download_url":"http://127.0.0.1:8766/SHA256SUMS.txt"}]}
JSON
fixture_server 8766 "$work/feed"
wait_for 30 "本地假发布" curl --connect-timeout 1 --max-time 2 -sf -o /dev/null http://127.0.0.1:8766/latest.json
curl -sSf -o /dev/null http://127.0.0.1:8766/latest.json || { echo "本地的假发布服务器没有起来"; exit 1; }
# 旧版本的数据：一套配置，加上 0.12 及以前才有的设置和数据目录里的子目录（新版本第一次启动时去掉）。
mkdir -p "$old_support/imports"
echo "x" > "$old_support/imports/local.txt"
cat > "$old_support/config.json" <<JSON
{"profiles":[{"id":"6D2F2A1E-0000-4000-8000-000000000009","name":"旧配置","color":"#16a34a","kind":"http","host":"127.0.0.1","port":8888}],
 "engine":{"mode":"rule"}}
JSON
# 改名前装过命令行工具：/usr/local/bin/proxyswitch 转给旧程序里的 ProxySwitch。
sudo mkdir -p /usr/local/bin && sudo chown "$(id -un)" /usr/local/bin
rm -f /usr/local/bin/proxi
printf '#!/bin/sh\n# ProxySwitch 的命令行工具：proxyswitch help 看用法。\nexec %s "$@"\n' "'$old_app/Contents/MacOS/ProxySwitch'" > /usr/local/bin/proxyswitch
chmod 755 /usr/local/bin/proxyswitch
PROXYSWITCH_UPDATE_URL=http://127.0.0.1:8766/latest.json "$old_app/Contents/MacOS/ProxySwitch" >/dev/null 2>&1 &
wait_for 30 "旧程序检查到假发布" fixture_requested 8766 /latest.json
# proxyswitch:// 这次的程序也认，用 -a 指定交给旧版本。
open -a "$old_app" "proxyswitch://update"
wait_for 90 "新名字的程序已落盘" test -d "$new_app"
wait_json "$new_app/Contents/MacOS/Proxi" '.version == "9.9.9"' 90
echo "===== 日志（旧版本的日志挪过来后接着写） ====="
cat "$support/proxi.log" 2>/dev/null || cat "$old_support/proxyswitch.log" 2>/dev/null || true
echo "================"
ls -la "$work/apps"
[ -d "$new_app" ] || { echo "程序没有改名为 Proxi.app"; exit 1; }
[ ! -e "$old_app" ] || { echo "旧名字的程序还在"; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$new_app/Contents/Info.plist")" = "9.9.9" ] || { echo "Proxi.app 不是新版本"; exit 1; }
[ ! -e "$old_support" ] || { echo "旧的数据目录还在"; ls -la "$old_support"; exit 1; }
grep -q "旧配置" "$support/config.json" || { echo "配置没有带过来"; cat "$support/config.json"; exit 1; }
grep -q '"engine"' "$support/config.json" && { echo "配置里还有以前版本的设置"; cat "$support/config.json"; exit 1; }
[ ! -e "$support/imports" ] || { echo "以前版本留下的 imports 没有删掉"; exit 1; }
[ -f "$support/engine/imports/local.txt" ] || { echo "以前版本的 imports 没有原样挪到 engine/ 里"; ls -laR "$support"; exit 1; }
grep -q '"engine"' "$support/engine/config-0.12-backup.json" || { echo "以前版本的配置没有备份"; exit 1; }
pgrep -f "$new_app/Contents/MacOS/Proxi" >/dev/null || { echo "没有从 Proxi.app 重新打开"; exit 1; }
# 改名前的命令行工具改好了，还多了一个 proxi。
condition_1() { grep -q "$new_app/Contents/MacOS/Proxi" /usr/local/bin/proxyswitch; }
wait_for 10 "旧命令行工具已迁移" condition_1
cat /usr/local/bin/proxyswitch
grep -q "$new_app/Contents/MacOS/Proxi" /usr/local/bin/proxyswitch || { echo "改名前的 proxyswitch 命令没有改好"; exit 1; }
grep -q "$new_app/Contents/MacOS/Proxi" /usr/local/bin/proxi || { echo "没有装上 proxi 命令"; exit 1; }
/usr/local/bin/proxi version | tee "$RUNNER_TEMP/proxi-version.txt"
grep -q "Proxi 9.9.9" "$RUNNER_TEMP/proxi-version.txt" || { echo "proxi 命令不能用"; exit 1; }
/usr/local/bin/proxyswitch status --json > "$RUNNER_TEMP/legacy-status.json" || true
grep -q '"proxy"' "$RUNNER_TEMP/legacy-status.json" || { echo "改名前的 proxyswitch 命令读不到状态"; cat "$RUNNER_TEMP/legacy-status.json"; exit 1; }
fixture_requested 8766 /ProxySwitch-macos-arm64.zip || { echo "旧版本没有请求旧名字的精简包"; exit 1; }
codesign --verify --deep --strict "$new_app"
stop_app Proxi
rm -f /usr/local/bin/proxi /usr/local/bin/proxyswitch
echo "从改名前的版本更新的测试通过"

mark_pass rename-e2e
