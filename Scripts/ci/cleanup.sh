#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
stop_app Proxi
stop_app ProxiEngine
if [[ -f "$RUNNER_TEMP/keychains-before" ]]; then
  read -r -a old_keychains < "$RUNNER_TEMP/keychains-before"
  security list-keychains -d user -s "${old_keychains[@]}"
fi
security delete-keychain "$RUNNER_TEMP/proxi-ci.keychain-db" 2>/dev/null || true
# 仅结束本任务的假发布服务，不按 Python 进程名结束其他任务。
for pidfile in "$RUNNER_TEMP"/fixture-*.pid; do
  [[ -f "$pidfile" ]] || continue
  kill "$(cat "$pidfile")" 2>/dev/null || true
done
