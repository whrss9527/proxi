#!/usr/bin/env bash
# 校验组件嵌入、版本和注册；仅用于隔离的 macOS 构建。
set -euo pipefail
APP="${1:-dist/Proxi.app}"
WIDGET="$APP/Contents/PlugIns/ProxiWidget.appex"
[[ -d "$WIDGET" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WIDGET/Contents/Info.plist")" == com.whrss9527.proxyswitch.widgets ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$WIDGET/Contents/Info.plist")" == com.apple.widgetkit-extension ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WIDGET/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" ]]
codesign --verify --deep --strict "$APP"
trap 'pluginkit -r "$WIDGET" >/dev/null 2>&1 || true' EXIT
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
pluginkit -a "$WIDGET"
for attempt in {1..15}; do
  listing=$(pluginkit -m -A -D -v -i com.whrss9527.proxyswitch.widgets)
  [[ "$listing" == *com.whrss9527.proxyswitch.widgets* ]] && break
  sleep 1
done
[[ "$listing" == *com.whrss9527.proxyswitch.widgets* ]]
echo 'Proxi widget bundle and registration verified'
