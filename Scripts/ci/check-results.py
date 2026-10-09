#!/usr/bin/env python3
"""任何失败、取消或跳过都阻止自动合并，保留原检查名作总门槛。"""
import json
import os
import sys

results = json.loads(os.environ["CI_NEEDS"])
required = {"scripts", "build", "smoke", "migration", "update", "rename", "signing", "extension", "settings-visual"}
failures = {name: results.get(name, {}).get("result", "missing") for name in required if results.get(name, {}).get("result") != "success"}
if failures:
    print(f"::error::检查未全部成功：{failures}")
    sys.exit(1)
print("全部检查通过")
