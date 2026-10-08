#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# README、docs（docs/extension.md 除外）、CHANGELOG 最上面一节（发布说明就是它）、扩展关着时也会显示的界面文字（Proxi 的翻译表和 Info.plist）。
words='机场|翻墙|科学上网|GFW|VPN|netflix|youtube|chatgpt|telegram|流媒体'
awk '/^## /{n++} n==1' CHANGELOG.md > "$RUNNER_TEMP/changelog-top.md"
files=(README.md README.zh-CN.md "$RUNNER_TEMP/changelog-top.md" Resources/en.lproj/*.strings Resources/zh-Hans.lproj/*.strings Resources/Info.plist)
for f in docs/*.md; do [ "$f" = docs/extension.md ] || files+=("$f"); done
if grep -n -i -E "$words" "${files[@]}"; then echo "上面这些公开的文字里不该出现这些词"; exit 1; fi
# 发布说明（CHANGELOG 最上面一节）只说设置里多了「扩展」页，不写它是什么。
if grep -n -E '代理引擎|Proxi-Engine|mihomo|内核|订阅|节点' "$RUNNER_TEMP/changelog-top.md"; then echo "发布说明里不该介绍扩展"; exit 1; fi
for f in README.md README.zh-CN.md docs/guide.md docs/automation.md docs/development.md; do
  if grep -n -E 'extension\.md|代理引擎|Proxy Engine|mihomo' "$f"; then echo "$f 里不该提扩展"; exit 1; fi
done
echo "公开的文字检查通过"
