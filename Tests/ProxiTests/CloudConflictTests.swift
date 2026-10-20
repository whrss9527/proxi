import Foundation
import XCTest
import os
@testable import Proxi

final class CloudConflictTests: XCTestCase {
    /// 真实文件呈现者：更新协调必须先保存其待提交内容；替换/删除意图会走另一条回调。
    private final class Presenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        private let state: OSAllocatedUnfairLock<(pending: Data?, saves: Int, deletions: Int)>

        init(url: URL, pending: Data) {
            presentedItemURL = url
            state = OSAllocatedUnfairLock(initialState: (pending, 0, 0))
            super.init()
            presentedItemOperationQueue.maxConcurrentOperationCount = 1
        }

        var saves: Int { state.withLock { $0.saves } }
        var deletions: Int { state.withLock { $0.deletions } }

        func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
            let pending = state.withLock { state in
                state.saves += 1
                return state.pending
            }
            do {
                if let pending, let url = presentedItemURL { try pending.write(to: url, options: .atomic) }
                state.withLock { $0.pending = nil }
                completionHandler(nil)
            } catch { completionHandler(error) }
        }

        func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
            state.withLock { $0.deletions += 1 }
            completionHandler(nil)
        }
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud conflicts \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func synced(_ time: TimeInterval, _ device: String) -> SyncedConfig {
        SyncedConfig(updatedAt: Date(timeIntervalSince1970: time), device: device, config: AppConfig())
    }

    /// 版本替身只负责记录已处理的版本；不把普通临时文件描述成真实云服务冲突。
    private func conflict(_ url: URL, events: OSAllocatedUnfairLock<[String]>) -> CloudFile.Conflict {
        CloudFile.Conflict(url: url, resolve: { events.withLock { $0.append("resolve:\(url.lastPathComponent)") } }, remove: {
            events.withLock { $0.append("remove:\(url.lastPathComponent)") }
            try FileManager.default.removeItem(at: url)
        })
    }

    func testPresenterPendingNewerDocumentWinsWithoutDeletionRequest() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = folder.appendingPathComponent("config.json")
        let captured = folder.appendingPathComponent("captured.json")
        try CloudFile.encoder.encode(synced(1, "current")).write(to: current)
        try CloudFile.encoder.encode(synced(2, "conflict")).write(to: captured)
        let latest = synced(3, "presenter")
        let presenter = Presenter(url: current, pending: try CloudFile.encoder.encode(latest))
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let version = conflict(captured, events: events)
        let winner = try await Task.detached { try CloudFile.resolveConflicts(at: current, conflicts: [version]) }.value
        XCTAssertEqual(winner, latest)
        XCTAssertEqual(try CloudFile.read(at: current), latest)
        XCTAssertGreaterThan(presenter.saves, 0)
        XCTAssertEqual(presenter.deletions, 0)
        XCTAssertEqual(events.withLock { $0 }, ["resolve:captured.json", "remove:captured.json"])
    }

    func testCapturedWinnerKeepsUnknownFieldsAndOnlyCapturedVersionIsRemoved() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = folder.appendingPathComponent("config.json")
        let captured = folder.appendingPathComponent("captured.json")
        let later = folder.appendingPathComponent("later.json")
        try CloudFile.encoder.encode(synced(1, "current")).write(to: current)
        let oldFormat = Data(#"{"updatedAt":"1970-01-01T00:00:03Z","device":"legacy","config":{"format":2,"future":{"nested":7},"profiles":[]}}"#.utf8)
        try oldFormat.write(to: captured)
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let version = conflict(captured, events: events)
        let lateBytes = try CloudFile.encoder.encode(synced(4, "later"))
        // 候选捕获后新出现的版本不属于本次清理集合。
        try lateBytes.write(to: later)
        let winner = try CloudFile.resolveConflicts(at: current, conflicts: [version])
        XCTAssertEqual(winner?.device, "legacy")
        XCTAssertEqual(winner?.format, 1)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: current)) as? [String: Any])
        let config = try XCTUnwrap(result["config"] as? [String: Any])
        XCTAssertEqual((config["future"] as? [String: Int])?["nested"], 7)
        XCTAssertEqual(try Data(contentsOf: later), lateBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured.path))
        XCTAssertEqual(events.withLock { $0 }, ["resolve:captured.json", "remove:captured.json"])
    }

    func testPresenterSavingFutureFormatAbortsWithoutResolvingCapturedVersion() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = folder.appendingPathComponent("config.json")
        let captured = folder.appendingPathComponent("captured.json")
        try CloudFile.encoder.encode(synced(1, "current")).write(to: current)
        try CloudFile.encoder.encode(synced(2, "conflict")).write(to: captured)
        let bytes = Data(#"{"format":3,"config":"future pending document"}"#.utf8)
        let presenter = Presenter(url: current, pending: bytes)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let version = conflict(captured, events: events)
        do {
            _ = try await Task.detached { try CloudFile.resolveConflicts(at: current, conflicts: [version]) }.value
            XCTFail("presenter's future format must not be overwritten")
        } catch {
            guard case CloudFileError.newerFormat(3) = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: current), bytes)
        XCTAssertGreaterThan(presenter.saves, 0)
        XCTAssertEqual(presenter.deletions, 0)
        XCTAssertTrue(events.withLock { $0.isEmpty })
        XCTAssertTrue(FileManager.default.fileExists(atPath: captured.path))
    }

    func testFutureOrCorruptCurrentBytesAndVersionsRemainUntouched() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = folder.appendingPathComponent("config.json")
        let captured = folder.appendingPathComponent("captured.json")
        let candidate = try CloudFile.encoder.encode(synced(2, "conflict"))
        try candidate.write(to: captured)
        for raw in [#"{"format":3,"config":"future"}"#, #"{"format":2,"config":{"format":3}}"#, #"{"format":2,"config":"broken"}"#, "invalid"] {
            let bytes = Data(raw.utf8)
            try bytes.write(to: current)
            let events = OSAllocatedUnfairLock(initialState: [String]())
            XCTAssertThrowsError(try CloudFile.resolveConflicts(at: current, conflicts: [conflict(captured, events: events)]))
            XCTAssertEqual(try Data(contentsOf: current), bytes)
            XCTAssertEqual(try Data(contentsOf: captured), candidate)
            XCTAssertTrue(events.withLock { $0.isEmpty })
        }
    }

    func testInvalidCapturedVersionDoesNotWriteOrResolveAnyVersion() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = folder.appendingPathComponent("config.json")
        let good = folder.appendingPathComponent("good.json")
        let bad = folder.appendingPathComponent("bad.json")
        let bytes = try CloudFile.encoder.encode(synced(1, "current"))
        try bytes.write(to: current)
        try CloudFile.encoder.encode(synced(2, "good")).write(to: good)
        for raw in [#"{"format":3,"config":{}}"#, #"{"format":2,"config":{"format":3}}"#, "broken"] {
            try Data(raw.utf8).write(to: bad)
            let events = OSAllocatedUnfairLock(initialState: [String]())
            XCTAssertThrowsError(try CloudFile.resolveConflicts(at: current, conflicts: [conflict(good, events: events), conflict(bad, events: events)]))
            XCTAssertEqual(try Data(contentsOf: current), bytes)
            XCTAssertTrue(events.withLock { $0.isEmpty })
            XCTAssertTrue(FileManager.default.fileExists(atPath: good.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
        }
    }

    func testAtomicWriteFailureDoesNotResolveOrRemoveCapturedVersions() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = folder.appendingPathComponent("config.json")
        let captured = folder.appendingPathComponent("captured.json")
        let bytes = try CloudFile.encoder.encode(synced(1, "current"))
        try bytes.write(to: current)
        try CloudFile.encoder.encode(synced(2, "conflict")).write(to: captured)
        let events = OSAllocatedUnfairLock(initialState: [String]())
        XCTAssertThrowsError(try CloudFile.resolveConflicts(at: current, conflicts: [conflict(captured, events: events)], writeData: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }))
        XCTAssertEqual(try Data(contentsOf: current), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captured.path))
        XCTAssertTrue(events.withLock { $0.isEmpty })
    }

    func testNoConflictsDoesNotRewriteCurrentFile() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = folder.appendingPathComponent("config.json")
        let bytes = Data("not a cloud document".utf8)
        try bytes.write(to: current)
        XCTAssertNil(try CloudFile.resolveConflicts(at: current, conflicts: []))
        XCTAssertEqual(try Data(contentsOf: current), bytes)
    }
}
