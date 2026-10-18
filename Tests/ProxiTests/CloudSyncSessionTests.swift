import Combine
import XCTest
@testable import Proxi

final class CloudSyncSessionTests: XCTestCase {
    private final class Gate {
        let entered = XCTestExpectation(description: "文件操作开始")
        private let semaphore = DispatchSemaphore(value: 0)

        func wait() {
            entered.fulfill()
            XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success)
        }

        func release() { semaphore.signal() }
    }

    private func config(_ name: String) -> AppConfig {
        var config = AppConfig()
        config.profiles = [Profile(name: name, color: "#111111", host: "127.0.0.1", port: 8080)]
        return config
    }

    private func synced(_ config: AppConfig) -> SyncedConfig {
        SyncedConfig(updatedAt: Date(timeIntervalSince1970: 1_700_000_000), device: "另一台 Mac", config: config)
    }

    private func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-session-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    @MainActor
    func testDisabledPullCannotApplyRemoteCreateFileOrReportError() async throws {
        let local = config("本机")
        let remote = synced(config("云端"))
        let outcomes: [Result<SyncedConfig?, Error>] = [.success(remote), .success(nil), .failure(CloudFileError.unavailable)]
        for outcome in outcomes {
            let gate = Gate()
            defer { gate.release() }
            var reads = 0
            var writes = 0
            var applied: [AppConfig] = []
            let io = CloudSyncIO(read: { _ in
                reads += 1
                if reads == 1 { return self.synced(local) }
                gate.wait()
                return try outcome.get()
            }, write: { _, _ in writes += 1 })
            let sync = CloudSync(folder: folder(), io: io)
            sync.currentConfig = { local }
            sync.applyRemote = { applied.append($0) }
            await sync.enable()
            let baselineWrites = writes
            let task = Task { await sync.syncNow() }
            await fulfillment(of: [gate.entered], timeout: 3)
            sync.disable()
            gate.release()
            await task.value
            XCTAssertTrue(applied.isEmpty)
            XCTAssertEqual(writes, baselineWrites)
            XCTAssertFalse(sync.enabled)
            XCTAssertNil(sync.pending)
            XCTAssertEqual(sync.status, .off)
        }
    }

    @MainActor
    func testDisabledWriteCannotRestoreSyncedOrErrorStatus() async {
        for fail in [false, true] {
            let gate = Gate()
            defer { gate.release() }
            var completedWrites = 0
            let io = CloudSyncIO(read: { _ in nil }, write: { _, _ in
                gate.wait()
                completedWrites += 1
                if fail { throw CloudFileError.unavailable }
            })
            let sync = CloudSync(folder: folder(), io: io)
            let task = Task { await sync.enable() }
            await fulfillment(of: [gate.entered], timeout: 3)
            sync.disable()
            gate.release()
            await task.value
            XCTAssertEqual(completedWrites, 1)
            XCTAssertFalse(sync.enabled)
            XCTAssertNil(sync.pending)
            XCTAssertEqual(sync.status, .off)
        }
    }

    @MainActor
    func testCancelledInitialReadCannotEnableOrRestoreChoiceOrError() async {
        let remote = synced(config("云端"))
        let outcomes: [Result<SyncedConfig?, Error>] = [.success(remote), .success(nil), .failure(CloudFileError.unavailable)]
        for outcome in outcomes {
            let gate = Gate()
            defer { gate.release() }
            var enabledFlags: [Bool] = []
            var writes = 0
            let io = CloudSyncIO(read: { _ in
                gate.wait()
                return try outcome.get()
            }, write: { _, _ in writes += 1 })
            let sync = CloudSync(folder: folder(), io: io)
            sync.onEnabledChanged = { enabledFlags.append($0) }
            let task = Task { await sync.enable() }
            await fulfillment(of: [gate.entered], timeout: 3)
            sync.cancelEnable()
            gate.release()
            await task.value
            XCTAssertFalse(sync.enabled)
            XCTAssertNil(sync.pending)
            XCTAssertEqual(sync.status, .off)
            XCTAssertTrue(enabledFlags.isEmpty)
            XCTAssertEqual(writes, 0)
        }
    }

    @MainActor
    func testResolvingAfterDisableDoesNotApplyAnyChoice() async {
        for choice in [CloudSync.Choice.useCloud, .useLocal, .merge] {
            let local = config("本机")
            let remote = synced(config("云端"))
            let unexpectedEnable = expectation(description: "关闭后不能重新启用")
            unexpectedEnable.isInverted = true
            var applied: [AppConfig] = []
            var writes = 0
            let io = CloudSyncIO(read: { _ in remote }, write: { _, _ in writes += 1 })
            let sync = CloudSync(folder: folder(), io: io)
            sync.currentConfig = { local }
            sync.applyRemote = { applied.append($0) }
            sync.onEnabledChanged = { if $0 { unexpectedEnable.fulfill() } }
            await sync.enable()
            XCTAssertNotNil(sync.pending)
            sync.resolve(choice)
            sync.disable()
            await fulfillment(of: [unexpectedEnable], timeout: 0.1)
            XCTAssertTrue(applied.isEmpty)
            XCTAssertEqual(writes, 0)
            XCTAssertFalse(sync.enabled)
            XCTAssertNil(sync.pending)
            XCTAssertEqual(sync.status, .off)
        }
    }

    @MainActor
    func testRepeatedEnableSharesInitialRead() async {
        let gate = Gate()
        defer { gate.release() }
        let remote = synced(config("云端"))
        var reads = 0
        let io = CloudSyncIO(read: { _ in
            reads += 1
            if reads == 1 { gate.wait() }
            return remote
        }, write: { _, _ in XCTFail("等待选择时不能写文件") })
        let sync = CloudSync(folder: folder(), io: io)
        let first = Task { await sync.enable() }
        await fulfillment(of: [gate.entered], timeout: 3)
        let second = Task { await sync.enable() }
        gate.release()
        await first.value
        await second.value
        await sync.enable()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(sync.pending, remote)
        sync.cancelEnable()
    }

    @MainActor
    func testOldPullCannotApplyDuringReenable() async {
        let gate = Gate()
        defer { gate.release() }
        let local = config("本机")
        let remote = synced(config("旧云端"))
        var reads = 0
        var applied: [AppConfig] = []
        let io = CloudSyncIO(read: { _ in
            reads += 1
            if reads == 2 {
                gate.wait()
                return remote
            }
            return self.synced(local)
        }, write: { _, _ in })
        let sync = CloudSync(folder: folder(), io: io)
        sync.currentConfig = { local }
        sync.applyRemote = { applied.append($0) }
        await sync.enable()
        let old = Task { await sync.syncNow() }
        await fulfillment(of: [gate.entered], timeout: 3)
        sync.disable()
        let fresh = Task { await sync.enable() }
        gate.release()
        await old.value
        await fresh.value
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(sync.enabled)
        XCTAssertNil(sync.pending)
        guard case .synced = sync.status else { return XCTFail("新会话没有同步成功") }
        sync.disable()
    }

    @MainActor
    func testStartedOldWriteFinishesBeforeNewSessionWrite() async {
        let gate = Gate()
        defer { gate.release() }
        let oldConfig = config("旧本机")
        let newConfig = config("新本机")
        var written: [AppConfig] = []
        let io = CloudSyncIO(read: { _ in nil }, write: { snapshot, _ in
            if written.isEmpty { gate.wait() }
            written.append(snapshot.config)
        })
        let sync = CloudSync(folder: folder(), io: io)
        sync.currentConfig = { oldConfig }
        let old = Task { await sync.enable() }
        await fulfillment(of: [gate.entered], timeout: 3)
        sync.disable()
        sync.currentConfig = { newConfig }
        let fresh = Task { await sync.enable() }
        gate.release()
        await old.value
        await fresh.value
        XCTAssertEqual(written, [oldConfig, newConfig])
        XCTAssertTrue(sync.enabled)
        guard case .synced = sync.status else { return XCTFail("新会话没有同步成功") }
        sync.disable()
    }

    @MainActor
    func testInvalidatedSessionSkipsQueuedReadWriteAndMigration() async throws {
        let gate = Gate()
        defer { gate.release() }
        let snapshot = synced(config("本机"))
        var reads = 0
        var writes = 0
        var migrations = 0
        let io = CloudSyncIO(read: { _ in
            reads += 1
            return nil
        }, write: { _, _ in
            writes += 1
            gate.wait()
        }, migrate: {
            migrations += 1
            return false
        })
        let session = CloudSyncSession()
        let file = folder().appendingPathComponent("config.json")
        let started = Task { try await io.write(snapshot, to: file, session: session) }
        await fulfillment(of: [gate.entered], timeout: 3)
        let read = Task { try await io.read(at: file, session: session) }
        let write = Task { try await io.write(snapshot, to: file, session: session) }
        let migrate = Task { try await io.migrate(session: session) }
        session.invalidate()
        gate.release()
        _ = try await started.value
        do {
            _ = try await read.value
            XCTFail("旧读取没有取消")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await write.value
            XCTFail("旧写入没有取消")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await migrate.value
            XCTFail("旧迁移没有取消")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(migrations, 0)
    }

    @MainActor
    func testValidInitialChoicesKeepCloudLocalAndMergeBehavior() async {
        for choice in [CloudSync.Choice.useCloud, .useLocal, .merge] {
            let local = config("本机")
            let remote = synced(config("云端"))
            var current = local
            var written: [AppConfig] = []
            let io = CloudSyncIO(read: { _ in remote }, write: { snapshot, _ in written.append(snapshot.config) })
            let sync = CloudSync(folder: folder(), io: io)
            sync.currentConfig = { current }
            sync.applyRemote = { current = $0 }
            await sync.enable()
            let completed = expectation(description: "有效选择完成同步")
            let observation = sync.$status.sink { status in
                if case .synced = status { completed.fulfill() }
            }
            sync.resolve(choice)
            await fulfillment(of: [completed], timeout: 3)
            observation.cancel()
            XCTAssertTrue(sync.enabled)
            XCTAssertNil(sync.pending)
            switch choice {
            case .useCloud:
                XCTAssertEqual(current, remote.config)
                XCTAssertTrue(written.isEmpty)
            case .useLocal:
                XCTAssertEqual(current, local)
                XCTAssertEqual(written, [local])
            case .merge:
                XCTAssertEqual(current.profiles.map(\.name), ["云端", "本机"])
                XCTAssertEqual(written, [current])
            }
            sync.disable()
        }
    }
}
