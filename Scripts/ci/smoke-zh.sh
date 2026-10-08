#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
# 输出另存一份：失败时最后一步把末尾打在日志最后（前面是几万行截图）。
exec > >(tee "$RUNNER_TEMP/smoke.log") 2>&1
support="$HOME/Library/Application Support/Proxi"
cloud="$PROXI_SYNC_DIR"
kc="$RUNNER_TEMP/proxi-ci.keychain-db"
# 直接运行 .app 里的二进制，环境变量才能传进去；系统仍把它当作 dist/Proxi.app 在运行，proxi:// 命令照常送达。
# 离线的 env / shell-init 不会启动 GUI；状态关闭时清理当前 shell 的旧变量。
(
  export http_proxy=old NO_PROXY=old
  eval "$(dist/Proxi.app/Contents/MacOS/Proxi env --shell bash)"
  [ -z "${http_proxy+x}" ] && [ -z "${NO_PROXY+x}" ] || { echo "离线 env 没清理变量"; exit 1; }
)
pgrep -x Proxi >/dev/null && { echo "env 不该启动 GUI"; exit 1; }
PROXI_SYNC_DIR="$cloud" dist/Proxi.app/Contents/MacOS/Proxi >/dev/null 2>&1 &
wait_json dist/Proxi.app/Contents/MacOS/Proxi 'has("proxy") and .interface.language == "simplifiedChinese" and .interface.english == false'
wait_for 30 "iCloud 配置" file_contains "$support/config.json" "iCloud 来的"
wait_json dist/Proxi.app/Contents/MacOS/Proxi '.interface.visibleWindows == 0'
if ! pgrep -x Proxi >/dev/null; then
  echo "程序没有在运行"
  cat "$support/proxi.log" || true
  exit 1
fi
# 面板打开前先拍一张整屏，留着裁出菜单栏右半边看图标和网速。
screencapture -x screenshots/desktop.png || true
show_panel
screencapture -x screenshots/panel.png || true
show_settings profiles
screencapture -x screenshots/settings.png || true
show_settings sync
screencapture -x screenshots/sync.png || true
show_settings automation
screencapture -x screenshots/automation.png || true
show_settings general
screencapture -x screenshots/general.png || true
show_settings extensions
screencapture -x screenshots/extensions.png || true
echo "===== 程序日志 ====="; cat "$support/proxi.log" || true
grep -q "iCloud 来的" "$support/config.json" || { echo "拉到的配置没有写到本机"; cat "$support/config.json"; exit 1; }
# 命令行、MCP 和 URL 命令：经本机控制接口操作正在运行的程序。
cli=dist/Proxi.app/Contents/MacOS/Proxi
[ -S "$support/control.sock" ] || { echo "本机控制接口没有开"; cat "$support/proxi.log"; exit 1; }
"$cli" status --json | tee "$RUNNER_TEMP/status.json"
grep -q '"proxy"' "$RUNNER_TEMP/status.json" || { echo "命令行读不到状态"; exit 1; }
"$cli" profiles | tee "$RUNNER_TEMP/profiles.txt"
grep -q "公司代理" "$RUNNER_TEMP/profiles.txt" || { echo "命令行列不出代理配置"; exit 1; }
# 切到「开发代理」：终端环境变量、git、npm 都指向它，带着从钥匙串里取出、转义过的用户名和密码。
# git 的带密码地址不经命令行，写在只有自己能读的 include 文件里。
expected='http://dev:p%40ss%20word@devproxy.example:8080'
gitproxy() { git config --global --includes --get http.proxy || true; }
"$cli" use 开发
condition_1() { [ "$(gitproxy)" = "$expected" ]; }
wait_for 10 "git 代理已开启" condition_1
[ "$(gitproxy)" = "$expected" ] || { echo "git 的代理不对：$(gitproxy)"; tail -20 "$support/proxi.log"; exit 1; }
grep -q 'p%40ss' "$HOME/.gitconfig" && { echo "$HOME/.gitconfig 里直接写了密码"; exit 1; }
[ "$(stat -f %Lp "$support/git-proxy.inc")" = "600" ] || { echo "git 的 include 文件权限不对"; ls -la "$support"; exit 1; }
[ "$(stat -f %Lp "$HOME/.npmrc")" = "600" ] || { echo ".npmrc 里有密码，权限应该是 600"; exit 1; }
[ "$(launchctl getenv http_proxy)" = "$expected" ] || { echo "环境变量 http_proxy 不对：$(launchctl getenv http_proxy)"; exit 1; }
[ "$(launchctl getenv ALL_PROXY)" = "$expected" ] || { echo "环境变量 ALL_PROXY 不对：$(launchctl getenv ALL_PROXY)"; exit 1; }
[ "$(launchctl getenv no_proxy)" = "localhost,.corp.example" ] || { echo "环境变量 no_proxy 不对"; exit 1; }
# 在子 shell 里实际 eval，不把凭据打印进日志，也不污染测试工作流的环境。
(
  eval "$("$cli" env --shell bash)"
  [ "$http_proxy" = "$expected" ] && [ "$HTTP_PROXY" = "$expected" ] || { echo "env 命令没有刷新代理"; exit 1; }
  [ "${no_proxy-}" = "localhost,.corp.example" ] || { echo "env 的绕过列表不对"; exit 1; }
  eval "$("$cli" env --shell bash --unset)"
  [ -z "${http_proxy+x}" ] && [ -z "${NO_PROXY+x}" ] || { echo "env --unset 没有清理变量"; exit 1; }
)
grep -q "^proxy=$expected" "$HOME/.npmrc" || { echo ".npmrc 里的代理不对"; cat "$HOME/.npmrc" || true; exit 1; }
"$cli" status | tee "$RUNNER_TEMP/status-on.txt"
grep -q "开发代理" "$RUNNER_TEMP/status-on.txt" || { echo "状态里没有正在用的配置"; exit 1; }
show_panel
screencapture -x screenshots/panel-on.png || true
# 关掉：全部清干净。
"$cli" off
condition_2() { [ -z "$(gitproxy)" ]; }
wait_for 10 "git 代理已恢复" condition_2
[ -z "$(gitproxy)" ] || { echo "关掉后 git 的代理还在"; exit 1; }
[ ! -e "$support/git-proxy.inc" ] || { echo "关掉后 git 的 include 文件还在"; exit 1; }
grep -q 'git-proxy.inc' "$HOME/.gitconfig" && { echo "关掉后 ~/.gitconfig 里的 include 还在"; exit 1; }
[ -z "$(launchctl getenv http_proxy)" ] || { echo "关掉后环境变量还在"; exit 1; }
[ -z "$(launchctl getenv ALL_PROXY)" ] || { echo "关掉后 ALL_PROXY 还在"; exit 1; }
if grep -q "^proxy=" "$HOME/.npmrc" 2>/dev/null; then echo "关掉后 .npmrc 里的代理还在"; exit 1; fi
# 测试连接：Charles 没在运行，应该报连不上，命令本身照常结束。
"$cli" test Charles | tee "$RUNNER_TEMP/test.txt"
grep -q "Charles" "$RUNNER_TEMP/test.txt" || { echo "测试连接没有输出"; exit 1; }
# MCP：初始化、列出工具、调用一个工具。
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ci","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_profiles","arguments":{}}}' \
  | "$cli" mcp | tee "$RUNNER_TEMP/mcp.out"
