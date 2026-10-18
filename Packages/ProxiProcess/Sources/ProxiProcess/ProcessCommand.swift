import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct CommandResult: Sendable {
    public let output: String
    public let status: Int32
}

public enum CommandError: Error {
    case timeout
    case launchFailed(String)
}

public enum ProcessCommand {
    /// 等待期间不占用 Swift 协作线程。取消和超时均先终止进程，两秒后强制结束。
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) async throws -> CommandResult {
        let execution = Execution(executable: executable, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

/// 初始化后，所有可变状态只在 queue 上访问；回调只向该队列投递事件。
private final class Execution: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Proxi.ProcessCommand", qos: .userInitiated)
    private let process = Process()
    private let pipe = Pipe()
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var output = Data()
    private var descriptor: Int32 = -1
    private var reader: DispatchSourceRead?
    private var exited = false
    private var eof = false
    private var completed = false
    private var cancelled = false
    private var failure: Error?
    private var timer: DispatchWorkItem?
    private var escalation: DispatchWorkItem?

    init(executable: String, arguments: [String], timeout: TimeInterval) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        self.timeout = timeout
    }

    func start(_ continuation: CheckedContinuation<CommandResult, Error>) {
        queue.async { self.begin(continuation) }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            // onCancel 可以比 begin 更早执行；那种情况根本不启动进程。
            if self.continuation != nil { self.stop(CancellationError()) }
        }
    }

    // 以下方法只在 queue 上调用。
    private func begin(_ continuation: CheckedContinuation<CommandResult, Error>) {
        self.continuation = continuation
        if cancelled {
            finish(.failure(CancellationError()))
            return
        }
        // DispatchSource 独占一个描述符，取消回调确认不再读取后才能关闭，避免句柄复用竞态。
        descriptor = dup(pipe.fileHandleForReading.fileDescriptor)
        guard descriptor >= 0 else {
            finish(.failure(CommandError.launchFailed(String(cString: strerror(errno)))))
            return
        }
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            finish(.failure(CommandError.launchFailed(reason)))
            return
        }
        // 不把这个额外的读端传给子进程。
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            finish(.failure(CommandError.launchFailed(reason)))
            return
        }
        let descriptor = descriptor
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setEventHandler { [self] in
            readOutput()
            completeIfReady()
        }
        reader.setCancelHandler { close(descriptor) }
        self.reader = reader
        reader.resume()
        process.terminationHandler = { [self] _ in
            // Foundation 回调内部可能持有自己的锁，先投递事件再返回。
            queue.async {
                self.exited = true
                self.readOutput()
                self.completeIfReady()
            }
        }
        do {
            // Process.run 本身也可能等待启动；这里运行在 Dispatch 队列，不占协作线程。
            try process.run()
            try? pipe.fileHandleForWriting.close()
        } catch {
            finish(.failure(CommandError.launchFailed(error.localizedDescription)))
            return
        }
        let timer = DispatchWorkItem { [weak self] in self?.stop(CommandError.timeout) }
        self.timer = timer
        queue.asyncAfter(deadline: .now() + max(0, timeout), execute: timer)
    }

    private func stop(_ error: Error) {
        guard !completed, failure == nil else { return }
        failure = error
        if process.isRunning { process.terminate() }
        let escalation = DispatchWorkItem { [weak self] in
            guard let self, !self.completed else { return }
            if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
            // 后代可能持有输出管道；部分 Foundation 实现还会延迟退出通知。
            // 直接进程已被终止后按截止时间返回，不无限等待后代关闭管道。
            self.finish(.failure(error))
        }
        self.escalation = escalation
        queue.asyncAfter(deadline: .now() + 2, execute: escalation)
    }

    private func readOutput() {
        guard !completed, !eof else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        // 连续输出不能占住队列；分批让出执行机会，使超时和取消及时生效。
        for _ in 0..<16 {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                eof = true
                reader?.cancel()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                stop(CommandError.launchFailed(String(cString: strerror(errno))))
                return
            }
        }
        queue.async {
            self.readOutput()
            self.completeIfReady()
        }
    }

    private func completeIfReady() {
        guard exited, eof, !completed else { return }
        if let failure {
            finish(.failure(failure))
        } else {
            finish(.success(CommandResult(output: String(decoding: output, as: UTF8.self), status: process.terminationStatus)))
        }
    }

    private func finish(_ result: Result<CommandResult, Error>) {
        guard !completed else { return }
        completed = true
        timer?.cancel()
        escalation?.cancel()
        process.terminationHandler = nil
        reader?.setEventHandler {}
        reader?.cancel()
        reader = nil
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
