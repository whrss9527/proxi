import Darwin
import Foundation

/// PID 会复用；清理前核对用户和出生时间，不对身份已变化的进程继续发信号。
struct CoreProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let uid: UInt32
    let seconds: UInt64
    let microseconds: UInt64

    static func read(_ pid: Int32) -> CoreProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // BSD 的 SZOMB 为 5：僵尸已释放套接字，不再把它当作待停止的内核。
        guard info.pbi_status != 5 else { return nil }
        return Self(pid: pid, uid: info.pbi_uid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    static func isCore(_ pid: Int32, configs: [URL]) -> Bool {
        var path = [CChar](repeating: 0, count: 4096)
        let capacity = UInt32(path.count)
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress!, capacity) }
        guard length > 0,
              URL(fileURLWithPath: String(cString: path)).lastPathComponent == CoreBinary.name,
              let arguments = arguments(pid), let index = arguments.firstIndex(of: "-f"),
              arguments.indices.contains(index + 1) else { return false }
        let config = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        return configs.contains { $0.standardizedFileURL == config }
    }

    /// KERN_PROCARGS2 保留参数边界，路径里的空格不会被误拆，也不把其他进程的描述文字当配置路径。
    private static func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size >= 4, size <= 1 << 20 else { return nil }
        var data = Data(count: size)
        let loaded = data.withUnsafeMutableBytes { buffer in sysctl(&mib, 3, buffer.baseAddress, &size, nil, 0) }
        guard loaded == 0 else { return nil }
        let count = data.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard (1...4096).contains(count) else { return nil }
        let bytes = [UInt8](data.prefix(size))
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            guard index < bytes.count else { return nil }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    func stop(grace: Duration = .seconds(3), killGrace: Duration = .seconds(2)) async throws {
        guard Self.read(pid) == self else { return }
        kill(pid, SIGTERM)
        if try await waitForExit(grace) { return }
        guard Self.read(pid) == self else { return }
        kill(pid, SIGKILL)
        guard try await waitForExit(killGrace) else {
            throw CoreRunnerError.notReady(L("内核进程未在期限内退出，已取消后续启动"))
        }
    }

    private func waitForExit(_ duration: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while Self.read(pid) == self {
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(25))
        }
        return true
    }
}
