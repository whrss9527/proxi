#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# 出错时把去重后的错误打在最后（警告很多，原样输出会把错误淹没）。
if ! swift build > "$RUNNER_TEMP/build.log" 2>&1; then
  grep -E "^/.*error:" "$RUNNER_TEMP/build.log" | sort -u | head -150 | tee "$RUNNER_TEMP/build-errors.txt"
  echo "::error title=编译错误::$(head -60 "$RUNNER_TEMP/build-errors.txt" | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')"
  exit 1
fi
grep -E "error:" "$RUNNER_TEMP/build.log" | sort -u | head -20 || true
