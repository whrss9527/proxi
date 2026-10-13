import Combine
import XCTest
@testable import ProxiEngine

final class IdlePowerTests: XCTestCase {
    @MainActor
    func testHiddenSpeedHistoryDoesNotRedrawAndOpeningCatchesUp() {
        let engine = Engine()
        engine.setSettingsWindowVisible(true)
        let start = Date(timeIntervalSince1970: 1000)
        var redraws = 0
        let observation = engine.objectWillChange.sink { redraws += 1 }
        defer { observation.cancel() }
        engine.recordSpeed(TrafficTotal(), now: start)
        for index in 1...80 {
            engine.recordSpeed(TrafficTotal(upload: Int64(index * 100), download: Int64(index * 200)), now: start.addingTimeInterval(Double(index * 2)))
        }
        XCTAssertEqual(redraws, 0)
        XCTAssertTrue(engine.speedHistory.isEmpty)
        engine.setSpeedHistoryVisible(true)
        XCTAssertEqual(redraws, 1)
        XCTAssertEqual(engine.speedHistory.count, Engine.speedHistoryLimit)
        XCTAssertEqual(engine.speedHistory.last?.upload, 50)
        XCTAssertEqual(engine.speedHistory.last?.download, 100)
        engine.setSpeedHistoryVisible(true)
        XCTAssertEqual(redraws, 1)
        engine.recordSpeed(TrafficTotal(upload: 8200, download: 16400), now: start.addingTimeInterval(164))
        XCTAssertEqual(redraws, 2)
        let visible = engine.speedHistory
        engine.setSpeedHistoryVisible(false)
        engine.recordSpeed(TrafficTotal(upload: 8400, download: 16800), now: start.addingTimeInterval(168))
        XCTAssertEqual(redraws, 2)
        XCTAssertEqual(engine.speedHistory, visible)
        engine.setSpeedHistoryVisible(true)
        XCTAssertEqual(redraws, 3)
        XCTAssertEqual(engine.speedHistory.last?.date, start.addingTimeInterval(168))
    }

    @MainActor
    func testAppKitHidingStopsLogTaskWithoutSwiftUIDisappearing() {
        let engine = Engine()
        engine.subscribeLiveLog()
        XCTAssertFalse(engine.isLiveLogStreaming)
        engine.setSettingsWindowVisible(true)
        XCTAssertTrue(engine.isLiveLogStreaming)
        engine.setSpeedHistoryVisible(true)
        XCTAssertTrue(engine.isSpeedHistoryPublishing)
        // 模拟 orderOut/最小化：没有调用 unsubscribeLiveLog，也必须停止任务。
        engine.setSettingsWindowVisible(false)
        XCTAssertFalse(engine.isLiveLogStreaming)
        XCTAssertFalse(engine.isSpeedHistoryPublishing)
        engine.setSpeedHistoryVisible(true)
        XCTAssertFalse(engine.isSpeedHistoryPublishing)
        engine.setSettingsWindowVisible(true)
        XCTAssertTrue(engine.isLiveLogStreaming)
        engine.unsubscribeLiveLog()
        XCTAssertFalse(engine.isLiveLogStreaming)
        engine.setSettingsWindowVisible(false)
    }

    @MainActor
    func testWindowVisibilityDoesNotChangeTheSelectedPageOrRepeatNotifications() {
        let navigation = SettingsNavigation()
        navigation.select(.engine(.advanced))
        let requested = SidebarItem.proxi(.general)
        navigation.select(requested)
        var changes = 0
        let observation = navigation.$windowVisible.dropFirst().sink { _ in changes += 1 }
        defer { observation.cancel() }
        navigation.setWindowVisible(true)
        navigation.setWindowVisible(true)
        navigation.setWindowVisible(false)
        navigation.setWindowVisible(false)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(navigation.page, .advanced)
        XCTAssertEqual(navigation.sidebarItem, requested)
    }
}
