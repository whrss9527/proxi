#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
exec > >(tee "$RUNNER_TEMP/migration.log") 2>&1
support="$HOME/Library/Application Support/Proxi"
cp "$support/config.json" "$RUNNER_TEMP/config-backup.json"
# 以前版本的数据：代理引擎那条配置开着（只设了 git，不动 runner 的系统代理），有订阅（本机文件，runner 上连本机端口会被「本地网络」权限拦住）、
# 手动节点、策略组和规则；数据目录里有 core/、imports/ 和操作记录；另外放一份假的后台助手文件（不加载），看能不能认出来。
mkdir -p "$RUNNER_TEMP/sub"
python3 - "$RUNNER_TEMP/sub/sub.txt" <<'PY'
import base64, sys, urllib.parse
uris = [f"ss://YWVzLTEyOC1nY206cGFzc3dvcmQ=@127.0.0.1:{port}#{urllib.parse.quote(name)}" for port, name in [(8388, "测试节点A"), (8389, "测试节点B")]]
uris.append("trojan://password@example.com:443#" + urllib.parse.quote("测试节点C"))
# 订阅设了「去掉 过期」：这个节点不该出现。
uris.append("trojan://password@example.com:443#" + urllib.parse.quote("过期节点"))
open(sys.argv[1], "w").write(base64.b64encode("\n".join(uris).encode()).decode())
PY
cat > "$support/config.json" <<JSON
{"profiles":[{"id":"6D2F2A1E-0000-4000-8000-0000000000AA","name":"节点代理","color":"#2563eb","kind":"http","host":"127.0.0.1","port":7890,"engine":true,"targets":["git"]},
             {"id":"6D2F2A1E-0000-4000-8000-000000000002","name":"公司代理","color":"#2563eb","kind":"http","host":"proxy.corp.example","port":3128}],
 "engine":{"mode":"rule","mixedPort":7890,
           "subscriptions":[{"id":"6D2F2A1E-0000-4000-8000-00000000000A","name":"测试订阅","url":"file://$RUNNER_TEMP/sub/sub.txt","exclude":"过期"}],
           "groups":[{"name":"组 A","kind":"select","filter":"A|B"}],
           "customRules":[{"pattern":"example.net","policy":"group:组 A"},{"kind":"app","pattern":"/Applications/Safari.app","policy":"direct"}],
           "manualNodes":[{"link":"trojan://password@example.com:443#%E6%89%8B%E5%8A%A8%E8%8A%82%E7%82%B9D"}],
           "ruleSets":[]},
 "speedDisplay":"engine","automation":{"permission":"full"}}
JSON
echo '{"lastProfileID":"6D2F2A1E-0000-4000-8000-0000000000AA","enabledByUs":true,"share":{"enabled":false,"port":7892},"traffic":{}}' > "$support/state.json"
git config --global http.proxy http://127.0.0.1:7890
git config --global https.proxy http://127.0.0.1:7890
mkdir -p "$support/core/rules" "$support/imports"
echo "x" > "$support/core/config.yaml"
echo "imported" > "$support/imports/nodes.txt"
echo '[]' > "$support/journal.json"
sudo mkdir -p /Library/PrivilegedHelperTools
sudo touch /Library/PrivilegedHelperTools/com.whrss9527.proxyswitch.helper
: > "$support/proxi.log"
dist/Proxi.app/Contents/MacOS/Proxi >/dev/null 2>&1 &
wait_for 30 "迁移落盘" file_json_match "$support/state.json" '.extension.migrationChecked == true and .enabledByUs == false and .noticeShown == true'
wait_json dist/Proxi.app/Contents/MacOS/Proxi '.extension.enabled == false and .interface.visibleWindows == 0' 
# 更新后不弹任何窗口：扩展的说明只在「设置 → 扩展」里打开开关时显示；有代理引擎的数据时，开启扩展还要用以前的后台助手，也不提示移除。
screencapture -x screenshots/upgrade.png || true
echo "===== 程序日志 ====="; cat "$support/proxi.log"
[ -z "$(git config --global --get http.proxy || true)" ] || { echo "以前版本设的 git 代理没有清掉"; exit 1; }
# 数据一个都没删：挪到了代理引擎的数据目录，配置原样复制，另有备份。
engine="$support/engine"
ls -la "$engine"
for item in config.json state.json config-0.12-backup.json state-0.12-backup.json core/config.yaml imports/nodes.txt journal.json; do
  [ -e "$engine/$item" ] || { echo "代理引擎的数据里少了 $item"; exit 1; }
done
grep -q "测试订阅" "$engine/config.json" || { echo "订阅没有带到代理引擎的配置里"; exit 1; }
grep -q "手动节点" "$engine/config-0.12-backup.json" || grep -q "%E6%89%8B" "$engine/config-0.12-backup.json" || { echo "备份不完整"; exit 1; }
[ "$(cat "$engine/imports/nodes.txt")" = "imported" ] || { echo "imports 的内容不对"; exit 1; }
python3 - "$support/config.json" "$support/state.json" <<'PY' || exit 1
import json, sys
config = json.load(open(sys.argv[1]))
state = json.load(open(sys.argv[2]))
assert "engine" not in config, "Proxi 的配置里不该再有代理引擎的设置（已经挪走）"
assert [p["name"] for p in config["profiles"]] == ["公司代理"], config["profiles"]
assert config["speedDisplay"] == "system" and config["automation"]["permission"] == "operate", config
ext = state["extension"]
assert ext["enabled"] is False and "pendingMigration" not in ext and ext["restoreActive"] is True and ext["migrationChecked"] is True, ext
assert state["noticeShown"] is True, "有代理引擎的数据时后台助手的提示记为不用再显示"
assert ext["profile"]["id"] == "6D2F2A1E-0000-4000-8000-0000000000AA" and ext["profile"]["targets"] == ["git"], ext
assert state["enabledByUs"] is False, state
print("配置迁移正确")
PY
# 用户还没同意：什么都不下载，没有和扩展有关的网络请求。
grep -q "event=extension.request" "$support/proxi.log" && { echo "没同意说明前不该有扩展的网络请求"; exit 1; }
[ ! -e "$support/Extensions" ] || { echo "没同意说明前不该下载代理引擎"; exit 1; }
[ ! -e "$engine/bin" ] || { echo "没同意说明前不该下载内核"; exit 1; }
pgrep -x ProxiEngine && { echo "没同意说明前代理引擎不该在运行"; exit 1; }
stop_app Proxi
# 第二次启动也不弹窗。
: > "$support/proxi.log"
dist/Proxi.app/Contents/MacOS/Proxi >/dev/null 2>&1 &
wait_json dist/Proxi.app/Contents/MacOS/Proxi '.interface.language == "simplifiedChinese" and .interface.visibleWindows == 0' 
grep -q "event=extension.request" "$support/proxi.log" && { echo "没同意说明前不该有扩展的网络请求"; exit 1; }
stop_app Proxi
# 以前开着的配置还记着，在扩展页里开启扩展后开回来。
python3 -c "import json,sys; e=json.load(open(sys.argv[1]))['extension']; assert e['restoreActive'] and not e['enabled'], e" "$support/state.json" || { echo "退出后扩展的状态不对"; exit 1; }
sudo rm -f /Library/PrivilegedHelperTools/com.whrss9527.proxyswitch.helper
git config --global --unset-all https.proxy || true
echo "迁移测试通过"

mark_pass migration-config
