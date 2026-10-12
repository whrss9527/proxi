#!/usr/bin/env python3
"""检查界面文字的翻译是否齐全。

代码里显示给用户的中文都写成 L("中文原文", 参数…)，原文就是 Localizable.strings 里的键。这个脚本检查：

1. Sources/Proxi 里每个 L("…") 的键，在每种语言的 Resources/<语言>.lproj/Localizable.strings 里都有
   （扩展「代理引擎」Sources/ProxiEngine 的对应 Resources/Engine/<语言>.lproj，两套分开检查）；
2. 各种语言的键完全一样，没有多出来的（代码里已经不用的）键；
3. 译文里的占位（%@、%1$@）和键里的一样多；
4. 代码里没有漏掉 L(...) 的中文字符串，L( 的第一个参数都是字符串字面量（L(变量) 查不到有没有翻译）。日志（Log.info / Log.error）和行尾带 `// l10n-ignore` 的
   数据（脚本内容、参数里认的中文写法这类）不算。命令行的输出（print）也是界面文字，要经过 L()。
   多行字符串（三个引号）里有中文时，上一行要写 `// l10n-ignore` 并说明英文版在哪里（比如按 AppLanguage.isEnglish 选的另一段）。

用法: Scripts/check-localization.py [--print-keys]
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# (代码目录, 翻译表目录)：Proxi 和扩展「代理引擎」各一套。
TARGETS = [
    (ROOT / "Sources" / "Proxi", ROOT / "Resources"),
    (ROOT / "Sources" / "ProxiEngine", ROOT / "Resources" / "Engine"),
]
# 中文（汉字和全角标点）。
CHINESE = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef“”‘’…]")
# 这些行不是界面文字。
IGNORED_LINE = re.compile(r"Log\.(info|error)\(|Self\.log\(|l10n-ignore")
# 整个文件都不是界面文字的，写在这里（现在没有）。
IGNORED_FILES = set()
PLACEHOLDER = re.compile(r"%(?:\d+\$)?@")
# L( 后面不是字符串字面量（L(name)、L(prefix + x)）：查不到这个键有没有翻译。
NON_LITERAL_L = re.compile(r"(?<![A-Za-z0-9_])L\(\s*(?!\")")


def literal_end(line, start):
    """line[start] 是开头的引号，返回结尾引号后面的位置（跳过 \\( … ) 里嵌套的字符串）。"""
    i = start + 1
    while i < len(line):
        c = line[i]
        if c == "\\":
            if line.startswith("\\(", i):
                depth, i = 1, i + 2
                while i < len(line) and depth:
                    if line[i] == '"':
                        i = literal_end(line, i)
                        continue
                    depth += {"(": 1, ")": -1}.get(line[i], 0)
                    i += 1
                continue
            i += 2
            continue
        if c == '"':
            return i + 1
        i += 1
    return len(line)


def literals(line):
    """一行代码里（去掉 // 注释）的字符串字面量：(开始位置, 内容)。"""
    i = 0
    while i < len(line):
        if line.startswith("//", i):
            return
        if line[i] == '"':
            end = literal_end(line, i)
            yield i, line[i + 1:end - 1]
            i = end
            continue
        i += 1


def mask_literals(line):
    """把一行代码里字符串字面量的内容换成空格（保留引号），去掉 // 注释，用来查 L( 后面跟的是不是字面量。"""
    out, i = [], 0
    while i < len(line):
        if line.startswith("//", i):
            break
        if line[i] == '"':
            end = literal_end(line, i)
            out.append('"' + " " * max(0, end - i - 2) + '"')
            i = end
            continue
        out.append(line[i])
        i += 1
    return "".join(out)


