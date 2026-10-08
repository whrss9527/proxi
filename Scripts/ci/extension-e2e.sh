#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
exec > >(tee "$RUNNER_TEMP/extension.log") 2>&1
support="$HOME/Library/Application Support/Proxi"
engine="$support/engine"
# 本地假发布：这次打包的代理引擎和校验和，格式和 GitHub 的发布接口一样。
feed="$RUNNER_TEMP/ext-feed"
rm -rf "$feed" && mkdir -p "$feed"
cp dist/Proxi-Engine-0.0.0.zip "$feed/"
(cd "$feed" && shasum -a 256 Proxi-Engine-0.0.0.zip > SHA256SUMS.txt && cat SHA256SUMS.txt)
size=$(stat -f %z "$feed/Proxi-Engine-0.0.0.zip")
cat > "$feed/release.json" <<JSON
{"tag_name":"v0.0.0","assets":[{"name":"Proxi-Engine-0.0.0.zip","size":$size,"browser_download_url":"http://127.0.0.1:8767/Proxi-Engine-0.0.0.zip"},
                              {"name":"SHA256SUMS.txt","size":100,"browser_download_url":"http://127.0.0.1:8767/SHA256SUMS.txt"}]}
JSON
fixture_server 8767 "$feed"
condition_1() { curl --connect-timeout 1 --max-time 2 -sf -o /dev/null http://127.0.0.1:8767/release.json; }
wait_for 15 "扩展假发布服务可用" condition_1
# 用测试用的环境变量当作用户勾选了同意并开启（界面上的流程和截图在上一步）。
: > "$support/proxi.log"
PROXI_EXTENSION_FEED=http://127.0.0.1:8767/release.json PROXI_TEST_ACCEPT_EXTENSION=1 dist/Proxi.app/Contents/MacOS/Proxi >/dev/null 2>&1 &
wait_json dist/Proxi.app/Contents/MacOS/Proxi '.extension.enabled == true and .extension.installed == true' 90
app="$support/Extensions/Proxi Engine.app"
fixture_requested 8767 /release.json || { echo "没有读取假发布信息"; exit 1; }
codesign --verify --deep --strict "$app"
bin="$app/Contents/MacOS/ProxiEngine"
# 代理引擎第一次运行：下载内核和 GeoIP 数据库（上游的正式发布，核对写死的 SHA-256），读以前的订阅，启动内核。
wait_json "$bin" '.engine.nodes == 4 and .engine.status == "running"' 180
echo "===== 代理引擎的日志 ====="; cat "$engine/engine.log" || true
grep -q "event=core.download url=https://github.com/MetaCubeX/mihomo/releases/download/v1.19.31/" "$engine/engine.log" || { echo "没有从上游的发布下载内核"; exit 1; }
expected=$(python3 -c 'import platform; print({"arm64":"fae1f37e28ee53fcf5be7a8bb121099db1fe442e44205734ed49c62579364090"}.get(platform.machine(),"d1361fdb7f93ac500d8c936cfd61516b2445c6acfaabe982244fdd765872e077"))')
[ "$(shasum -a 256 "$engine/bin/mihomo" | cut -d' ' -f1)" = "$expected" ] || { echo "下载的内核和写死的校验和不一样"; exit 1; }
geo_expected=$(sed -n 's/.*static let geoIPSHA256 = "\([a-f0-9]*\)".*/\1/p' Sources/ProxiEngine/System/CoreDownload.swift)
[[ -n "$geo_expected" && $(shasum -a 256 "$engine/bin/Country.mmdb" | cut -d' ' -f1) == "$geo_expected" ]] || { echo "GeoIP 数据库没有按固定校验和验证"; exit 1; }
[ -f "$engine/bin/Country.mmdb" ] || { echo "没有下载 GeoIP 数据库"; exit 1; }
find "$app" -iname '*mihomo*' | grep . && { echo "内核不该放进程序里"; exit 1; }
# 以前开着的「节点代理」（只设了 git）开回来了，指向代理引擎的端口。
condition_4() { [ "$(git config --global --includes --get http.proxy || true)" = "http://127.0.0.1:7890" ]; }
wait_for 30 "迁移的 git 代理已恢复" condition_4
echo "===== 程序日志 ====="; cat "$support/proxi.log"
[ "$(git config --global --includes --get http.proxy || true)" = "http://127.0.0.1:7890" ] || { echo "以前开着的代理引擎配置没有开回来"; exit 1; }
cli=dist/Proxi.app/Contents/MacOS/Proxi
"$cli" status --json | tee "$RUNNER_TEMP/ext-status.json"
python3 -c "import json,sys; e=json.load(open(sys.argv[1]))['extension']; assert e['enabled'] and e['running'] and e['port']==7890, e" "$RUNNER_TEMP/ext-status.json" || { echo "状态里的扩展不对"; exit 1; }
"$cli" status | tee "$RUNNER_TEMP/ext-status.txt"
grep -q "节点代理" "$RUNNER_TEMP/ext-status.txt" || { echo "状态里没有正在用的代理引擎配置"; exit 1; }
"$cli" profiles | grep -q "节点代理" || { echo "配置列表里没有代理引擎那条配置"; exit 1; }
grep -q '"engine"' "$support/config.json" && { echo "代理引擎那条配置不该写进 Proxi 的 config.json"; exit 1; }
# 经代理引擎的端口访问（假节点都连不上，自动选择会退回直连）。
echo "经代理引擎访问外网：$(curl -s -m 10 -x http://127.0.0.1:7890 -o /dev/null -w '%{http_code}' https://www.apple.com/library/test/success.html || true)"
# 代理引擎自己的命令行：经它的本机控制接口操作。
core="$engine/core/config.yaml"
"$bin" status --json | tee "$RUNNER_TEMP/engine-status.json"
grep -q '"engine"' "$RUNNER_TEMP/engine-status.json" || { echo "代理引擎的命令行读不到状态"; exit 1; }
"$bin" nodes 测试
"$bin" rule add example.org direct --type suffix
condition_5() { grep -q 'DOMAIN-SUFFIX,example.org,DIRECT' "$core"; }
wait_for 10 "新规则已生效" condition_5
grep -q 'DOMAIN-SUFFIX,example.org,DIRECT' "$core" || { echo "命令行加的规则没有进内核配置"; exit 1; }
"$bin" undo
condition_6() { ! grep -q 'DOMAIN-SUFFIX,example.org,DIRECT' "$core"; }
wait_for 10 "撤销规则已生效" condition_6
grep -q 'DOMAIN-SUFFIX,example.org,DIRECT' "$core" && { echo "撤销没有生效"; exit 1; }
grep -q 'name: "组 A"' "$core" || { echo "以前的策略组没有进内核配置"; exit 1; }
grep -q 'DOMAIN-SUFFIX,example.net,组 A' "$core" || { echo "以前的规则没有进内核配置"; exit 1; }
grep -q 'exclude-filter: "(?i)过期"' "$core" || { echo "订阅的排除没有写进内核配置"; exit 1; }
"$bin" check https://www.apple.com/library/test/success.html || true
# 截图：Proxi 的面板和扩展页，代理引擎的设置（它没有自己的菜单栏图标，再打开一次就显示设置）。
show_panel
screencapture -x screenshots/ext-panel.png || true
show_settings extensions
screencapture -x screenshots/ext-page.png || true
show_settings profiles
screencapture -x screenshots/ext-profiles.png || true
open -a "$app"
wait_for 30 "扩展设置窗口" dist/ci-window-ready com.whrss9527.proxyswitch.engine
screencapture -x screenshots/engine-settings.png || true
# 验证切换设置期间也不会临时进入 Dock（持续采样，而非只检查最终状态）。
swift Scripts/check-settings-dock.swift "$app"
# 特权助手：装的时候核对内核的校验和，认不出的内核不装；装好以后经它以 root 运行内核（网关模式）。
printf 'not the core' > "$RUNNER_TEMP/fake-core"; chmod +x "$RUNNER_TEMP/fake-core"
# shellcheck disable=SC2024
if sudo env PROXI_CI_DIAGNOSTICS=1 "$bin" helper install --uid "$(id -u)" --core "$RUNNER_TEMP/fake-core" > "$RUNNER_TEMP/fake-helper.txt" 2>&1; then
  cat "$RUNNER_TEMP/fake-helper.txt"; echo "认不出的内核不该装进特权助手"; exit 1
fi
cat "$RUNNER_TEMP/fake-helper.txt"
grep -q "event=helper.reject reason=core_checksum" "$RUNNER_TEMP/fake-helper.txt" || { echo "没有按校验和拒绝"; exit 1; }
[ ! -e /Library/PrivilegedHelperTools/com.whrss9527.proxyswitch.mihomo ] || { echo "认不出的内核留在了助手的目录里"; exit 1; }
sudo "$bin" helper install --uid "$(id -u)" --core "$engine/bin/mihomo"
condition_7() { "$bin" helper status; }
wait_for 10 "特权助手已就绪" condition_7
"$bin" helper status || { echo "特权助手没有运行"; sudo cat /Library/Logs/ProxySwitch-helper.log || true; exit 1; }
[ "$(stat -f %u /Library/PrivilegedHelperTools/com.whrss9527.proxyswitch.mihomo)" = "0" ] || { echo "助手里的内核不是 root 的"; exit 1; }
[ "$(shasum -a 256 /Library/PrivilegedHelperTools/com.whrss9527.proxyswitch.mihomo | cut -d' ' -f1)" = "$expected" ] || { echo "助手里的内核不是校验过的那份"; exit 1; }
fwd_before=$(sysctl -n net.inet.ip.forwarding)
# 虚拟网卡只接管 1.1.1.1 和 1.0.0.1（用配置补丁限定路由），免得 runner 自己和 GitHub 的连接被截下来。
printf '%s' '{"proxi":1,"patch":"log-level: info\ntun:\n  route-address: [\"1.1.1.1/32\", \"1.0.0.1/32\"]\n"}' > "$RUNNER_TEMP/tun-patch.json"
"$bin" import "$RUNNER_TEMP/tun-patch.json"
"$bin" gateway on
condition_8() { ifconfig | grep -q "inet 198\.18\."; }
wait_for 30 "测试虚拟网卡已就绪" condition_8
helper_log="/Library/Application Support/ProxySwitch/core/core.log"
if ! ifconfig | grep -q "inet 198\.18\."; then
  echo "虚拟网卡没有起来"; "$bin" status --json || true; cat "$helper_log" || true; tail -30 "$engine/engine.log"; sudo tail -30 /Library/Logs/ProxySwitch-helper.log || true
  exit 1
fi
condition_9() { [ "$(sysctl -n net.inet.ip.forwarding)" = "1" ]; }
wait_for 10 "IP 转发已开启" condition_9
[ "$(sysctl -n net.inet.ip.forwarding)" = "1" ] || { echo "网关模式没有打开 IP 转发"; exit 1; }
pgrep -f "com.whrss9527.proxyswitch.mihomo" >/dev/null || { echo "助手没有运行内核"; exit 1; }
served=$(dig +short +time=3 +tries=2 example.org @127.0.0.1 | head -1)
echo "网关的 DNS 回答 example.org：$served"
case "$served" in 198.18.*) ;; *) echo "网关模式的 DNS 没有回答"; exit 1 ;; esac
"$bin" gateway off
condition_10() { ! ifconfig | grep -q "inet 198\.18\."; }
wait_for 30 "测试虚拟网卡已关闭" condition_10
ifconfig | grep -q "inet 198\.18\." && { echo "关掉网关模式后虚拟网卡还在"; exit 1; }
condition_11() { [ "$(sysctl -n net.inet.ip.forwarding)" = "$fwd_before" ]; }
wait_for 10 "IP 转发已恢复" condition_11
[ "$(sysctl -n net.inet.ip.forwarding)" = "$fwd_before" ] || { echo "IP 转发没有恢复"; exit 1; }
condition_12() { pgrep -x mihomo >/dev/null; }
wait_for 15 "内核已回到普通进程" condition_12
pgrep -x mihomo >/dev/null || { echo "关掉网关模式后内核没有回到本机进程"; exit 1; }
"$bin" undo
sudo "$bin" helper uninstall
[ ! -e /Library/LaunchDaemons/com.whrss9527.proxyswitch.helper.plist ] || { echo "特权助手没有卸载干净"; exit 1; }
# 关闭扩展（测试用的环境变量，等于在扩展页里点「关闭并移除」）：先关掉正在用的代理引擎配置、恢复设置，再退出代理引擎、删掉程序，数据留着。
pkill -x Proxi || true
condition_13() { ! pgrep -x Proxi >/dev/null; }
wait_for 15 "Proxi 已退出" condition_13
condition_14() { ! pgrep -x ProxiEngine >/dev/null; }
wait_for 10 "扩展已退出" condition_14
pgrep -x ProxiEngine >/dev/null && { echo "Proxi 退出时代理引擎应该跟着退出（下次打开 Proxi 再启动）"; exit 1; }
# 代理引擎跟着退出了：正在用的「代理引擎」配置也要关掉，不然 git、系统代理都指向一个没人监听的端口。
[ -z "$(git config --global --includes --get http.proxy || true)" ] || { echo "退出 Proxi 时没有关掉正在用的代理引擎配置（git 还指着它）"; cat "$support/proxi.log"; exit 1; }
: > "$support/proxi.log"
PROXI_TEST_DISABLE_EXTENSION=1 dist/Proxi.app/Contents/MacOS/Proxi >/dev/null 2>&1 &
wait_json "$cli" '.extension == {"enabled": false}' 60
cat "$support/proxi.log"
condition_16() { ! pgrep -x ProxiEngine >/dev/null; }
wait_for 10 "关闭后扩展已退出" condition_16
pgrep -x ProxiEngine && { echo "关闭扩展后代理引擎还在运行"; exit 1; }
pgrep -x mihomo && { echo "关闭扩展后内核还在运行"; exit 1; }
[ -z "$(git config --global --includes --get http.proxy || true)" ] || { echo "关闭扩展后 git 代理还在"; exit 1; }
[ ! -e "$app" ] || { echo "「关闭并移除」后程序还在"; exit 1; }
[ -f "$engine/config.json" ] && grep -q "测试订阅" "$engine/config.json" || { echo "关闭扩展不该删掉它的数据"; exit 1; }
"$cli" status --json > "$RUNNER_TEMP/off-status.json"
python3 -c "import json,sys; assert json.load(open(sys.argv[1]))['extension']=={'enabled': False}" "$RUNNER_TEMP/off-status.json" || { echo "关闭后状态不对"; exit 1; }
"$cli" profiles | grep -q "节点代理" && { echo "关闭扩展后配置列表里还有代理引擎"; exit 1; }
before=$(grep -c "event=extension.request" "$support/proxi.log" || true)
requests_unchanged() { [[ $(grep -c "event=extension.request" "$support/proxi.log" || true) == "$before" ]]; }
assert_for 8 "关闭后无扩展请求" requests_unchanged
stop_app Proxi
# 后面的步骤用回原来的配置。
cp "$RUNNER_TEMP/config-backup.json" "$support/config.json"
echo '{}' > "$support/state.json"
rm -rf "$engine" "$support/Extensions"
echo "扩展测试通过"

mark_pass extension-e2e
