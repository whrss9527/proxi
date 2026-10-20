import Foundation
import Darwin

/// 打包在 app 里的内核和数据文件。
enum CoreBinary {
    static let name = "mihomo"

    /// 内核程序：开启代理引擎时下载到数据目录的 bin/mihomo（见 CoreDownload.swift，校验过 SHA-256）。
    /// 开发时可以用环境变量 PROXI_CORE 指定。
    static var executableURL: URL? {
        if let override = ProcessInfo.processInfo.environment["PROXI_CORE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return installedPath.map { URL(fileURLWithPath: $0) }
    }

    /// 下载好的那份内核（不看环境变量）：装特权助手时复制它，助手那边再校验一遍。
    static var installedPath: String? {
        let url = CoreDownload.coreURL
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    /// GeoIP 数据库（按 IP 归属地分流的规则要用），和内核一起下载。
    static var geoIPURL: URL? {
        let url = CoreDownload.geoIPURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum CoreRunnerError: LocalizedError {
    case missingBinary
    case launchFailed(String)
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .missingBinary: return L("还没有下载内核，到设置的「内核」页下载")
        case .launchFailed(let text): return L("内核启动失败：%@", text)
        case .notReady(let text): return L("内核没有正常启动：%@", text)
        }
    }
}

/// 生命周期状态只在 worker 访问；公开的 PID 快照单独加锁，读状态不会等停止操作。
/// 日志仍由独立队列管理。队列任务持有 self，异步调用方不接触 Process。
final class CoreRunner: @unchecked Sendable {
    private let worker = DispatchQueue(label: "com.whrss9527.proxyswitch.core.lifecycle", qos: .userInitiated)
    private let queue = DispatchQueue(label: "com.whrss9527.proxyswitch.core.log")
    private let stateLock = NSLock()
    private var snapshotPID: Int32?
    private var snapshotID: UUID?
    private var process: Process?
    private var runID: UUID?
    private var exited: DispatchSemaphore?
    private var pipe: Pipe?
    private var identity: CoreProcessIdentity?
    private let grace: TimeInterval
    private let killGrace: TimeInterval
    private let readIdentity: @Sendable (Int32) -> CoreProcessIdentity?
    private var lines: [String] = []
    private var logHandle: FileHandle?
    private var pending = ""
    private var logID: UUID?

    @MainActor var onExit: (@MainActor (Int32) -> Void)?

    init(grace: TimeInterval = 3, killGrace: TimeInterval = 2,
         readIdentity: @escaping @Sendable (Int32) -> CoreProcessIdentity? = { CoreProcessIdentity.read($0) }) {
        self.grace = grace
        self.killGrace = killGrace
        self.readIdentity = readIdentity
    }

    var isRunning: Bool { pid != nil }
    var pid: Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return snapshotPID
    }

    var logTail: String { queue.sync { lines.suffix(200).joined(separator: "\n") } }

    func start(executable: URL, directory: URL, config: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async {
                continuation.resume(with: Result { try self.launch(executable: executable, directory: directory, config: config) })
            }
        }
    }

    func stop() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async { continuation.resume(with: Result { try self.stopOwnedProcess() }) }
        }
    }

    private func updatePID(_ pid: Int32?, id: UUID? = nil) {
        stateLock.lock()
        snapshotPID = pid
        snapshotID = id
        stateLock.unlock()
    }

    private func launch(executable: URL, directory: URL, config: URL) throws {
        try stopOwnedProcess()
        let process = Process()
        let pipe = Pipe()
        let id = UUID()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = ["-d", directory.path, "-f", config.path]
        process.currentDirectoryURL = directory
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        queue.sync { openLog(in: directory, id: id) }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.append(data, id: id) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            exited.signal()
            self?.worker.async { [weak self] in self?.didExit(id: id, status: status) }
        }
        self.process = process
        self.pipe = pipe
        self.runID = id
        self.exited = exited
        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
            identity = readIdentity(process.processIdentifier)
            updatePID(process.processIdentifier, id: id)
        } catch {
            releaseProcess()
            throw CoreRunnerError.launchFailed(error.localizedDescription)
        }
    }

    /// 等待只占这条独立队列；退出回调直接 signal，不需要等 worker 才能结束等待。
    private func stopOwnedProcess() throws {
        guard let process else { return }
        guard process.isRunning else { releaseProcess(); return }
        guard let identity, readIdentity(process.processIdentifier) == identity else {
            throw CoreRunnerError.notReady(L("无法确认内核进程身份，未发送停止信号"))
        }
        process.terminate()
        if exited?.wait(timeout: .now() + grace) == .timedOut, process.isRunning {
            guard readIdentity(process.processIdentifier) == identity else {
                throw CoreRunnerError.notReady(L("无法确认内核进程身份，未发送停止信号"))
            }
            kill(process.processIdentifier, SIGKILL)
            _ = exited?.wait(timeout: .now() + killGrace)
        }
        guard !process.isRunning else { throw CoreRunnerError.notReady(L("内核进程未在期限内退出，已取消后续启动")) }
        releaseProcess()
    }

    private func releaseProcess(exitID: UUID? = nil) {
        process?.terminationHandler = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        try? pipe?.fileHandleForReading.close()
        try? pipe?.fileHandleForWriting.close()
        process = nil
        pipe = nil
        identity = nil
        runID = nil
        exited = nil
        updatePID(nil, id: exitID)
    }

    private func didExit(id: UUID, status: Int32) {
        guard runID == id else { return }
        append(Data("[Proxi] 内核退出，状态 \(status)\n".utf8), id: id)  // l10n-ignore：内核日志
        releaseProcess(exitID: id)
        Task { @MainActor [weak self] in
            guard let self, self.isLatest(id) else { return }
            self.onExit?(status)
        }
    }

    private func isLatest(_ id: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return snapshotID == id
    }

    /// 枚举命令复用异步 Shell 边界；只清理本用户、参数完全匹配的 mihomo。
    static func killStrays(configs: [URL]) async throws {
        let result = try await Shell.run("/usr/bin/pgrep", ["-u", String(geteuid()), "-x", CoreBinary.name], timeout: 5)
        guard result.status == 0 || result.status == 1 else { throw CoreRunnerError.notReady(result.trimmedOutput) }
        for value in result.output.split(whereSeparator: \.isWhitespace) {
            guard let pid = Int32(value), let identity = CoreProcessIdentity.read(pid),
                  identity.uid == geteuid(), CoreProcessIdentity.isCore(pid, configs: configs) else { continue }
            try await identity.stop()
        }
    }

    private func openLog(in directory: URL, id: UUID) {
        try? logHandle?.close()
        let url = directory.appendingPathComponent("core.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
        try? logHandle?.truncate(atOffset: 0)
        logID = id
        pending = ""
    }

    private func append(_ data: Data, id: UUID) {
        queue.async {
            guard self.logID == id else { return }
            self.logHandle?.write(data)
            self.pending += String(decoding: data, as: UTF8.self)
            var parts = self.pending.components(separatedBy: "\n")
            self.pending = parts.removeLast()
            self.lines.append(contentsOf: parts.filter { !$0.isEmpty })
            if self.lines.count > 400 { self.lines.removeFirst(self.lines.count - 400) }
        }
    }
}