def scan(sources):
    keys, unwrapped = {}, []
    for folder in sources:
        for path in sorted(folder.rglob("*.swift")):
            if path.name in IGNORED_FILES:
                continue
            lines = path.read_text(encoding="utf-8").splitlines()
            block = None  # 在多行字符串里：(开始的行号, 上一行是否标了 l10n-ignore)
            for number, line in enumerate(lines, 1):
                if block is not None:
                    if line.strip().startswith('"""'):
                        block = None
                    elif CHINESE.search(line) and not block[1]:
                        unwrapped.append(f"{path.relative_to(ROOT)}:{number}: 多行字符串里有中文，上一行没有标 l10n-ignore")
                        block = (block[0], True)
                    continue
                if line.rstrip().endswith('"""') and line.count('"""') == 1:
                    block = (number, number > 1 and "l10n-ignore" in lines[number - 2])
                    continue
                if line.strip().startswith("//"):
                    continue
                where = f"{path.relative_to(ROOT)}:{number}"
                if "func L(" not in line and not IGNORED_LINE.search(line) and NON_LITERAL_L.search(mask_literals(line)):
                    unwrapped.append(f"{where}: L() 的第一个参数要直接写中文原文（字符串字面量），不然查不到它有没有翻译")
                for start, text in literals(line):
                    wrapped = re.search(r"(?<![A-Za-z0-9_])L\(\s*$", line[:start]) is not None
                    if wrapped:
                        if "\\(" in text:
                            unwrapped.append(f"{where}: L() 的键里不能有插值，用 %@ 占位：\"{text}\"")
                        keys.setdefault(unescape(text), where)
                    elif CHINESE.search(re.sub(r"\\\(.*?\)", "", text)) and not IGNORED_LINE.search(line):
                        unwrapped.append(f"{where}: 中文没有经过 L()：\"{text}\"")
                    inner_found, inner_keys = nested(text)
                    for key in inner_keys:
                        keys.setdefault(key, where)
                    if not IGNORED_LINE.search(line):
                        for inner in inner_found:
                            unwrapped.append(f"{where}: 插值里的中文没有经过 L()：\"{inner}\"")
    return keys, unwrapped


def nested(text):
    """插值 \\( … ) 里嵌套的字符串：(没有经过 L() 的中文, 经过 L() 的键)。"""
    found, keys, i = [], [], 0
    while True:
        j = text.find("\\(", i)
        if j < 0:
            return found, keys
        depth, k = 1, j + 2
        while k < len(text) and depth:
            if text[k] == '"':
                end = literal_end(text, k)
                inner = text[k + 1:end - 1]
                if re.search(r"(?<![A-Za-z0-9_])L\(\s*$", text[:k]) is not None:
                    keys.append(unescape(inner))
                elif CHINESE.search(re.sub(r"\\\(.*?\)", "", inner)):
                    found.append(inner)
                more_found, more_keys = nested(inner)
                found += more_found
                keys += more_keys
                k = end
                continue
            depth += {"(": 1, ")": -1}.get(text[k], 0)
            k += 1
        i = k


def unescape(text):
    return text.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\\\", "\\")


def parse_strings(path):
    table = {}
    pattern = re.compile(r'^\s*"((?:[^"\\\n]|\\.)*)"\s*=\s*"((?:[^"\\\n]|\\.)*)"\s*;\s*$', re.M)
    for m in pattern.finditer(path.read_text(encoding="utf-8")):
        key = unescape(m.group(1))
        if key in table:
            print(f"{path.relative_to(ROOT)}: 键重复：\"{m.group(1)}\"")
            table["\0duplicate"] = ""
        table[key] = unescape(m.group(2))
    return table


def check(sources, resources):
    keys, unwrapped = scan([sources] + ([ROOT / "Widgets" / "Sources"] if sources.name == "Proxi" else []))
    if "--print-keys" in sys.argv:
        for key in sorted(keys):
            print(key.replace("\n", "\\n").replace("\t", "\\t"))
        return 0
    status = 0
    print(f"== {sources.relative_to(ROOT)} ↔ {resources.relative_to(ROOT)}")
    for problem in unwrapped:
        print(problem)
        status = 1
    tables = {p.parent.name: parse_strings(p) for p in sorted(resources.glob("*.lproj/Localizable.strings"))}
    if not tables:
        print(f"{resources.relative_to(ROOT)} 里没有 Localizable.strings")
        return 1
    for lang, table in tables.items():
        if "\0duplicate" in table:
            status = 1
            del table["\0duplicate"]
        missing = sorted(k for k in keys if k not in table)
        unused = sorted(k for k in table if k not in keys)
        for key in missing:
            print(f"{lang}: 缺少 \"{key}\"（{keys[key]}）")
        for key in unused:
            print(f"{lang}: 代码里没有用到 \"{key}\"")
        mismatched = [k for k in keys if k in table and len(PLACEHOLDER.findall(k)) != len(PLACEHOLDER.findall(table[k]))]
        for key in mismatched:
            print(f"{lang}: 占位数量不对 \"{key}\" = \"{table[key]}\"")
        if missing or unused or mismatched:
            status = 1
        print(f"{lang}: {len(table)} 条，缺 {len(missing)} 条，多 {len(unused)} 条，占位不对 {len(mismatched)} 条")
    print(f"代码里的键 {len(keys)} 个，漏掉 L() 的中文 {len(unwrapped)} 处")
    return status


def main():
    status = 0
    for sources, resources in TARGETS:
        status |= check(sources, resources)
    return status


if __name__ == "__main__":
    sys.exit(main())
