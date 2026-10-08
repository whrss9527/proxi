#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
support="$HOME/Library/Application Support/Proxi"
mkdir -p "$support" screenshots
# 单元测试也写过日志，从干净的日志开始。
: > "$support/proxi.log"
# runner 的系统语言是英文。下面的检查和截图用中文界面：先在 Proxi 自己的偏好设置里把界面语言选成简体中文
# （和设置 → 通用 → 界面语言选「简体中文」一样）；英文界面在下一步单独启动。
defaults write com.whrss9527.proxyswitch AppleLanguages -array zh-Hans
# 预置几套配置，面板里有内容可看。「开发代理」只设终端环境变量、git 和 npm（不动 runner 的系统代理），还要登录：
# 配置里只有 hasPassword，密码放在钥匙串里。用一个临时钥匙串（知道它的密码才能设访问分区），
# 允许这次打包的程序读（按它的 cdhash），免得测试时弹出钥匙串的授权对话框。
kc="$RUNNER_TEMP/proxi-ci.keychain-db"
security create-keychain -p ci "$kc"
security unlock-keychain -p ci "$kc"
security set-keychain-settings "$kc"
echo "$(security list-keychains -d user | tr -d '"' | xargs)" > "$RUNNER_TEMP/keychains-before"
read -r -a old_keychains <<< "$(cat "$RUNNER_TEMP/keychains-before")"
security list-keychains -d user -s "$kc" "${old_keychains[@]}"
cdhash=$(codesign -dvvv dist/Proxi.app 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')
security add-generic-password -U -A -T dist/Proxi.app/Contents/MacOS/Proxi -s com.whrss9527.proxyswitch -a 6D2F2A1E-0000-4000-8000-000000000003 -l "Proxi 代理密码" -w 'p@ss word' "$kc"
security set-generic-password-partition-list -S "apple-tool:,apple:,unsigned:,cdhash:$cdhash" -s com.whrss9527.proxyswitch -k ci "$kc" >/dev/null
cat > "$support/config.json" <<'JSON'
{"profiles":[{"id":"6D2F2A1E-0000-4000-8000-000000000001","name":"Charles","color":"#16a34a","kind":"http","host":"127.0.0.1","port":8888},
             {"id":"6D2F2A1E-0000-4000-8000-000000000002","name":"公司代理","color":"#2563eb","kind":"http","host":"proxy.corp.example","port":3128},
             {"id":"6D2F2A1E-0000-4000-8000-000000000003","name":"开发代理","color":"#7c3aed","kind":"http","host":"devproxy.example","port":8080,
              "targets":["environment","git","npm"],"username":"dev","hasPassword":true,"noProxy":"localhost,.corp.example"}]}
JSON
# 假装 iCloud 云盘里已经有另一台 Mac 同步上来的配置（多一套「iCloud 来的」），并且本机记录着同步已开启。
cloud="$RUNNER_TEMP/fake-icloud"
mkdir -p "$cloud"
cat > "$cloud/config.json" <<'JSON'
{"format":1,"updatedAt":"2026-09-24T00:00:00Z","device":"另一台 Mac",
 "config":{"profiles":[{"id":"6D2F2A1E-0000-4000-8000-000000000001","name":"Charles","color":"#16a34a","kind":"http","host":"127.0.0.1","port":8888},
                       {"id":"6D2F2A1E-0000-4000-8000-000000000002","name":"公司代理","color":"#2563eb","kind":"http","host":"proxy.corp.example","port":3128},
                       {"id":"6D2F2A1E-0000-4000-8000-000000000003","name":"开发代理","color":"#7c3aed","kind":"http","host":"devproxy.example","port":8080,
                        "targets":["environment","git","npm"],"username":"dev","hasPassword":true,"noProxy":"localhost,.corp.example"},
                       {"id":"6D2F2A1E-0000-4000-8000-000000000004","name":"iCloud 来的","color":"#db2777","kind":"socks5","host":"10.0.0.8","port":1080}]}}
JSON
echo '{"syncEnabled":true}' > "$support/state.json"
echo "PROXI_SYNC_DIR=$cloud" >> "$GITHUB_ENV"
export PROXI_SYNC_DIR="$cloud"
