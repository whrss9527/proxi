import Foundation

struct ProcessNetworkCounter: Equatable, Sendable {
    var pid: Int32
    var name: String
    var received: UInt64
    var sent: UInt64
}

enum NettopOutput {
    /// 兼容带时间列与不带时间列的 CSV；列顺序以表头为准，名称按最后一个点拆出 PID。
    static func parse(_ output: String) throws -> [ProcessNetworkCounter] {
        var columns: (process: Int, received: Int, sent: Int)?
        var counters: [Int32: ProcessNetworkCounter] = [:]
        var invalidCounters = false
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = csvFields(String(line))
            if let received = fields.firstIndex(of: "bytes_in"), let sent = fields.firstIndex(of: "bytes_out") {
                columns = (fields.first == "time" ? 1 : 0, received, sent)
                continue
            }
            guard let columns, fields.count > max(columns.process, max(columns.received, columns.sent)) else { continue }
            let token = fields[columns.process]
            guard let dot = token.lastIndex(of: "."), let pid = Int32(token[token.index(after: dot)...]), pid > 0 else { continue }
            guard let received = UInt64(fields[columns.received]), let sent = UInt64(fields[columns.sent]) else {
                invalidCounters = true
                continue
            }
            counters[pid] = ProcessNetworkCounter(pid: pid, name: String(token[..<dot]), received: received, sent: sent)
        }
        guard columns != nil, !invalidCounters else { throw NetworkMonitorError.invalidOutput }
        return counters.values.sorted { $0.pid < $1.pid }
    }

    private static func csvFields(_ line: String) -> [String] {
        var result: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else { quoted.toggle() }
            }
            else if character == "," && !quoted {
                result.append(field.trimmingCharacters(in: .whitespaces))
                field = ""
            } else { field.append(character) }
            index += 1
        }
        result.append(field.trimmingCharacters(in: .whitespaces))
        return result
    }
}

enum NetworkMonitorError: LocalizedError {
    case invalidOutput
    case command(String)
    var errorDescription: String? {
        switch self {
        case .invalidOutput: return L("无法识别系统的应用网络统计")
        case .command(let message): return L("无法读取应用网络统计：%@", message)
        }
    }
}

struct NetworkProcessFacts: Equatable, Sendable {
    var identity: String
    /// 从本进程到父进程的可执行文件路径，用来合并应用的辅助进程及终端子进程。
    var executablePaths: [String]
}

struct NetworkMonitorFrame: Sendable {
    var uptime: TimeInterval
    var date: Date
    var interfaces: [String: InterfaceCounters.Sample]
    var processes: [ProcessNetworkCounter]
    var facts: [Int32: NetworkProcessFacts]
}

struct NetworkApplicationRate: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var bundlePath: String?
    var download: Double
    var upload: Double
    var processes: [ProcessNetworkCounter]
    var total: Double { download + upload }

    func matches(_ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedCaseInsensitiveContains(query) || processes.contains {
            $0.name.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query)
        }
    }
}

enum NetworkTrafficMath {
    /// 取最外层应用，浏览器的嵌套 Helper.app 仍归到浏览器。
    static func applicationBundle(in executablePath: String) -> String? {
        guard executablePath.hasPrefix("/") else { return nil }
        var url = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        var found: String?
        while url.path != "/" && !url.path.isEmpty {
            if url.pathExtension.lowercased() == "app" { found = url.path }
            url.deleteLastPathComponent()
        }
        return found
    }

    static func rates(from previous: NetworkMonitorFrame, to current: NetworkMonitorFrame) -> [NetworkApplicationRate] {
        let seconds = current.uptime - previous.uptime
        guard seconds.isFinite, seconds > 0.2, seconds < 15 else { return [] }
        let old = Dictionary(uniqueKeysWithValues: previous.processes.map { ($0.pid, $0) })
        var applications: [String: NetworkApplicationRate] = [:]
        for process in current.processes {
            let facts = current.facts[process.pid]
            let bundle = facts?.executablePaths.lazy.compactMap(applicationBundle(in:)).first
            let identity = facts?.identity ?? "\(process.pid):\(process.name)"
            let key = bundle ?? "process:\(identity)"
            let name = bundle.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? process.name
            var rate = applications[key] ?? NetworkApplicationRate(id: key, name: name, bundlePath: bundle, download: 0, upload: 0, processes: [])
            rate.processes.append(process)
            if let before = old[process.pid], before.name == process.name,
               previous.facts[process.pid]?.identity == facts?.identity {
                // 进程/连接计数回退时重新建立基线，不能当成整数回绕产生巨大的假网速。
                if process.received >= before.received { rate.download += Double(process.received - before.received) / seconds }
                if process.sent >= before.sent { rate.upload += Double(process.sent - before.sent) / seconds }
            }
            applications[key] = rate
        }
        return applications.values.sorted { $0.id < $1.id }
    }

    static func displayBytes(_ rate: Double) -> Int {
        guard rate.isFinite else { return 0 }
        if rate >= Double(Int.max) { return Int.max }
        return Int(max(0, rate))
    }
}
