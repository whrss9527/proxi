#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
VERSION=0.0.0 ARCHS="" THIN_ARCHIVES=1 Scripts/build-app.sh
[ -f dist/Proxi-macos-arm64.zip ] || { echo "没有生成 arm64 精简包"; exit 1; }
[ "$(lipo -archs dist/thin-arm64/Proxi.app/Contents/MacOS/Proxi)" = "arm64" ] || { echo "精简包里的程序不是单架构"; exit 1; }
# 程序里只有 Proxi 自己一个可执行文件，没有别的打包进来的程序。
[ "$(ls dist/Proxi.app/Contents/MacOS)" = "Proxi" ] || { ls -la dist/Proxi.app/Contents/MacOS; echo "Contents/MacOS 里多了别的文件"; exit 1; }
# 两个程序里都没有内核和 GeoIP 数据库（代理引擎第一次运行时才下载）。
engine_app="dist/Proxi Engine.app"
[ -d "$engine_app" ] || { echo "没有组装代理引擎"; exit 1; }
[ "$(ls "$engine_app/Contents/MacOS")" = "ProxiEngine" ] || { ls -la "$engine_app/Contents/MacOS"; echo "代理引擎里多了别的可执行文件"; exit 1; }
found=$(find dist/Proxi.app "$engine_app" \( -iname '*mihomo*' -o -iname '*.mmdb' -o -iname '*clash*' \) -print)
[ -z "$found" ] || { echo "程序里打包了内核或 GeoIP 数据库：$found"; exit 1; }
for bin in dist/Proxi.app/Contents/MacOS/* "$engine_app"/Contents/MacOS/*; do
  if file "$bin" | grep -qi "go buildid" || strings -a "$bin" | grep -q "^go1\.[0-9]"; then echo "$bin 像是 Go 写的内核"; exit 1; fi
done
# Proxi.app 里没有代理引擎的代码：引擎特有的类型名和内核配置的写法在 Proxi 的二进制里都找不到（在代理引擎的二进制里能找到，确认这个检查有效）。
markers='CoreConfigBuilder|ConfigImporter|HelperDaemon|RuleConverter|proxy-groups|rule-providers|mixed-port|PolicyGroupKind'
if strings -a dist/Proxi.app/Contents/MacOS/Proxi | grep -E "$markers" | head -5 | grep .; then echo "Proxi.app 里有代理引擎的代码"; exit 1; fi
[ "$(strings -a "$engine_app/Contents/MacOS/ProxiEngine" | grep -cE "$markers")" -gt 0 ] || { echo "检查方法不对：代理引擎的二进制里也找不到这些名字"; exit 1; }
# 菜单栏上只有 Proxi 一个图标：代理引擎不建自己的菜单栏图标（Proxi 的二进制里有，确认这个检查有效）。
proxi_imports=$(nm -u dist/Proxi.app/Contents/MacOS/Proxi)
engine_imports=$(nm -u "$engine_app/Contents/MacOS/ProxiEngine")
grep -qF 'OBJC_CLASS_$_NSStatusBar' <<< "$proxi_imports" || { echo "检查方法不对：Proxi 的二进制里也找不到 NSStatusBar"; exit 1; }
if grep -F 'OBJC_CLASS_$_NSStatusBar' <<< "$engine_imports"; then echo "代理引擎不该有自己的菜单栏图标"; exit 1; fi
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$engine_app/Contents/Info.plist")" = "com.whrss9527.proxyswitch.engine" ] || { echo "代理引擎的标识不对"; exit 1; }
[ -f dist/Proxi-Engine-0.0.0.zip ] || { echo "没有生成代理引擎的压缩包"; exit 1; }
codesign -dv "$engine_app" 2>&1 | grep -q 'flags=.*runtime' || { echo "代理引擎没有开 hardened runtime"; exit 1; }
echo "程序大小：Proxi.app $(du -sh dist/Proxi.app | cut -f1)，Proxi Engine.app $(du -sh "$engine_app" | cut -f1)" | tee -a screenshots/summary.txt
[ -f dist/Proxi.app/Contents/Resources/donate-wechat.png ] || { echo "关于页的赞赏码没有打包进去"; exit 1; }
for lang in en zh-Hans; do
  for table in Localizable InfoPlist; do
    plutil -lint "dist/Proxi.app/Contents/Resources/$lang.lproj/$table.strings" || { echo "$lang 的 $table.strings 没有打包进去或者格式不对"; exit 1; }
  done
done
# 程序开着 hardened runtime（公证要求），后面的冒烟和更新测试跑的就是这种运行方式。
for code in dist/Proxi.app dist/thin-arm64/Proxi.app; do
  codesign -dv "$code" 2>&1 | grep -q 'flags=.*runtime' || { codesign -dv "$code"; echo "$code 没有开 hardened runtime"; exit 1; }
done
ls -la dist/*.zip
