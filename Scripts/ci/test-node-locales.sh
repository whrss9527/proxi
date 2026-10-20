#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
# 仅在专用 CI 账户切换区域；结束时恢复原偏好，后续打包不继承测试设置。
locale_backup=$(mktemp "$RUNNER_TEMP/node-locales.XXXXXX")
defaults export NSGlobalDomain "$locale_backup"
restore_locale() {
  defaults import NSGlobalDomain "$locale_backup"
  rm -f "$locale_backup"
}
trap restore_locale EXIT
for locale in en_US zh_CN; do
  if [[ $locale == zh_CN ]]; then language=zh-Hans; else language=en; fi
  defaults write NSGlobalDomain AppleLanguages -array "$language"
  defaults write NSGlobalDomain AppleLocale -string "$locale"
  # swift test 每次创建新的 XCTest 进程；断言实际 Locale 与首选语言，防止只改了环境变量。
  PROXI_TEST_LOCALE="$locale" PROXI_ENGINE_DIR="$RUNNER_TEMP/engine-tests" \
    swift test --skip-build --filter NodeQueryTests 2>&1 | tee "$RUNNER_TEMP/test-node-$locale.log"
done
