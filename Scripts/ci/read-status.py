#!/usr/bin/env python3
"""有界读取状态，避免一个挂起的 CLI 请求超过 wait_for 的截止时间。"""
import json
import subprocess
import sys

try:
    result = subprocess.run([sys.argv[1], "status", "--json"], capture_output=True, text=True, timeout=2, check=True)
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise ValueError("status must be an object")
    print(json.dumps(value, ensure_ascii=False))
except (subprocess.SubprocessError, OSError, ValueError):
    sys.exit(1)
