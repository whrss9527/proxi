#!/usr/bin/env bash
# 单独构建小组件，主程序与代理引擎保留 SwiftPM。
set -euo pipefail
cd "$(dirname "$0")/.."
XCODEGEN_VERSION=2.44.1
CHECKSUM=a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73
TOOLS="$PWD/.build/tools/xcodegen-$XCODEGEN_VERSION"
GENERATOR="$TOOLS/xcodegen/bin/xcodegen"
if [[ ! -x "$GENERATOR" ]]; then
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  curl --fail --location --retry 2 --output "$WORK/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
  printf '%s  %s\n' "$CHECKSUM" "$WORK/xcodegen.zip" | shasum -a 256 -c -
  mkdir -p "$TOOLS"
  ditto -x -k "$WORK/xcodegen.zip" "$TOOLS"
fi
[[ "$($GENERATOR --version)" == "Version: $XCODEGEN_VERSION" ]]
"$GENERATOR" generate --spec widget-project.yml
ARCH_FLAGS=(ONLY_ACTIVE_ARCH=YES)
if [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]]; then
  ARCH_FLAGS=("ARCHS=arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
fi
xcodebuild build -project ProxiWidget.xcodeproj -scheme ProxiWidget \
  -configuration Release -derivedDataPath .build/widgets CODE_SIGNING_ALLOWED=NO \
  "MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD" "${ARCH_FLAGS[@]}"
mkdir -p "$APP/Contents/PlugIns"
ditto .build/widgets/Build/Products/Release/ProxiWidget.appex "$APP/Contents/PlugIns/ProxiWidget.appex"
SIGN_ARGS=(--force --options runtime --sign "$IDENTITY" --entitlements Widgets/ProxiWidget.entitlements)
if [[ "$IDENTITY" != "-" ]]; then SIGN_ARGS+=(--timestamp); else SIGN_ARGS+=(--timestamp=none); fi
if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then SIGN_ARGS+=(--keychain "$CODESIGN_KEYCHAIN"); fi
codesign "${SIGN_ARGS[@]}" "$APP/Contents/PlugIns/ProxiWidget.appex"
