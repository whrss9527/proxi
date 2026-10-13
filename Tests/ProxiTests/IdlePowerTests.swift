import AppKit
import Combine
import XCTest
@testable import Proxi

final class IdlePowerTests: XCTestCase {
    @MainActor
    func testStatusImageOnlyChangesWhenDisplayedContentOrAppearanceChanges() {
        let updates = StatusImageUpdates()
        var input = StatusImageInput(state: .off, upload: SpeedFormatter.compact(bytesPerSecond: 100_000),
                                     download: "0.00B", textColor: NSColor.black.cgColor, appearance: "light")
        XCTAssertNotNil(updates.imageIfChanged(input))
        input.upload = SpeedFormatter.compact(bytesPerSecond: 100_001)
        XCTAssertNil(updates.imageIfChanged(input), "原始字节数变化、显示不变时复用按钮已有的图像")
        input.download = "1.00K"
        XCTAssertNotNil(updates.imageIfChanged(input))
        input.state = .on(.systemBlue)
        XCTAssertNotNil(updates.imageIfChanged(input))
        input.state = .warning(.systemBlue)
        XCTAssertNotNil(updates.imageIfChanged(input))
        input.textColor = NSColor.white.cgColor
        XCTAssertNotNil(updates.imageIfChanged(input))
        input.layout = .speedOnly
        XCTAssertNotNil(updates.imageIfChanged(input))
        input.appearance = "dark"
        XCTAssertNotNil(updates.imageIfChanged(input))
        input.upload = nil
        input.download = nil
        XCTAssertNotNil(updates.imageIfChanged(input), "关闭网速显示时立即移除文字")
        XCTAssertNil(updates.imageIfChanged(input))
    }

    @MainActor
    func testDisabledExtensionHasNoPollingAndEnablingRestartsIt() {
        var state = ExtensionState()
        var reads = 0
        let manager = ExtensionManager(readStatus: { reads += 1; return nil })
        manager.readState = { state }
        manager.writeState = { state = $0 }
        manager.start()
        XCTAssertFalse(manager.isPolling)
        manager.poll()
        XCTAssertEqual(reads, 0)
        manager.accept()
        XCTAssertTrue(manager.isPolling)
        // 注入本机开关状态，避免测试退出用户正在运行的扩展。
        state.enabled = false
        manager.poll()
        XCTAssertFalse(manager.isPolling)
        XCTAssertEqual(reads, 0)
    }

    @MainActor
    func testHeartbeatsDoNotPublishButChangesAndDeathDo() {
        var state = ExtensionState()
        state.enabled = true
        var file: ExtensionStatus? = ExtensionStatus(version: "1.0", pid: 123, mixedPort: 7890, coreRunning: true, coreReady: true, summary: "ready", updatedAt: Date())
        let manager = ExtensionManager(readStatus: { file })
        manager.readState = { state }
        var changes = 0
        var notifications = 0
        manager.onChange = { changes += 1 }
        let observation = manager.$status.dropFirst().sink { _ in notifications += 1 }
        defer { observation.cancel() }
        manager.poll()
        for _ in 0..<100 {
            file?.updatedAt.addTimeInterval(10)
            manager.poll()
        }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(notifications, 1)
        // 心跳仍能重试尚未完成的启动恢复，避免 busy 期间错过恢复。
        state.restoreActive = true
        manager.poll()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(notifications, 1)
        state.restoreActive = false
        file?.mixedPort = 7891
        manager.poll()
        XCTAssertEqual(manager.status?.mixedPort, 7891)
        XCTAssertEqual(changes, 3)
        file = nil
        manager.poll()
        XCTAssertNil(manager.status)
        XCTAssertEqual(changes, 4)
        XCTAssertEqual(notifications, 3)
    }

    func testHeartbeatFilteringIncludesEveryOperationalField() {
        let original = ExtensionStatus(version: "1.0", pid: 123, mixedPort: 7890, coreRunning: true, coreReady: true, summary: "ready", updatedAt: Date())
        var heartbeat = original
        heartbeat.updatedAt.addTimeInterval(10)
        XCTAssertTrue(heartbeat.hasSameState(as: original))
        let edits: [(inout ExtensionStatus) -> Void] = [
            { $0.version = "2.0" }, { $0.pid += 1 }, { $0.mixedPort += 1 },
            { $0.coreRunning.toggle() }, { $0.coreReady.toggle() }, { $0.summary = "stopped" },
        ]
        for edit in edits {
            var changed = heartbeat
            edit(&changed)
            XCTAssertFalse(changed.hasSameState(as: original))
        }
        XCTAssertFalse(heartbeat.isAlive(now: heartbeat.updatedAt.addingTimeInterval(46), processExists: { _ in true }))
    }

    @MainActor
    func testHealthTimerStopsWhenOffAndRestartsAfterTurningOn() async throws {
        let backend = AppliedTargetsTests.Backend()
        var profile = Profile(name: "fixture", color: "#2563eb", host: "127.0.0.1", port: 3128)
        profile.targets = [.environment]
        var config = AppConfig()
        config.profiles = [profile]
        config.healthCheck = true
        config.notifyLevel = .none
        var calls = 0
        let state = AppState(config: config, persisted: PersistedState(), backend: backend, persists: false,
                             reachability: { _, _ in calls += 1; return true })
        state.startHealthChecks()
        await state.checkHealth()
        XCTAssertFalse(state.isHealthCheckScheduled)
        XCTAssertEqual(calls, 0)
        state.turnOn(profile)
        try await finishOperation(state)
        await state.checkHealth()
        XCTAssertTrue(state.isHealthCheckScheduled)
        state.turnOff()
        try await finishOperation(state)
        await state.checkHealth()
        XCTAssertFalse(state.isHealthCheckScheduled)
        let count = calls
        await state.checkHealth()
        XCTAssertEqual(calls, count)
        state.turnOn(profile)
        try await finishOperation(state)
        await state.checkHealth()
        XCTAssertTrue(state.isHealthCheckScheduled)
        state.config.healthCheck = false
        await state.checkHealth()
        XCTAssertFalse(state.isHealthCheckScheduled)
    }

    @MainActor
    private func finishOperation(_ state: AppState) async throws {
        for _ in 0..<100 {
            if !state.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("代理开关未完成")
    }
}
