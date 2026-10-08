#!/bin/bash
set -eo pipefail
# 上传单个 tar，避免 artifact 服务丢掉 App 中的可执行权限和符号链接。
tar -czf "$RUNNER_TEMP/proxi-ci-dist.tar.gz" dist screenshots
