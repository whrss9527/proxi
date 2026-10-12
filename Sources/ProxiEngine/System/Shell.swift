import Foundation
import ProxiProcess

struct ShellResult: Sendable {
    let output: String
    let status: Int32

    var succeeded: Bool { status == 0 }
    var trimmedOutput: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum ShellError: LocalizedError {
    case timeout(String)
    case launchFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .timeout(let name): return L("%@ 执行超时", name)
        case .launchFailed(let name, let reason): return L("无法运行 %@：%@", name, reason)
        }
    }
}

/// 超时的计时器动过手没有（计时器在别的线程上跑）。
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func set() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

/// 异步命令用事件回调等待；runSync 仅供独立同步入口使用。
enum Shell {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) async throws -> ShellResult {
        do {
            let result = try await ProcessCommand.run(executable, arguments, timeout: timeout)
            return ShellResult(output: result.output, status: result.status)
        } catch CommandError.timeout {
            throw ShellError.timeout((executable as NSString).lastPathComponent)
        } catch CommandError.launchFailed(let reason) {
            throw ShellError.launchFailed((executable as NSString).lastPathComponent, reason)
        }
    }

    static func runSync(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed((executable as NSString).lastPathComponent, error.localizedDescription)
        }
        let fired = TimeoutFlag()
        let timer = DispatchWorkItem { [process] in
            guard process.isRunning else { return }
            fired.set()
            process.terminate()
            // 不理 SIGTERM 的进程过两秒强制结束，不然一直等不到输出的结尾。
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // 先读完输出再等待结束，否则管道写满时进程会卡住。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        // 只看计时器有没有动过手：进程自己因为信号崩溃不算超时。
        if fired.value {
            throw ShellError.timeout((executable as NSString).lastPathComponent)
        }
        return ShellResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
    }

    /// 找到 PATH 里的命令；图形程序的 PATH 很短，补上常见的位置。
    static func lookPath(_ name: String) -> String? {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for directory in directories {
            let path = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// 把文字写成 AppleScript 的字符串字面量。
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 把参数写成 shell 的单引号字面量。
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
