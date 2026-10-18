import Foundation

final class CloudSyncSession: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if !active { throw CancellationError() }
    }
}

/// 文件操作只在同一串行队列执行，已开始的旧写入先于新会话完成。
final class CloudSyncIO: @unchecked Sendable {
    struct Snapshot: @unchecked Sendable {
        let synced: SyncedConfig?
        let stamp: String?
    }

    private let queue = DispatchQueue(label: "com.whrss9527.proxi.cloud-sync", qos: .utility)
    private let readFile: (URL) throws -> SyncedConfig?
    private let writeFile: (SyncedConfig, URL) throws -> Void
    private let migrateFolder: () -> Bool

    init(
        read: @escaping (URL) throws -> SyncedConfig? = {
            try CloudFile.resolveConflicts(at: $0) ?? CloudFile.read(at: $0)
        },
        write: @escaping (SyncedConfig, URL) throws -> Void = CloudFile.write,
        migrate: @escaping () -> Bool = { CloudFile.migrateLegacyFolder() }
    ) {
        readFile = read
        writeFile = write
        migrateFolder = migrate
    }

    func read(at url: URL, session: CloudSyncSession) async throws -> Snapshot {
        try await perform(session: session) {
            let synced = try self.readFile(url)
            return Snapshot(synced: synced, stamp: CloudFile.stamp(of: url))
        }
    }

    func write(_ synced: SyncedConfig, to url: URL, session: CloudSyncSession) async throws -> String? {
        try await perform(session: session) {
            try self.writeFile(synced, url)
            return CloudFile.stamp(of: url)
        }
    }

    func migrate(session: CloudSyncSession) async throws -> Bool {
        try await perform(session: session) { self.migrateFolder() }
    }

    private func perform<Value: Sendable>(
        session: CloudSyncSession,
        operation: @escaping () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async(execute: DispatchWorkItem {
                continuation.resume(with: Result {
                    try session.check()
                    // 已进入文件协调的操作可能完成，失效只阻止排队操作和结果提交。
                    return try operation()
                })
            })
        }
    }
}
