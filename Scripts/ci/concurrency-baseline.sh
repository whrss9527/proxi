#!/bin/bash
set -eo pipefail
# 用同一 Xcode 完整编译 PR 基线与当前版本，避免拿不同编译器的警告数相比。
: "${RUNNER_TEMP:?}"
: "${CI_BASE_SHA:?}"
git fetch --no-tags origin "$CI_BASE_SHA"
baseline_dir=$(mktemp -d "$RUNNER_TEMP/concurrency-base.XXXXXX")
git worktree add --detach "$baseline_dir" "$CI_BASE_SHA"
trap 'git worktree remove --force "$baseline_dir"' EXIT
if ! swift build --package-path "$baseline_dir" -Xswiftc -strict-concurrency=complete > "$RUNNER_TEMP/build-concurrency-base.log" 2>&1; then
  tail -80 "$RUNNER_TEMP/build-concurrency-base.log"
  exit 1
fi
python3 Scripts/ci/concurrency-baseline.py "$RUNNER_TEMP/build-concurrency-base.log" "$RUNNER_TEMP/build.log" | tee "$RUNNER_TEMP/build-concurrency-summary.log"
