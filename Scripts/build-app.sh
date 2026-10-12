#!/bin/bash
# 编译并组装 Proxi.app（通用二进制），签名后打成 dist/Proxi-macos.zip；
# 另外组装可选扩展「代理引擎」dist/Proxi Engine.app，打成 dist/Proxi-Engine-<版本>.zip（不放进 Proxi.app，
# 用户在 Proxi 里开启扩展时才下载它；两个程序里都没有内核，内核由代理引擎第一次运行时下载）。
#   VERSION=1.0.0 Scripts/build-app.sh          发布构建
#   CONFIG=debug ARCHS="" Scripts/build-app.sh   本机架构的调试构建
#   THIN_ARCHIVES=1 Scripts/build-app.sh         另外打两个单架构的精简包（一键更新用，比通用包小）
#   SKIP_ENGINE=1 Scripts/build-app.sh           不组装代理引擎
#   CODESIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh
#                                                用开发者证书签名（可以是证书名字或 SHA-1），带安全时间戳，之后能提交公证（Scripts/notarize.sh）；
#                                                不设时 ad-hoc 签名。CODESIGN_KEYCHAIN 可以指定证书所在的钥匙串。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS---arch arm64 --arch x86_64}"

# 签名。开 hardened runtime（公证要求；ad-hoc 的构建也开，CI 里测到的就是发布出去的运行方式）。
# 有开发者证书时加安全时间戳（公证要求，证书过期后签名照样有效）；ad-hoc 签名不能带时间戳。
IDENTITY="${CODESIGN_IDENTITY:--}"
# 程序带上权限声明（Resources/Proxi.entitlements：读 Wi‑Fi 名字要的定位权限）。
ENTITLEMENTS="Resources/Proxi.entitlements"
sign() {
  local args=(--force --options runtime --sign "$IDENTITY")
  if [ "$IDENTITY" != "-" ]; then
    args+=(--timestamp)
  fi
  if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
    args+=(--keychain "$CODESIGN_KEYCHAIN")
  fi
  if [ -n "${2:-}" ]; then
    args+=(--entitlements "$2")
  fi
  codesign "${args[@]}" "$1"
}

# shellcheck disable=SC2086
swift build -c "$CONFIG" $ARCHS --product Proxi
if [ -z "${SKIP_ENGINE:-}" ]; then
  # shellcheck disable=SC2086
  swift build -c "$CONFIG" $ARCHS --product ProxiEngine
fi
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c "$CONFIG" $ARCHS --show-bin-path)"

APP="dist/Proxi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp "$BIN_DIR/Proxi" "$APP/Contents/MacOS/Proxi"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 界面文字的翻译：英文和简体中文（代码里写的是中文原文，见 Sources/Proxi/App/AppLanguage.swift）。
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
# 关于页的赞赏码（「请我喝杯咖啡」）。
[ -f Resources/donate-wechat.png ] && cp Resources/donate-wechat.png "$APP/Contents/Resources/donate-wechat.png"
printf 'APPL????' > "$APP/Contents/PkgInfo"
APP="$APP" VERSION="$VERSION" BUILD="$BUILD" IDENTITY="$IDENTITY" ARCHS="$ARCHS" \
  bash Scripts/build-widgets.sh

# 没有开发者证书时用 ad-hoc 签名，Apple 芯片上必须有签名才能运行。
sign "$APP" "$ENTITLEMENTS"
codesign --verify --deep --strict "$APP"
if [ "$IDENTITY" = "-" ]; then
  echo "签名：ad-hoc"
else
  echo "签名：$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
fi

(cd dist && rm -f Proxi-macos.zip && ditto -c -k --keepParent Proxi.app Proxi-macos.zip)
echo "已生成 ${APP} 和 dist/Proxi-macos.zip（版本 ${VERSION}）"

if [ -z "${SKIP_ENGINE:-}" ]; then
  # 扩展「代理引擎」：单独的程序和标识（com.whrss9527.proxyswitch.engine），同一个证书签名。
  ENGINE_APP="dist/Proxi Engine.app"
  rm -rf "$ENGINE_APP"
  mkdir -p "$ENGINE_APP/Contents/MacOS" "$ENGINE_APP/Contents/Resources"
  sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Engine/Info.plist > "$ENGINE_APP/Contents/Info.plist"
  cp "$BIN_DIR/ProxiEngine" "$ENGINE_APP/Contents/MacOS/ProxiEngine"
  cp Resources/AppIcon.icns "$ENGINE_APP/Contents/Resources/AppIcon.icns"
  for lproj in Resources/Engine/*.lproj; do
    cp -R "$lproj" "$ENGINE_APP/Contents/Resources/"
  done
  printf 'APPL????' > "$ENGINE_APP/Contents/PkgInfo"
  sign "$ENGINE_APP"
  codesign --verify --deep --strict "$ENGINE_APP"
  ENGINE_ZIP="Proxi-Engine-${VERSION}.zip"
  (cd dist && rm -f Proxi-Engine-*.zip && ditto -c -k --keepParent "Proxi Engine.app" "$ENGINE_ZIP")
  echo "已生成 ${ENGINE_APP} 和 dist/${ENGINE_ZIP}：$(du -h "dist/${ENGINE_ZIP}" | cut -f1)"
fi

if [ -n "${THIN_ARCHIVES:-}" ]; then
  # 从通用包里各取一种芯片的部分，单架构的包比通用包小。
  for arch in arm64 x86_64; do
    dir="dist/thin-${arch}"
    rm -rf "$dir" && mkdir -p "$dir"
    ditto "$APP" "${dir}/Proxi.app"
    missing=""
    for bin in "${dir}/Proxi.app/Contents/MacOS/Proxi" "${dir}/Proxi.app/Contents/PlugIns/ProxiWidget.appex/Contents/MacOS/ProxiWidget"; do
      [ -f "$bin" ] || continue
      archs="$(lipo -archs "$bin")"
      if [ "$archs" = "$arch" ]; then
        continue
      elif [[ " $archs " == *" $arch "* ]]; then
        lipo "$bin" -thin "$arch" -output "${bin}.thin"
        mv "${bin}.thin" "$bin"
        chmod +x "$bin"
      else
        missing="$bin"
      fi
    done
    if [ -n "$missing" ]; then
      echo "跳过 ${arch} 精简包：${missing} 里没有这个架构"
      rm -rf "$dir"
      continue
    fi
    sign "${dir}/Proxi.app/Contents/PlugIns/ProxiWidget.appex" Widgets/ProxiWidget.entitlements
    sign "${dir}/Proxi.app" "$ENTITLEMENTS"
    codesign --verify --deep --strict "${dir}/Proxi.app"
    (cd "$dir" && ditto -c -k --keepParent Proxi.app "../Proxi-macos-${arch}.zip")
    echo "已生成 dist/Proxi-macos-${arch}.zip：$(du -h "dist/Proxi-macos-${arch}.zip" | cut -f1)"
  done
fi
