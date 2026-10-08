#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
rm -rf feed && mkdir -p feed
cp -R dist/Proxi.app feed/Proxi.app
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" feed/Proxi.app/Contents/Info.plist
codesign --force --deep --sign - feed/Proxi.app
(cd feed && ditto -c -k --keepParent Proxi.app Proxi-macos.zip && cp Proxi-macos.zip Proxi-macos-arm64.zip && rm -rf Proxi.app \
  && shasum -a 256 Proxi-macos.zip Proxi-macos-arm64.zip > SHA256SUMS.txt && cat SHA256SUMS.txt)
size=$(stat -f %z feed/Proxi-macos.zip)
cat > feed/latest.json <<JSON
{"tag_name":"v9.9.9","html_url":"http://127.0.0.1:8765/latest.json","published_at":"2026-01-01T00:00:00Z",
 "body":"## 9.9.9\n\n- 这是 CI 里用来测试一键更新的假版本。\n- 下载、校验、替换、重新启动都会走一遍。",
 "assets":[{"name":"Proxi-macos.zip","size":$size,"browser_download_url":"http://127.0.0.1:8765/Proxi-macos.zip"},
           {"name":"Proxi-macos-arm64.zip","size":$size,"browser_download_url":"http://127.0.0.1:8765/Proxi-macos-arm64.zip"},
           {"name":"SHA256SUMS.txt","size":100,"browser_download_url":"http://127.0.0.1:8765/SHA256SUMS.txt"}]}
JSON