grep -q '"protocolVersion":"2025-06-18"' "$RUNNER_TEMP/mcp.out" || { echo "MCP 初始化失败"; exit 1; }
grep -q '"name":"get_status"' "$RUNNER_TEMP/mcp.out" || { echo "MCP 没有列出工具"; exit 1; }
grep -q '"name":"use_profile"' "$RUNNER_TEMP/mcp.out" || { echo "MCP 没有切换配置的工具"; exit 1; }
grep -q 'iCloud 来的' "$RUNNER_TEMP/mcp.out" || { echo "MCP 调用工具失败"; exit 1; }
# 扩展关着（默认）：命令行和 MCP 只报告它没开，没有它的命令和工具。
grep -q '"extension"' "$RUNNER_TEMP/status.json" || { echo "状态里没有报告扩展"; exit 1; }
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['extension']=={'enabled': False}, d['extension']" "$RUNNER_TEMP/status.json" || { echo "扩展应该是关着的"; exit 1; }
if grep -qE '"name":"(list_nodes|select_node|add_subscription|set_tun|check_url)"' "$RUNNER_TEMP/mcp.out"; then echo "扩展关着时 MCP 不该有它的工具"; exit 1; fi
"$cli" help | grep -qiE "subscription|节点|订阅|engine|引擎" && { echo "扩展关着时命令行的用法里不该提它"; exit 1; }
# URL 命令经同一个接口：用改名前的写法（proxyswitch://）切到「开发代理」，它照样认。
open "proxyswitch://use?name=%E5%BC%80%E5%8F%91%E4%BB%A3%E7%90%86"
condition_3() { [ "$(gitproxy)" = "$expected" ]; }
wait_for 10 "URL 命令开启代理" condition_3
[ "$(gitproxy)" = "$expected" ] || { echo "URL 命令切换配置没有生效"; exit 1; }
open "proxi://off"
condition_4() { [ -z "$(gitproxy)" ]; }
wait_for 10 "URL 命令关闭代理" condition_4
[ -z "$(gitproxy)" ] || { echo "URL 命令关闭代理没有生效"; exit 1; }
# 密码不出现在日志、配置文件、iCloud 同步文件和命令行的输出里。
wait_json "$cli" '.busy == false and .proxy.state == "off"'
"$cli" logs 500 > "$RUNNER_TEMP/logs.txt"
for file in "$support/proxi.log" "$support/config.json" "$support/state.json" "$cloud/config.json" "$RUNNER_TEMP/logs.txt" "$RUNNER_TEMP/status-on.txt"; do
  if grep -qE 'p@ss|p%40ss' "$file"; then echo "$file 里有密码"; exit 1; fi
done
# 扩展关着：没有下载、没有和它有关的网络请求、没有它的文件和进程。
grep -q "event=extension.request" "$support/proxi.log" && { echo "扩展关着时不该有它的网络请求"; grep "event=extension.request" "$support/proxi.log"; exit 1; }
grep -qiE "mihomo|Proxi-Engine|MetaCubeX|geoip" "$support/proxi.log" && { echo "扩展关着时日志里不该出现它的下载"; exit 1; }
for item in Extensions engine; do
  [ ! -e "$support/$item" ] || { echo "扩展关着时不该有 $item"; ls -la "$support/$item"; exit 1; }
done
pgrep -x ProxiEngine && { echo "扩展关着时代理引擎不该在运行"; exit 1; }
pgrep -x mihomo && { echo "扩展关着时内核不该在运行"; exit 1; }
stop_app Proxi
read -r -a old_keychains <<< "$(cat "$RUNNER_TEMP/keychains-before")"
security list-keychains -d user -s "${old_keychains[@]}"
security delete-keychain "$kc" || true
ls -la screenshots
echo "冒烟测试通过"

mark_pass smoke-zh
