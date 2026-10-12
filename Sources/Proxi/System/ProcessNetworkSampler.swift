import Darwin
import Foundation

/// 只读系统进程计数，不安装助手、不提权，也不读取连接地址或数据包内容。
enum ProcessNetworkSampler {
    static let arguments = ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]

    static func read() async throws -> NetworkMonitorFrame {
        let result = try await Shell.run("/usr/bin/nettop", arguments, timeout: 6)
        guard result.succeeded else { throw NetworkMonitorError.command(Redact.secrets(result.trimmedOutput)) }
        let processes = try NettopOutput.parse(result.output)
        var metadata: [Int32: ProcessInfoSnapshot] = [:]
        var facts: [Int32: NetworkProcessFacts] = [:]
        for process in processes {
            var pid = process.pid
            var paths: [String] = []
            var identity = "\(process.pid):\(process.name)"
            var visited = Set<Int32>()
            for depth in 0..<6 {
                guard pid > 1, visited.insert(pid).inserted else { break }
                let info = metadata[pid] ?? processInfo(pid)
                guard let info else { break }
                metadata[pid] = info
                if depth == 0 { identity += ":\(info.started):\(info.path)" }
                if !info.path.isEmpty { paths.append(info.path) }
                if NetworkTrafficMath.applicationBundle(in: info.path) != nil { break }
                pid = info.parent
            }
            facts[process.pid] = NetworkProcessFacts(identity: identity, executablePaths: paths)
        }
        return NetworkMonitorFrame(uptime: ProcessInfo.processInfo.systemUptime, date: Date(), interfaces: InterfaceCounters.read(), processes: processes, facts: facts)
    }

    private struct ProcessInfoSnapshot {
        var parent: Int32
        var started: String
        var path: String
    }

    private static func processInfo(_ pid: Int32) -> ProcessInfoSnapshot? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var path = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let count = UInt32(path.count)
        let length = path.withUnsafeMutableBytes { buffer -> Int32 in
            guard let address = buffer.baseAddress else { return 0 }
            return proc_pidpath(pid, address, count)
        }
        return ProcessInfoSnapshot(parent: Int32(info.pbi_ppid), started: "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)",
                                   path: length > 0 ? String(cString: path) : "")
    }
}
