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
                // Process.run 本身也可能等待子进程启动，放到 Dispatch 线程上。
                DispatchQueue.global(qos: .userInitiated).async {
                    execution.start(continuation)
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

/// 所有可变状态（包括输出读取、句柄关闭和 Process 操作）由 lock 保护。
private final class Execution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let pipe = Pipe()
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var output = Data()
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
        lock.withLock {
            self.continuation = continuation
            if cancelled {
                finish(.failure(CancellationError()))
                return
            }
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            // 退出与读取回调可能同时到达；非阻塞读取也能识别“已退出但后代还持有写端”。
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
                finish(.failure(CommandError.launchFailed(String(cString: strerror(errno)))))
                return
            }
            pipe.fileHandleForReading.readabilityHandler = { @Sendable [self] _ in
                // Foundation 的回调内部可能持有自己的锁，不能在这里等待状态锁。
                DispatchQueue.global().async {
                    self.lock.withLock {
                        self.readOutput()
                        self.completeIfReady()
                    }
                }
            }
            process.terminationHandler = { [self] _ in
                DispatchQueue.global().async {
                    self.lock.withLock {
                        self.exited = true
                        self.readOutput()
                        self.completeIfReady()
                    }
                }
            }
            do {
                try process.run()
                // 父进程不写管道；否则子进程退出后也可能收不到 EOF。
                try? pipe.fileHandleForWriting.close()
            } catch {
                finish(.failure(CommandError.launchFailed(error.localizedDescription)))
                return
            }
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.stop(CommandError.timeout) }
            }
            self.timer = timer
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout), execute: timer)
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            // onCancel 可以比 start 更早执行；那种情况根本不启动进程。
            if continuation != nil { stop(CancellationError()) }
        }
    }

    // 以下方法只在持有 lock 时调用。
    private func stop(_ error: Error) {
        guard !completed, failure == nil else { return }
        failure = error
        if process.isRunning { process.terminate() }
        let escalation = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard !self.completed else { return }
                if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
                // 子进程的后代可能仍持有写端；到截止时间就停止收集输出。
                self.pipe.fileHandleForReading.readabilityHandler = nil
                try? self.pipe.fileHandleForReading.close()
                self.eof = true
                // 部分 Foundation 实现会等后代关闭内部管道才通知父进程退出。
                // 已发送 SIGKILL 后按截止时间返回，不再等待这个通知。
                self.finish(.failure(self.failure ?? error))
            }
        }
        self.escalation = escalation
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: escalation)
    }

    private func readOutput() {
        guard !completed, !eof else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        // 连续写入的命令不能一直占住锁，否则超时和取消也无法生效。
        for _ in 0..<16 {
            let count = read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                eof = true
                pipe.fileHandleForReading.readabilityHandler = nil
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
        DispatchQueue.global().async { [self] in
            lock.withLock {
                readOutput()
                completeIfReady()
            }
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
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
