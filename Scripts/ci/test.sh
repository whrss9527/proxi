#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
set -o pipefail
# 顺便把菜单栏图标各种状态的对照图画出来，最后一步打进日志。
# Team ID 的比对必须拿 runner 上真实的 Developer ID 程序测到，不许跳过。
mkdir -p screenshots
# 真实监听查询和代理探测只访问回环 fixture，计时从监听查询前开始。
python3 Scripts/ci/detection-fixture.py "$RUNNER_TEMP/detection-port" > "$RUNNER_TEMP/detection-fixture.log" 2>&1 &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT
for _ in {1..30}; do
  [[ -s "$RUNNER_TEMP/detection-port" ]] && break
  sleep 0.1
done
[[ -s "$RUNNER_TEMP/detection-port" ]] || { echo '检测 fixture 未就绪'; exit 1; }
export PROXI_DETECTION_FIXTURE_PORT
PROXI_DETECTION_FIXTURE_PORT=$(cat "$RUNNER_TEMP/detection-port")
# 代理引擎的单元测试会写它的日志：放到临时目录，不和后面冒烟测试的数据目录混在一起。
if ! PROXI_ENGINE_DIR="$RUNNER_TEMP/engine-tests" PROXI_ICON_PREVIEW_DIR="$PWD/screenshots" PROXI_REQUIRE_SIGNED_SAMPLE=1 PROXI_REQUIRE_FISH=1 swift test > "$RUNNER_TEMP/test.log" 2>&1; then
  # 失败时只打错误和没通过的测试（编译警告很多）。
  grep -E "^/.*error:|error: -\[|failed \(|Executed [0-9]+ tests" "$RUNNER_TEMP/test.log" | sort -u | head -150 | tee "$RUNNER_TEMP/test-errors.txt"
  echo "::error title=单元测试失败::$(head -60 "$RUNNER_TEMP/test-errors.txt" | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')"
  exit 1
fi
grep -E "testCodeSignatureTeam|Executed [0-9]+ tests" "$RUNNER_TEMP/test.log" | tail -3 > screenshots/summary.txt || true

grep PROXI_DETECTION "$RUNNER_TEMP/test.log" | tee -a screenshots/summary.txt
