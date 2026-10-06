import XCTest
@testable import Proxi

/// 退出时清理代理设置：各项都清理成功才记成「已关闭」，没清理完的记下来，下次启动时接着清理。
final class ExitCleanupTests: XCTestCase {
    /// 假的系统后端：不碰这台 Mac 的设置，记下调用；可以让某几项出错，或者卡住不返回。
    final class FakeBackend: ProxyBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        private let failing: Set<ProxyTarget>
        private let stalling: Set<ProxyTarget>
        private let snapshot: ProxySnapshot

        init(snapshot: ProxySnapshot, failing: Set<ProxyTarget> = [], stalling: Set<ProxyTarget> = []) {
            self.snapshot = snapshot
            self.failing = failing
            self.stalling = stalling
        }

        var calls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        private func record(_ call: String, _ target: ProxyTarget) throws {
            lock.lock()
            recorded.append(call)
            lock.unlock()
            if failing.contains(target) {
                throw SystemProxyError.command("\(call) 失败")
            }
        }

        private func recordAsync(_ call: String, _ target: ProxyTarget) async throws {
            if stalling.contains(target) {
                // 像管理员密码框一直开着：比退出时等的时间长得多。
                try await Task.sleep(for: .seconds(5))
            }
            try record(call, target)
        }

        func currentSystemProxy() -> ProxySnapshot { snapshot }
        func applySystemProxy(_ desired: DesiredProxy, also services: [String]) async throws -> [String] {
            try await recordAsync("system", .system)
            return services
        }
        func setEnvironment(proxyURL: String, noProxy: String) async throws { try await recordAsync("setEnvironment", .environment) }
        func clearEnvironment() async throws { try await recordAsync("clearEnvironment", .environment) }
        func setGit(proxyURL: String) async throws { try await recordAsync("setGit", .git) }
        func clearGit() async throws { try await recordAsync("clearGit", .git) }
        func setNpm(proxyURL: String, noProxy: String) throws { try record("setNpm", .npm) }
        func clearNpm() throws { try record("clearNpm", .npm) }
    }

    private let host = "proxy.corp.example"
    private let port = 3128

    /// 系统代理正指向这个配置（Proxi 开着它）。
    private var activeSnapshot: ProxySnapshot {
        var snapshot = ProxySnapshot()
        snapshot.httpEnabled = true
        snapshot.httpHost = host
        snapshot.httpPort = port
        snapshot.httpsEnabled = true
        snapshot.httpsHost = host
        snapshot.httpsPort = port
        return snapshot
    }

    /// 一个开着的配置，系统代理、终端、git、npm 都设了；「退出时关闭代理」开着。不读写磁盘上的配置。
    @MainActor
    private func makeState(_ backend: FakeBackend) -> AppState {
        var profile = Profile(name: "公司代理", color: "#2563eb", host: host, port: port)
        profile.targets = [.system, .environment, .git, .npm]
        var config = AppConfig()
        config.profiles = [profile]
        config.disableOnExit = true
        config.notifyLevel = .none
        var persisted = PersistedState()
        persisted.lastProfileID = profile.id
        persisted.enabledByUs = true
        persisted.original = ProxySnapshot()
        persisted.systemServices = ["Wi-Fi"]
        let state = AppState(config: config, persisted: persisted, backend: backend, persists: false)
        state.exitCleanupTimeout = 1
        return state
    }

    @MainActor
    func testMarksOffWhenEverythingIsCleared() {
        let backend = FakeBackend(snapshot: activeSnapshot)
        let state = makeState(backend)
        XCTAssertTrue(state.status.isOn)
        state.handleExit()
        XCTAssertEqual(Set(backend.calls), ["system", "clearEnvironment", "clearGit", "clearNpm"])
        XCTAssertFalse(state.persisted.enabledByUs)
        XCTAssertNil(state.persisted.original)
        XCTAssertEqual(state.persisted.systemServices, [])
        XCTAssertNil(state.persisted.pendingCleanup)
    }

    @MainActor
    func testPartialFailureIsKeptForNextLaunch() {
        let backend = FakeBackend(snapshot: activeSnapshot, failing: [.git])
        let state = makeState(backend)
        state.handleExit()
        // 出错的那一项留着，状态不改成「已关闭」，开启前的设置也留着。
        XCTAssertEqual(state.persisted.pendingCleanup, PendingCleanup(profileName: "公司代理", targets: [.git]))
        XCTAssertTrue(state.persisted.enabledByUs)
        XCTAssertNotNil(state.persisted.original)
        // 系统代理已经清理好了，开启时写过的网络服务不用再记。
        XCTAssertEqual(state.persisted.systemServices, [])
    }

    @MainActor
    func testTimeoutIsKeptForNextLaunch() {
        // 系统代理卡住（标准账户的管理员密码框开着），终端、git、npm 照样先清掉。
        let backend = FakeBackend(snapshot: activeSnapshot, stalling: [.system])
        let state = makeState(backend)
        let start = Date()
        state.handleExit()
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertEqual(state.persisted.pendingCleanup?.targets, [.system])
        XCTAssertTrue(state.persisted.enabledByUs)
        XCTAssertNotNil(state.persisted.original)
        XCTAssertEqual(state.persisted.systemServices, ["Wi-Fi"])
        XCTAssertTrue(Set(backend.calls).isSuperset(of: ["clearEnvironment", "clearGit", "clearNpm"]))
        XCTAssertFalse(backend.calls.contains("system"))
    }

    @MainActor
    func testResumesPendingCleanupOnNextLaunch() async {
        var persisted = PersistedState()
        persisted.enabledByUs = true
        persisted.original = ProxySnapshot()
        persisted.pendingCleanup = PendingCleanup(profileName: "公司代理", targets: [.git, .npm])
        var config = AppConfig()
        config.notifyLevel = .none

        let failing = FakeBackend(snapshot: ProxySnapshot(), failing: [.npm])
        let state = AppState(config: config, persisted: persisted, backend: failing, persists: false)
        await state.resumePendingCleanup()
        // npm 还是不行：只留下 npm，告诉用户。
        XCTAssertEqual(state.persisted.pendingCleanup?.targets, [.npm])
        XCTAssertTrue(state.persisted.enabledByUs)
        XCTAssertNotNil(state.lastError)

        let backend = FakeBackend(snapshot: ProxySnapshot())
        let resumed = AppState(config: config, persisted: persisted, backend: backend, persists: false)
        await resumed.resumePendingCleanup()
        XCTAssertEqual(backend.calls, ["clearGit", "clearNpm"])
        XCTAssertNil(resumed.persisted.pendingCleanup)
        XCTAssertFalse(resumed.persisted.enabledByUs)
        XCTAssertEqual(resumed.persisted.appliedTargets, [])
        XCTAssertNil(resumed.persisted.original)
    }

    func testPendingCleanupDecodesLeniently() throws {
        let data = Data(#"{"enabledByUs":true,"pendingCleanup":{"profileName":"公司代理","targets":["git","future-target"]}}"#.utf8)
        let state = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(state.pendingCleanup, PendingCleanup(profileName: "公司代理", targets: [.git]))
        let broken = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"enabledByUs":true,"pendingCleanup":"x"}"#.utf8))
        XCTAssertNil(broken.pendingCleanup)
        XCTAssertTrue(broken.enabledByUs)
    }
}
