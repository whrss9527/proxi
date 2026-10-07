import XCTest
@testable import Proxi

final class ProxyHealthMonitorTests: XCTestCase {
    private let profile = Profile(name: "本机调试代理", color: "#2563eb", host: "127.0.0.1", port: 3128)
    private let now = Date(timeIntervalSince1970: 1000)

    func testJitterDoesNotDeclareFailureOrPrematureRecovery() {
        var monitor = ProxyHealthMonitor()
        for reachable in [false, true, false, true] {
            XCTAssertNil(monitor.record(reachable, profile: profile, now: now))
        }
        XCTAssertEqual(monitor.health, .ok)
        XCTAssertNil(monitor.record(false, profile: profile, now: now))
        XCTAssertEqual(monitor.record(false, profile: profile, now: now), .failed)
        XCTAssertNil(monitor.record(true, profile: profile, now: now))
        XCTAssertEqual(monitor.health, .down)
        XCTAssertNil(monitor.record(false, profile: profile, now: now))
        XCTAssertNil(monitor.record(true, profile: profile, now: now))
        XCTAssertEqual(monitor.health, .down)
        XCTAssertEqual(monitor.record(true, profile: profile, now: now), .recovered)
        XCTAssertEqual(monitor.health, .ok)
        XCTAssertEqual(monitor.interval, 20)
    }

    func testFailureBackoffIsBoundedAndRecoveryKeepsItUntilConfirmed() {
        var monitor = ProxyHealthMonitor()
        _ = monitor.record(false, profile: profile, now: now)
        XCTAssertEqual(monitor.interval, 20)
        _ = monitor.record(false, profile: profile, now: now)
        XCTAssertEqual(monitor.interval, 40)
        for _ in 0..<8 { _ = monitor.record(false, profile: profile, now: now) }
        XCTAssertEqual(monitor.interval, 60)
        _ = monitor.record(true, profile: profile, now: now)
        XCTAssertEqual(monitor.interval, 60)
        _ = monitor.record(true, profile: profile, now: now)
        XCTAssertEqual(monitor.interval, 20)
    }

    func testNotificationPairsAreCooledDownPerProfileEvenAcrossReset() {
        var monitor = ProxyHealthMonitor()
        func episode(_ time: Date) -> [ProxyHealthMonitor.Notice] {
            [false, false, true, true].compactMap { monitor.record($0, profile: profile, now: time) }
        }
        XCTAssertEqual(episode(now), [.failed, .recovered])
        monitor.reset()
        XCTAssertEqual(episode(now.addingTimeInterval(599)), [])
        XCTAssertEqual(episode(now.addingTimeInterval(600)), [.failed, .recovered])
        var other = profile
        other.id = UUID()
        _ = monitor.record(false, profile: other, now: now)
        XCTAssertEqual(monitor.record(false, profile: other, now: now), .failed)
    }

    @MainActor
    private func state(reachability: @escaping (String, Int) async -> Bool) -> AppState {
        var config = AppConfig()
        config.profiles = [profile]
        config.healthCheck = true
        config.notifyLevel = .none
        var persisted = PersistedState()
        persisted.lastProfileID = profile.id
        persisted.enabledByUs = true
        persisted.appliedTargets = [.environment]
        return AppState(config: config, persisted: persisted, backend: AppliedTargetsTests.Backend(), persists: false,
                        reachability: reachability, healthClock: { self.now })
    }

    @MainActor
    func testInjectedReachabilityOnlyRedrawsWhenHealthChanges() async {
        var results = [true, true, false, false, false, true, true, true]
        let state = state { host, port in
            XCTAssertEqual(host, "127.0.0.1")
            XCTAssertEqual(port, 3128)
            return results.removeFirst()
        }
        var redraws = 0
        state.onStatusChanged = { redraws += 1 }
        for _ in 0..<8 { await state.checkHealth() }
        XCTAssertEqual(redraws, 3) // unknown→ok、ok→down、down→ok。
        XCTAssertEqual(state.health, .ok)
        state.config.healthCheck = false
        await state.checkHealth()
        await state.checkHealth()
        XCTAssertEqual(state.health, .unknown)
        XCTAssertEqual(redraws, 4)
    }

    @MainActor
    func testResponseAfterHealthChecksAreDisabledIsIgnored() async {
        var current: AppState?
        let state = state { _, _ in
            current?.config.healthCheck = false
            await Task.yield()
            return true
        }
        current = state
        var redraws = 0
        state.onStatusChanged = { redraws += 1 }
        await state.checkHealth()
        XCTAssertEqual(state.health, .unknown)
        XCTAssertEqual(redraws, 0)
    }
}
