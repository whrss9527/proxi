import Foundation

/// 仓库根目录的 CHANGELOG.md。检查到新版本时，「设置 → 关于」按它列出从当前版本到新版本之间每一版的改动：
/// 发布很频繁，中间常常隔了好几版，只看最新那一版的发布说明会漏掉前面的。
enum Changelog {
    struct Release: Equatable {
        var version: String
        var date: String?
        /// 版本标题下面的内容（Markdown）。
        var notes: String
    }

    /// 分出每一版：「## 0.14.3（2026-10-01）」开头，到下一个「## 」为止；不是版本号的标题和它下面的内容跳过。
    static func parse(_ text: String) -> [Release] {
        var releases: [Release] = []
        var current: (version: String, date: String?)?
        var lines: [String] = []
        func flush() {
            if let current {
                let notes = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                releases.append(Release(version: current.version, date: current.date, notes: notes))
            }
            lines = []
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                current = heading(line)
            } else if current != nil {
                lines.append(line)
            }
        }
        flush()
        return releases
    }

    /// 「## 0.14.3（2026-10-01）」→ 版本号和日期；半角括号、没有日期也认。
    static func heading(_ line: String) -> (version: String, date: String?)? {
        let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        let parts = title.split(maxSplits: 1, whereSeparator: { "（(".contains($0) })  // l10n-ignore：标题里的括号
        guard let first = parts.first else { return nil }
        let version = first.trimmingCharacters(in: .whitespaces)
        guard version.range(of: #"^[0-9]+(?:\.[0-9]+)+(?:-[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else { return nil }
        let date = parts.count > 1
            ? parts[1].prefix { !"）)".contains($0) }.trimmingCharacters(in: .whitespaces)  // l10n-ignore：标题里的括号
            : ""
        return (version, date.isEmpty ? nil : date)
    }

    /// 比 current 新、不比 latest 新的几版，新的在前。
    static func releases(_ all: [Release], after current: String, upTo latest: String) -> [Release] {
        all.filter { UpdateChecker.isNewer($0.version, than: current) && !UpdateChecker.isNewer($0.version, than: latest) }
            .sorted { UpdateChecker.isNewer($0.version, than: $1.version) }
    }
}
