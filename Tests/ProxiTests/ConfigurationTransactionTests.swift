import XCTest
@testable import Proxi

@MainActor
final class ConfigurationTransactionTests: XCTestCase {
    /// 挂起一次真实生产调用，用确定的进入/释放时序模拟用户在后台写入期间修改配置。
    private final class Backend: ProxyBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var settings: [ProxyTarget: ProxyScopeSnapshot.Values] = [
            .environment: ["HTTP_PROXY": ["http://original.corp.example:8080"]],
            .git: ["http.proxy": ["http://original.corp.example:8081"]]
        ]
        private var writes: [(ProxyTarget, String)] = []
        private var restored: [ProxyTarget] = []
        private var captures: [ProxyTarget: Int] = [:]
        private var gate: CheckedContinuation<Void, Never>?
        private var holdNext = false
        private var entered: XCTestExpectation?
        var holdRestore = false
        var holdCapture = false
        var failCapture = Set<ProxyTarget>()
        var failWrite = Set<ProxyTarget>()
        var failRestore = Set<ProxyTarget>()

        func arm(_ entered: XCTestExpectation, restoring: Bool = false) {
            lock.lock(); defer { lock.unlock() }
            self.entered = entered
            holdNext = true
            holdRestore = restoring
        }
        func release() {
            lock.lock()
            let continuation = gate
            gate = nil
            lock.unlock()
            continuation?.resume()
        }
        private func pause(restoring: Bool) async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if holdNext && holdRestore == restoring {
                    holdNext = false
                    gate = continuation
                    let expectation = entered
                    lock.unlock()
                    expectation?.fulfill()
                } else {
                    lock.unlock()
                    continuation.resume()
                }
            }
        }
        func values(_ target: ProxyTarget) -> ProxyScopeSnapshot.Values {
            lock.lock(); defer { lock.unlock() }
            return settings[target] ?? [:]
        }
        func urls(_ target: ProxyTarget) -> [String] {
            lock.lock(); defer { lock.unlock() }
            return writes.filter { $0.0 == target }.map(\.1)
        }
        func captureCount(_ target: ProxyTarget) -> Int {
            lock.lock(); defer { lock.unlock() }
            return captures[target, default: 0]
        }
        func restoreCount(_ target: ProxyTarget) -> Int {
            lock.lock(); defer { lock.unlock() }
            return restored.filter { $0 == target }.count
        }
        private func write(_ target: ProxyTarget, url: String) throws {
            lock.lock(); defer { lock.unlock() }
            settings[target] = ["proxy": [url]]
            writes.append((target, url))
            if failWrite.contains(target) { throw RestorationError.unavailable }
        }
        private func capture(_ target: ProxyTarget) -> ProxyScopeSnapshot.Values {
            lock.lock(); defer { lock.unlock() }
            captures[target, default: 0] += 1
            return settings[target] ?? [:]
        }
        private func restore(_ target: ProxyTarget, values: ProxyScopeSnapshot.Values) throws {
            lock.lock(); defer { lock.unlock() }
            restored.append(target)
            if failRestore.contains(target) { throw RestorationError.unavailable }
            settings[target] = values
        }
        func currentSystemProxy() -> ProxySnapshot { ProxySnapshot() }
        func applySystemProxy(_ desired: DesiredProxy, also services: [String]) async throws -> [String] {
            XCTFail("仅终端/git的事务不应改动系统代理")
            return []
        }
        func setEnvironment(proxyURL: String, noProxy: String) async throws {
            await pause(restoring: false)
            try write(.environment, url: proxyURL)
        }
        func clearEnvironment() async throws { try restore(.environment, values: [:]) }
        func setGit(proxyURL: String) async throws {
            await pause(restoring: false)
            try write(.git, url: proxyURL)
        }
        func clearGit() async throws { try restore(.git, values: [:]) }
        func setNpm(proxyURL: String, noProxy: String) throws { try write(.npm, url: proxyURL) }
        func clearNpm() throws { try restore(.npm, values: [:]) }
        func captureProxySettings(for target: ProxyTarget) async throws -> ProxyScopeSnapshot.Values {
            if holdCapture { await pause(restoring: false) }
            if failCapture.contains(target) { throw RestorationError.unavailable }
            return capture(target)
        }
        func restoreProxySettings(_ values: ProxyScopeSnapshot.Values, for target: ProxyTarget) async throws {
            await pause(restoring: true)
            try restore(target, values: values)
        }
    }

    private func makeState(_ backend: Backend, passwordAccess: AppState.PasswordAccess? = nil) -> AppState {
        let profile = Profile(name: "公司代理", color: "#2563eb", host: "a.corp.example", port: 3128, targets: [.environment, .git])
        var config = AppConfig()
        config.profiles = [profile]
        config.notifyLevel = .none
        config.healthCheck = false
        config.offMode = .restore
        return AppState(config: config, persisted: PersistedState(), backend: backend, persists: false,
                        passwordAccess: passwordAccess, operationLog: { _, _ in })
    }

    private func completion(_ state: AppState) -> XCTestExpectation {
        let done = expectation(description: "代理事务及延期协调完成")
        done.assertForOverFulfill = false
        state.onStatusChanged = { [weak state] in
            if state?.busy == false { done.fulfill() }
        }
        return done
    }

    private func startHeld(_ state: AppState, _ backend: Backend) async throws -> Profile {
        let profile = try XCTUnwrap(state.selectedProfile)
        let entered = expectation(description: "后台首次写入已挂起")
        backend.arm(entered)
        state.turnOn(profile, askForPassword: false)
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(state.busy)
        return profile
    }

    func testFirstWriteAddressEditUsesLatestAndKeepsOriginalSnapshot() async throws {
        let backend = Backend()
        let original = backend.values(.environment)
        let state = makeState(backend)
        var profile = try await startHeld(state, backend)
        XCTAssertFalse(state.status.isOn)
        profile.host = "b.corp.example"
        state.update(profile)
        let done = completion(state)
        backend.release()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(backend.urls(.environment), ["http://a.corp.example:3128", "http://b.corp.example:3128"])
        XCTAssertEqual(backend.urls(.git).last, "http://b.corp.example:3128")
        XCTAssertEqual(backend.captureCount(.environment), 1)
        let off = completion(state)
        state.turnOff()
        await fulfillment(of: [off], timeout: 3)
        XCTAssertEqual(backend.values(.environment), original)
        XCTAssertFalse(state.status.isOn)
    }

    func testMultipleEditsCoalesceToLatestAndRevertingDoesNotRewrite() async throws {
        for revert in [false, true] {
            let backend = Backend()
            let state = makeState(backend)
            let original = try await startHeld(state, backend)
            var edited = original
            edited.host = "b.corp.example"
            state.update(edited)
            edited.host = revert ? original.host : "c.corp.example"
            state.update(edited)
            let done = completion(state)
            backend.release()
            await fulfillment(of: [done], timeout: 3)
            XCTAssertEqual(backend.urls(.environment), revert ? ["http://a.corp.example:3128"] : ["http://a.corp.example:3128", "http://c.corp.example:3128"])
        }
    }

    func testRemovedFailedScopeRestoresCapturedOriginalAndRetainsFailedCleanup() async throws {
        for restoreFails in [false, true] {
            let backend = Backend()
            let original = backend.values(.environment)
            backend.failWrite = [.environment]
            backend.failRestore = restoreFails ? [.environment] : []
            let state = makeState(backend)
            var profile = try await startHeld(state, backend)
            profile.targets = [.git]
            state.update(profile)
            let done = completion(state)
            backend.release()
            await fulfillment(of: [done], timeout: 3)
            XCTAssertEqual(backend.restoreCount(.environment), 1)
            if restoreFails {
                XCTAssertNotNil(state.persisted.originalScopes.environment)
                XCTAssertEqual(state.persisted.pendingCleanup?.targets, [.environment])
                XCTAssertNotNil(state.lastError)
            } else {
                XCTAssertEqual(backend.values(.environment), original)
                XCTAssertNil(state.persisted.originalScopes.environment)
                XCTAssertNil(state.persisted.pendingCleanup)
            }
            XCTAssertEqual(state.appliedTargets, [.git])
        }
    }

    func testDeletingInFlightProfileRestoresAndDoesNotEnableFallback() async throws {
        let backend = Backend()
        let original = backend.values(.environment)
        let state = makeState(backend)
        let profile = try await startHeld(state, backend)
        var fallback = profile
        fallback.id = UUID()
        fallback.host = "fallback.corp.example"
        state.addProfile(fallback)
        state.remove(profile)
        let done = completion(state)
        backend.release()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(backend.values(.environment), original)
        XCTAssertEqual(backend.urls(.environment), ["http://a.corp.example:3128"])
        XCTAssertEqual(state.appliedTargets, [])
        XCTAssertFalse(state.persisted.enabledByUs)
        XCTAssertFalse(state.status.isOn)
    }

    func testRemoteReplacementAndDeletionDuringFirstWriteAreReconciled() async throws {
        for delete in [false, true] {
            let backend = Backend()
            let original = backend.values(.environment)
            let state = makeState(backend)
            let profile = try await startHeld(state, backend)
            var remote = state.config
            if delete { remote.profiles = [] }
            else {
                remote.profiles[0].host = "remote.corp.example"
                remote.profiles[0].targets = [.git]
            }
            state.applyRemoteConfig(remote)
            let done = completion(state)
            backend.release()
            await fulfillment(of: [done], timeout: 3)
            XCTAssertEqual(backend.values(.environment), original)
            XCTAssertNil(state.persisted.originalScopes.environment)
            if delete { XCTAssertFalse(state.persisted.enabledByUs); XCTAssertEqual(state.appliedTargets, []) }
            else {
                XCTAssertEqual(state.appliedTargets, [.git])
                XCTAssertEqual(backend.urls(.git).last, "http://remote.corp.example:3128")
                XCTAssertEqual(state.persisted.lastProfileID, profile.id)
            }
        }
    }

    func testNameOnlyAndUnrelatedProfileEditsDoNotReapply() async throws {
        let backend = Backend()
        let state = makeState(backend)
        var profile = try await startHeld(state, backend)
        profile.name = "公司代理新名字"
        profile.color = "#111111"
        state.update(profile)
        var other = profile
        other.id = UUID()
        state.addProfile(other)
        other.host = "other.corp.example"
        state.update(other)
        let done = completion(state)
        backend.release()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(backend.urls(.environment), ["http://a.corp.example:3128"])
        XCTAssertEqual(state.config.profile(id: profile.id)?.name, profile.name)
    }

    func testEditsDuringTurnOffNeverReenable() async throws {
        let backend = Backend()
        let original = backend.values(.environment)
        let state = makeState(backend)
        var profile = try await startHeld(state, backend)
        let on = completion(state)
        backend.release()
        await fulfillment(of: [on], timeout: 3)
        let entered = expectation(description: "恢复原值已挂起")
        backend.arm(entered, restoring: true)
        state.turnOff()
        await fulfillment(of: [entered], timeout: 3)
        profile.host = "b.corp.example"
        state.update(profile)
        var remote = state.config
        remote.profiles[0].host = "remote.corp.example"
        state.applyRemoteConfig(remote)
        let off = completion(state)
        backend.release()
        await fulfillment(of: [off], timeout: 3)
        XCTAssertEqual(backend.urls(.environment), ["http://a.corp.example:3128"])
        XCTAssertEqual(backend.values(.environment), original)
        XCTAssertFalse(state.persisted.enabledByUs)
    }

    func testCancelledPasswordPromptDiscardsDeferredEditsAndAllowsExplicitRetry() async throws {
        let backend = Backend()
        weak var promptState: AppState?
        var prompts = 0
        let state = makeState(backend, passwordAccess: .init(read: { _, _ in nil }, prompt: { profile in
            prompts += 1
            var edited = profile
            edited.host = "b.corp.example"
            promptState?.update(edited)
            return prompts == 1 ? nil : "fixture-password"
        }, save: { _, _ in }))
        promptState = state
        var profile = try XCTUnwrap(state.selectedProfile)
        profile.username = "fixture-user"
        profile.hasPassword = true
        state.update(profile)
        state.turnOn(profile)
        XCTAssertFalse(state.busy)
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(backend.urls(.environment).isEmpty)
        let done = completion(state)
        state.turnOn(try XCTUnwrap(state.selectedProfile))
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(backend.urls(.environment), ["http://fixture-user:fixture-password@b.corp.example:3128"])
    }

    func testFailedReconciliationDoesNotLoopAndCanBeRetriedExplicitly() async throws {
        let backend = Backend()
        let state = makeState(backend)
        var profile = try await startHeld(state, backend)
        profile.host = "b.corp.example"
        state.update(profile)
        backend.failWrite = [.environment, .git]
        let done = completion(state)
        backend.release()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertFalse(state.busy)
        XCTAssertEqual(backend.urls(.environment), ["http://a.corp.example:3128", "http://b.corp.example:3128"])
        XCTAssertNotNil(state.lastError)
        backend.failWrite = []
        let retry = completion(state)
        state.turnOn(profile, askForPassword: false)
        await fulfillment(of: [retry], timeout: 3)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(backend.urls(.environment).last, "http://b.corp.example:3128")
        XCTAssertEqual(backend.captureCount(.environment), 1)
    }

    func testPasswordOnlyChangeIsReappliedWithoutAllowingInteractiveCLI() async throws {
        let backend = Backend()
        var reads = 0
        var allowsUI: [Bool] = []
        let state = makeState(backend, passwordAccess: .init(read: { _, allowUI in
            reads += 1
            allowsUI.append(allowUI)
            return reads == 1 ? "first-fixture" : "latest-fixture"
        }, prompt: { _ in XCTFail("非交互开启不能弹密码框"); return nil }, save: { _, _ in }))
        var profile = try XCTUnwrap(state.selectedProfile)
        profile.username = "fixture-user"
        profile.hasPassword = true
        state.update(profile)
        _ = try await startHeld(state, backend)
        state.update(profile, passwordChanged: true)
        let done = completion(state)
        backend.release()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(allowsUI, [false, false])
        XCTAssertEqual(backend.urls(.environment), ["http://fixture-user:first-fixture@a.corp.example:3128", "http://fixture-user:latest-fixture@a.corp.example:3128"])
    }

    func testNewRequestFromCompletionKeepsItsOwnDeferredConfiguration() async throws {
        let backend = Backend()
        let state = makeState(backend)
        let profile = try await startHeld(state, backend)
        var other = profile
        other.id = UUID()
        other.host = "other.corp.example"
        state.addProfile(other)
        let done = expectation(description: "回调中的新请求和新配置完成")
        done.assertForOverFulfill = false
        var requested = false
        state.onStatusChanged = { [weak state] in
            guard let state, !state.busy else { return }
            if !requested {
                requested = true
                state.turnOn(other, askForPassword: false)
                other.host = "latest.corp.example"
                state.update(other)
            } else {
                done.fulfill()
            }
        }
        backend.release()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(backend.urls(.environment), ["http://a.corp.example:3128", "http://other.corp.example:3128", "http://latest.corp.example:3128"])
        XCTAssertEqual(state.persisted.lastProfileID, other.id)
    }

    func testRelaunchDoesNotStartDeferredReapplication() async throws {
        let backend = Backend()
        let state = makeState(backend)
        var profile = try await startHeld(state, backend)
        profile.host = "b.corp.example"
        state.update(profile)
        state.relaunching = true
        state.handleExit()
        let done = completion(state)
        backend.release()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(backend.urls(.environment), ["http://a.corp.example:3128"])
    }


    func testEditsWhileReapplyingAnActiveProfileUseLatestWithoutRecapturing() async throws {
        let backend = Backend()
        let original = backend.values(.git)
        let state = makeState(backend)
        var profile = try await startHeld(state, backend)
        let first = completion(state)
        backend.release()
        await fulfillment(of: [first], timeout: 3)
        let entered = expectation(description: "已开启配置的重新应用挂起")
        backend.arm(entered)
        profile.host = "b.corp.example"
        state.update(profile)
        await fulfillment(of: [entered], timeout: 3)
        profile.host = "c.corp.example"
        state.update(profile)
        profile.host = "d.corp.example"
        state.update(profile)
        let done = completion(state)
        backend.release()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(backend.urls(.git), ["http://a.corp.example:3128", "http://b.corp.example:3128", "http://d.corp.example:3128"])
        XCTAssertEqual(backend.captureCount(.git), 1)
        let off = completion(state)
        state.turnOff()
        await fulfillment(of: [off], timeout: 3)
        XCTAssertEqual(backend.values(.git), original)
    }

    func testEditsDuringRestartCleanupDoNotReenableProxy() async throws {
        let backend = Backend()
        let original = backend.values(.environment)
        let state = makeState(backend)
        let profile = try await startHeld(state, backend)
        let first = completion(state)
        backend.release()
        await fulfillment(of: [first], timeout: 3)
        var persisted = state.persisted
        persisted.pendingCleanup = PendingCleanup(profileName: profile.name, targets: [.environment, .git])
        let resumed = AppState(config: state.config, persisted: persisted, backend: backend, persists: false,
                               operationLog: { _, _ in })
        let entered = expectation(description: "重启后的恢复清理挂起")
        backend.arm(entered, restoring: true)
        let cleanup = Task { await resumed.resumePendingCleanup() }
        await fulfillment(of: [entered], timeout: 3)
        var remote = resumed.config
        remote.profiles[0].host = "remote.corp.example"
        resumed.applyRemoteConfig(remote)
        backend.release()
        await cleanup.value
        XCTAssertFalse(resumed.busy)
        XCTAssertFalse(resumed.persisted.enabledByUs)
        XCTAssertNil(resumed.persisted.pendingCleanup)
        XCTAssertEqual(backend.values(.environment), original)
        XCTAssertEqual(backend.urls(.environment), ["http://a.corp.example:3128"])
    }


    func testDeletionAfterAllCapturesFailNeverClearsUntouchedSettings() async throws {
        let backend = Backend()
        let environment = backend.values(.environment)
        let git = backend.values(.git)
        backend.holdCapture = true
        backend.failCapture = [.environment, .git]
        let state = makeState(backend)
        let profile = try XCTUnwrap(state.selectedProfile)
        let entered = expectation(description: "原值采集在失败前挂起")
        backend.arm(entered)
        state.turnOn(profile, askForPassword: false)
        await fulfillment(of: [entered], timeout: 3)
        state.remove(profile)
        let done = completion(state)
        backend.release()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(backend.values(.environment), environment)
        XCTAssertEqual(backend.values(.git), git)
        XCTAssertTrue(backend.urls(.environment).isEmpty)
        XCTAssertTrue(backend.urls(.git).isEmpty)
        XCTAssertEqual(backend.restoreCount(.environment), 0)
        XCTAssertEqual(backend.restoreCount(.git), 0)
        XCTAssertEqual(state.appliedTargets, [])
        XCTAssertNil(state.persisted.originalScopes.environment)
        XCTAssertNil(state.persisted.originalScopes.git)
        XCTAssertNotNil(state.lastError)
    }

}
