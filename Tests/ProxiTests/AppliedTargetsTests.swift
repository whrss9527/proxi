import XCTest
@testable import Proxi

final class AppliedTargetsTests: XCTestCase {
    final class Backend: ProxyBackend, @unchecked Sendable {
        var snapshot = ProxySnapshot()
        var calls: [ProxyTarget] = []
        var desired: DesiredProxy?
        var failing: Set<ProxyTarget> = []
        func currentSystemProxy() -> ProxySnapshot { snapshot }
        func applySystemProxy(_ desired: DesiredProxy, also services: [String]) async throws -> [String] {
            calls.append(.system)
            self.desired = desired
            if failing.contains(.system) { throw SystemProxyError.command("失败") }
            return services
        }
        func setEnvironment(proxyURL: String, noProxy: String) async throws { calls.append(.environment) }
        func clearEnvironment() async throws { calls.append(.environment) }
        func setGit(proxyURL: String) async throws { calls.append(.git) }
        func clearGit() async throws {
            calls.append(.git)
            if failing.contains(.git) { throw SystemProxyError.command("失败") }
        }
        func setNpm(proxyURL: String, noProxy: String) throws { calls.append(.npm) }
        func clearNpm() throws { calls.append(.npm) }
    }

    @MainActor
    private func state(_ backend: Backend, targets: [ProxyTarget]) -> AppState {
        var profile = Profile(name: "公司代理", color: "#2563eb", host: "proxy.corp.example", port: 3128)
        profile.targets = Set(targets)
        var config = AppConfig()
        config.profiles = [profile]
        config.offMode = .restore
        config.notifyLevel = .none
        config.healthCheck = false
        var persisted = PersistedState()
        persisted.lastProfileID = profile.id
        persisted.enabledByUs = true
        persisted.appliedTargets = targets
        var original = ProxySnapshot()
        original.httpEnabled = true
        original.httpHost = "original.corp.example"
        original.httpPort = 8080
        persisted.original = original
        return AppState(config: config, persisted: persisted, backend: backend, persists: false)
    }

    @MainActor
    private func waitForOperation(_ state: AppState) async throws {
        for _ in 0..<100 {
            if !state.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("操作没有结束")
    }

    @MainActor
    func testExternalSystemChangeStillClearsEveryOwnedTargetAndRestoresOriginal() async throws {
        let backend = Backend()
        backend.snapshot.httpEnabled = true
        backend.snapshot.httpHost = "external.corp.example"
        backend.snapshot.httpPort = 8888
        let state = state(backend, targets: [.system, .environment, .git, .npm])
        XCTAssertTrue(state.status.isOn)
        XCTAssertTrue(state.systemProxyChangedExternally)
        state.turnOff()
        try await waitForOperation(state)
        XCTAssertEqual(Set(backend.calls), [.system, .environment, .git, .npm])
        XCTAssertEqual(backend.desired, DesiredProxy(restoring: {
            var original = ProxySnapshot()
            original.httpEnabled = true
            original.httpHost = "original.corp.example"
            original.httpPort = 8080
            return original
        }()))
        XCTAssertEqual(state.persisted.appliedTargets, [])
        XCTAssertNil(state.persisted.original)
    }

    @MainActor
    func testNonSystemProfileRemainsOnAndDoesNotClearExternalSystemProxy() async throws {
        let backend = Backend()
        backend.snapshot.httpEnabled = true
        backend.snapshot.httpHost = "external.corp.example"
        backend.snapshot.httpPort = 8888
        let state = state(backend, targets: [.environment, .git, .npm])
        XCTAssertTrue(state.status.isOn)
        XCTAssertFalse(state.systemProxyChangedExternally)
        state.turnOff()
        try await waitForOperation(state)
        XCTAssertEqual(Set(backend.calls), [.environment, .git, .npm])
        XCTAssertNil(backend.desired)
    }

    @MainActor
    func testFailedCleanupRetainsOnlyRemainingTargetsAndOriginal() async throws {
        let backend = Backend()
        backend.failing = [.git]
        let state = state(backend, targets: [.environment, .git, .npm])
        state.turnOff()
        try await waitForOperation(state)
        XCTAssertEqual(state.persisted.appliedTargets, [.git])
        XCTAssertTrue(state.status.isOn)
        XCTAssertNotNil(state.persisted.original)
        backend.calls = []
        backend.failing = []
        state.turnOff()
        try await waitForOperation(state)
        XCTAssertEqual(backend.calls, [.git])
        XCTAssertFalse(state.persisted.enabledByUs)
    }

    @MainActor
    func testExplicitEmptyOwnershipDoesNotReuseLegacyEnabledFlag() {
        let backend = Backend()
        var profile = Profile(name: "公司代理", color: "#2563eb", host: "proxy.corp.example", port: 3128)
        profile.targets = [.system]
        var config = AppConfig()
        config.profiles = [profile]
        var persisted = PersistedState()
        persisted.enabledByUs = true
        persisted.appliedTargets = []
        let state = AppState(config: config, persisted: persisted, backend: backend, persists: false)
        XCTAssertFalse(state.status.isOn)
    }

    func testAppliedTargetsDecodeOldAndFutureRecords() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(PersistedState.self, from: Data(#"{"enabledByUs":true}"#.utf8))
        XCTAssertNil(old.appliedTargets)
        let future = try decoder.decode(PersistedState.self, from: Data(#"{"appliedTargets":["git","future-target"]}"#.utf8))
        XCTAssertEqual(future.appliedTargets, [.git])
        XCTAssertEqual(try decoder.decode(PersistedState.self, from: JSONEncoder().encode(future)), future)
    }
}
