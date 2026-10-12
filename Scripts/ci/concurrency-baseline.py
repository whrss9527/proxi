"""严格并发构建的警告基线：去掉 Swift 批量编译重复诊断，不允许总数增加。"""
import re
import sys
from pathlib import Path


def warnings(text):
    return set(re.findall(r"^.*?((?:Sources|Packages)/[^\n]*?\.swift:\d+:\d+): warning: (.+)$", text, re.M))


def main():
    baseline, current = (warnings(Path(p).read_text()) for p in sys.argv[1:])
    print(f"Swift strict-concurrency=complete：基线 {len(baseline)}，当前 {len(current)}，变化 {len(current) - len(baseline):+d}")
    if len(current) > len(baseline):
        for location, message in sorted(current - baseline):
            print(f"{location}: warning: {message}")
        raise SystemExit("严格并发构建警告增加，请先修复")


if __name__ == "__main__":
    main()
