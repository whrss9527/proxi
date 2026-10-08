#!/bin/bash
set -eo pipefail
# 单元测试实际验证 fish 的提示符钩子，不因为缺少解释器而跳过。
brew install fish
