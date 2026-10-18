import XCTest
import SystemConfiguration
@testable import Proxi

final class SystemServiceProxyTests: XCTestCase {
    final class Backend: ProxyBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: SystemServiceSettings]
        var active: [String]
        var failWrite = Set<String>()
        var failRestore = Set<String>()
        var delay = false
        var applyGate: (@Sendable () async -> Void)?
        var restoreGate: (@Sendable () async -> Void)?
        private(set) var written: [String] = []
        private(set) var restored: [String] = []

        init(_ services: [SystemServiceSettings], active: [String]? = nil) {
            items = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
            self.active = active ?? services.map(\.id)
        }
        var supportsServiceSnapshots: Bool { true }
        func value(_ id: String) -> SystemServiceSettings? { lock.lock(); defer { lock.unlock() }; return items[id] }
        func add(_ item: SystemServiceSettings) { lock.lock(); defer { lock.unlock() }; items[item.id] = item; active.append(item.id) }
        private func replace(_ item: SystemServiceSettings) { lock.lock(); defer { lock.unlock() }; items[item.id] = item }
        private func record(_ id: String) { lock.lock(); defer { lock.unlock() }; written.append(id) }
        private func recordRestore(_ id: String) { lock.lock(); defer { lock.unlock() }; restored.append(id) }
        func readSystemServices(also ids: [String]) -> SystemServiceRead {
            lock.lock(); defer { lock.unlock() }
            return SystemServiceRead(settings: items.values.filter { active.contains($0.id) || ids.contains($0.id) || ids.contains($0.name) }.sorted { $0.id < $1.id })
        }
        func applySystemServices(_ desired: DesiredProxy, services: [SystemServiceSettings]) async -> SystemServiceResult {
            await applySystemPlans(services.map { .init(id: $0.id, name: $0.name, desired: desired) })
        }
        func applySystemPlans(_ plans: [SystemServiceProxy.Plan]) async -> SystemServiceResult {
            if let applyGate { await applyGate() }
            if delay { try? await Task.sleep(for: .milliseconds(80)) }
            var result = SystemServiceResult()
            for plan in plans {
                record(plan.id)
                var snapshot = ProxySnapshot()
                if let endpoint = plan.desired.http { snapshot.httpEnabled = true; snapshot.httpHost = endpoint.host; snapshot.httpPort = endpoint.port }
                if let endpoint = plan.desired.https { snapshot.httpsEnabled = true; snapshot.httpsHost = endpoint.host; snapshot.httpsPort = endpoint.port }
                snapshot.autoDiscovery = plan.desired.autoDiscovery
                snapshot.exceptions = plan.desired.bypassDomains
                replace(try! SystemServiceSettings(id: plan.id, name: plan.name, dictionary: snapshot.legacyDictionary))
                if failWrite.contains(plan.id) { result.failures[plan.name] = "write failed" }
                else { result.succeeded.append(plan.id) }
            }
            return result
        }
        func restoreSystemServices(_ settings: [SystemServiceSettings]) async -> SystemServiceResult {
            if let restoreGate { await restoreGate() }
            var result = SystemServiceResult()
            for item in settings {
                if failRestore.contains(item.id) { result.failures[item.name] = "restore failed" }
                else { replace(item); recordRestore(item.id); result.succeeded.append(item.id) }
            }
            return result
        }
        func currentSystemProxy() -> ProxySnapshot { value(active.first ?? "")?.snapshot ?? ProxySnapshot() }
        func applySystemProxy(_ desired: DesiredProxy, also services: [String]) async throws -> [String] { XCTFail("使用了旧的全局恢复"); return [] }
        func setEnvironment(proxyURL: String, noProxy: String) async throws {}
        func clearEnvironment() async throws {}
        func setGit(proxyURL: String) async throws {}
        func clearGit() async throws {}
        func setNpm(proxyURL: String, noProxy: String) throws {}
        func clearNpm() throws {}
        func captureProxySettings(for target: ProxyTarget) async throws -> ProxyScopeSnapshot.Values { [:] }
        func restoreProxySettings(_ values: ProxyScopeSnapshot.Values, for target: ProxyTarget) async throws {}
    }

    private func service(_ id: String, host: String = "", enabled: Bool = false, discovery: Bool = false) throws -> SystemServiceSettings {
        var snapshot = ProxySnapshot()
        snapshot.httpEnabled = enabled
        snapshot.httpHost = host
        snapshot.httpPort = 8080
        snapshot.autoDiscovery = discovery
        var dictionary = snapshot.legacyDictionary
        dictionary["PreservedData"] = Data([0, 1, 2])
        return try SystemServiceSettings(id: id, name: id == "wifi" ? "Wi-Fi" : "Ethernet", dictionary: dictionary)
    }

    /// 内存中的测试记录避免触碰运行测试机器的钥匙串。
    private func backup(_ item: SystemServiceSettings) -> SystemServiceBackup {
        SystemServiceBackup(id: item.id, name: item.name,
            original: ProxyScopeSnapshot(values: ["configuration": item.configuration.map { [$0.base64EncodedString()] } ?? [], "enabled": [item.protocolEnabled ? "1" : "0"]]),
            autoDiscovery: item.snapshot.autoDiscovery)
    }

    @MainActor
    private func state(_ backend: Backend, persisted: PersistedState = PersistedState(), mode: OffMode = .restore) -> AppState {
        var profile = Profile(name: "开发代理", color: "#2563eb", host: "debug.corp.example", port: 8888)
        profile.targets = [.system]
        var config = AppConfig()
        config.profiles = [profile]
        config.offMode = mode
        config.notifyLevel = .none
        config.healthCheck = false
        return AppState(config: config, persisted: persisted, backend: backend, persists: false, backupSystemService: backup,
            resolveSystemService: { try $0.resolved { _ in nil } })
    }

    @MainActor
    private func wait(_ state: AppState) async throws {
        for _ in 0..<300 { if !state.busy { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("代理操作没有完成")
    }

    @MainActor
    func testRestoreKeepsEachServiceOriginalAndDisabledFields() async throws {
        let wifi = try service("wifi", host: "disabled.corp.example")
        let ethernet = try service("ethernet", host: "corp.example", enabled: true, discovery: true)
        let backend = Backend([wifi, ethernet])
        let state = state(backend)
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false)
        try await wait(state)
        XCTAssertEqual(state.persisted.originalSystemServices?.count, 2)
        XCTAssertNil(state.persisted.original)
        state.turnOff(); try await wait(state)
        XCTAssertEqual(backend.value("wifi"), wifi)
        XCTAssertEqual(backend.value("ethernet"), ethernet)
        XCTAssertNil(state.persisted.originalSystemServices)
    }

    @MainActor
    func testPartialWriteStillRestoresFailedServiceAndContinuesOthers() async throws {
        let wifi = try service("wifi")
        let ethernet = try service("ethernet", host: "corp.example", enabled: true)
        let backend = Backend([wifi, ethernet]); backend.failWrite = ["ethernet"]
        let state = state(backend)
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false); try await wait(state)
        XCTAssertTrue(state.appliedTargets.contains(.system))
        XCTAssertTrue(state.lastError?.contains("Ethernet") == true)
        XCTAssertTrue(backend.value("ethernet")!.snapshot.httpActive)
        state.turnOff(); try await wait(state)
        XCTAssertEqual(backend.value("wifi"), wifi)
        XCTAssertEqual(backend.value("ethernet"), ethernet)
    }

    @MainActor
    func testFailedRestoreRetainsOnlyUnfinishedServiceForRetry() async throws {
        let wifi = try service("wifi")
        let ethernet = try service("ethernet", host: "corp.example", enabled: true)
        let backend = Backend([wifi, ethernet]); let state = state(backend)
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false); try await wait(state)
        backend.failRestore = ["ethernet"]
        state.turnOff(); try await wait(state)
        XCTAssertEqual(Set(state.persisted.originalSystemServices?.keys.map { $0 } ?? []), ["ethernet"])
        XCTAssertEqual(backend.value("wifi"), wifi)
        backend.failRestore = []
        state.turnOff(); try await wait(state)
        XCTAssertEqual(backend.value("ethernet"), ethernet)
        XCTAssertNil(state.persisted.originalSystemServices)
    }

    @MainActor
    func testNewServiceCapturedBeforeApplyAndExistingServiceNotRecaptured() async throws {
        let wifi = try service("wifi"); let backend = Backend([wifi]); let state = state(backend)
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false); try await wait(state)
        let original = state.persisted.originalSystemServices?["wifi"]
        let ethernet = try service("ethernet", host: "corp.example", enabled: true)
        backend.add(ethernet); state.networkServicesChanged(); try await wait(state)
        XCTAssertEqual(state.persisted.originalSystemServices?["wifi"], original)
        XCTAssertEqual(backend.written.filter { $0 == "wifi" }.count, 1)
        XCTAssertEqual(backend.value("ethernet")?.snapshot.httpHost, "debug.corp.example")
        state.turnOff(); try await wait(state)
        XCTAssertEqual(backend.value("ethernet"), ethernet)
    }

    @MainActor
    func testNetworkChangeDuringEnableIsDeferred() async throws {
        let backend = Backend([try service("wifi")]); backend.delay = true
        let state = state(backend)
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false)
        try await Task.sleep(for: .milliseconds(30))
        backend.add(try service("ethernet")); state.networkServicesChanged()
        try await wait(state)
        XCTAssertEqual(state.persisted.originalSystemServices?.count, 2)
        XCTAssertEqual(backend.value("ethernet")?.snapshot.httpHost, "debug.corp.example")
    }

    @MainActor
    func testDirectRestoresAutoDiscoverySeparately() async throws {
        let backend = Backend([try service("wifi"), try service("ethernet", discovery: true)])
        let state = state(backend, mode: .direct)
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false); try await wait(state)
        state.turnOff(); try await wait(state)
        XCTAssertFalse(backend.value("wifi")!.snapshot.autoDiscovery)
        XCTAssertTrue(backend.value("ethernet")!.snapshot.autoDiscovery)
        XCTAssertFalse(backend.value("ethernet")!.snapshot.isActive)
    }

    @MainActor
    func testLegacySessionUsesSavedGlobalOriginalInsteadOfCurrentOwnedValue() async throws {
        let original = try service("wifi", host: "corp.example", enabled: true)
        var persisted = PersistedState(); persisted.enabledByUs = true; persisted.appliedTargets = [.system]
        persisted.original = original.snapshot; persisted.systemServices = ["Wi-Fi"]
        let backend = Backend([try service("wifi", host: "debug.corp.example", enabled: true)])
        let state = state(backend, persisted: persisted)
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false); try await wait(state)
        state.turnOff(); try await wait(state)
        XCTAssertEqual(backend.value("wifi")!.snapshot, original.snapshot)
    }

    @MainActor
    func testUnreadableSystemBackupsNeverOverwriteCurrentSettings() async throws {
        let wifi = try service("wifi", host: "corp.example", enabled: true)
        let backend = Backend([wifi]); var persisted = PersistedState(); persisted.systemServiceBackupsUnreadable = true
        let state = state(backend, persisted: persisted)
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false); try await wait(state)
        XCTAssertEqual(backend.value("wifi"), wifi)
        XCTAssertTrue(backend.written.isEmpty)
    }

    @MainActor
    func testExplicitDirectCleanupCanClearCorruptBackupAndEnableAgain() async throws {
        let backend = Backend([try service("wifi", host: "corp.example", enabled: true)])
        var persisted = PersistedState(); persisted.systemServiceBackupsUnreadable = true
        let state = state(backend, persisted: persisted)
        await state.clearAllProxySettings()
        XCTAssertFalse(backend.value("wifi")!.snapshot.isActive)
        XCTAssertFalse(state.persisted.systemServiceBackupsUnreadable)
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false); try await wait(state)
        XCTAssertEqual(backend.value("wifi")!.snapshot.httpHost, "debug.corp.example")
    }

    @MainActor
    func testLegacyNetworkEventIncludesPreviouslyOwnedInactiveService() async throws {
        let old = try service("wifi", host: "corp.example", enabled: true)
        let owned = try service("wifi", host: "debug.corp.example", enabled: true)
        let added = try service("ethernet")
        let backend = Backend([owned, added], active: ["ethernet"])
        var persisted = PersistedState(); persisted.enabledByUs = true; persisted.appliedTargets = [.system]
        persisted.original = old.snapshot; persisted.systemServices = ["Wi-Fi"]
        let state = state(backend, persisted: persisted)
        state.networkServicesChanged(); try await wait(state)
        XCTAssertEqual(state.persisted.originalSystemServices?.count, 2)
        state.turnOff(); try await wait(state)
        XCTAssertEqual(backend.value("wifi")!.snapshot, old.snapshot)
        XCTAssertEqual(backend.value("ethernet"), added)
    }

    @MainActor
    func testMissingServiceSecretPreservesItsCurrentSettingsAndRestoresOthers() async throws {
        let wifi = try service("wifi", host: "corp.example", enabled: true)
        let ethernet = try service("ethernet")
        let backend = Backend([wifi, ethernet])
        var broken = backup(wifi); broken.original.secretID = UUID()
        var persisted = PersistedState(); persisted.enabledByUs = true; persisted.appliedTargets = [.system]
        persisted.originalSystemServices = ["wifi": broken, "ethernet": backup(ethernet)]
        let state = state(backend, persisted: persisted)
        state.turnOff(); try await wait(state)
        XCTAssertEqual(backend.value("wifi"), wifi)
        XCTAssertEqual(backend.restored, ["ethernet"])
        XCTAssertNotNil(state.persisted.originalSystemServices?["wifi"])
    }

    func testCompleteDictionaryProtectedAndRenamedServiceKeepsIdentity() throws {
        var service = try service("wifi", host: "disabled.corp.example")
        service.protocolEnabled = false
        var stored: [UUID: String] = [:]
        var record = try service.backup { stored[$1] = $0 }
        record.name = "Renamed Wi-Fi"
        let data = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("disabled.corp.example"))
        let restored = try record.resolved { stored[$0] }
        XCTAssertEqual(restored.id, service.id)
        XCTAssertEqual(restored.configuration, service.configuration)
        XCTAssertFalse(restored.protocolEnabled)
        XCTAssertEqual(restored.name, "Renamed Wi-Fi")
        XCTAssertThrowsError(try record.resolved { _ in nil })
    }

    func testNoProtocolConfigurationRoundTripsAndCorruptRecordIsBlocked() throws {
        let empty = try SystemServiceSettings(id: "empty", name: "Empty", dictionary: nil)
        XCTAssertNil(try backup(empty).resolved().configuration)
        var record = backup(empty); record.original.values = ["configuration": ["broken"]]
        XCTAssertThrowsError(try record.resolved())
        let state = try JSONDecoder().decode(PersistedState.self, from: Data("{\"originalSystemServices\":{\"wifi\":false}}".utf8))
        XCTAssertTrue(state.systemServiceBackupsUnreadable)
    }

    func testCommandFailureDoesNotStopNextService() async throws {
        let desired = DesiredProxy(profile: Profile(name: "代理", color: "#2563eb", host: "corp.example", port: 8888))
        let result = await SystemServiceProxy.apply([.init(id: "wifi", name: "Wi-Fi", desired: desired), .init(id: "ethernet", name: "Ethernet", desired: desired)], run: { _, arguments in
            ShellResult(output: arguments[1] == "Wi-Fi" ? "Error: failed" : "", status: arguments[1] == "Wi-Fi" ? 1 : 0)
        }, authorize: { _ in XCTFail("普通错误不应触发提权"); return ShellResult(output: "", status: 1) })
        XCTAssertEqual(result.succeeded, ["ethernet"])
        XCTAssertNotNil(result.failures["Wi-Fi"])
    }

    func testAuthorizationIsCombinedAndServiceErrorsAreIsolated() async throws {
        let desired = DesiredProxy(profile: Profile(name: "代理", color: "#2563eb", host: "corp.example", port: 8888))
        let plans = [SystemServiceProxy.Plan(id: "wifi", name: "Wi-Fi", desired: desired), .init(id: "ethernet", name: "Ethernet", desired: desired)]
        var authorizationCount = 0
        let result = await SystemServiceProxy.apply(plans, run: { _, _ in ShellResult(output: "requires administrator", status: 1) }, authorize: { script in
            authorizationCount += 1
            XCTAssertTrue(script.contains("service_0")); XCTAssertTrue(script.contains("service_1"))
            return ShellResult(output: "0\tERR\t" + Data("Error: unavailable".utf8).base64EncodedString() + "\n1\tOK\n", status: 0)
        })
        XCTAssertEqual(authorizationCount, 1)
        XCTAssertEqual(result.succeeded, ["ethernet"])
        XCTAssertEqual(result.failures["Wi-Fi"], "Error: unavailable")
    }

    func testExitRestoresReadableServiceEvenWhenAnotherSecretIsUnavailable() throws {
        let wifi = try service("wifi"); let ethernet = try service("ethernet")
        let backend = Backend([wifi, ethernet])
        let records = ["wifi": backup(wifi), "ethernet": backup(ethernet)]
        let failures = ExitCleanup.run([.system], systemProxy: DesiredProxy(offWithAutoDiscovery: false, bypassDomains: []), services: [], backend: backend, timeout: 2,
            mode: .restore, systemBackups: records, resolveSystemOriginal: { record in
                if record.id == "ethernet" { throw RestorationError.unavailable }
                return try record.resolved()
            })
        XCTAssertNotNil(failures[.system])
        XCTAssertEqual(backend.restored, ["wifi"])
        XCTAssertEqual(backend.value("wifi"), wifi)
    }

    private actor WriteGate {
        let entered: XCTestExpectation
        private var used = false
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() async {
            guard !used else { return }
            used = true
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor
    func testConfigurationEditsDuringNewServiceWriteReconcileAllServicesOnce() async throws {
        let wifi = try service("wifi")
        let ethernet = try service("ethernet", host: "original.corp.example", enabled: true)
        let backend = Backend([wifi])
        let state = state(backend)
        var profile = try XCTUnwrap(state.selectedProfile)
        state.turnOn(profile, askForPassword: false)
        try await wait(state)
        let wifiOriginal = state.persisted.originalSystemServices?["wifi"]
        let entered = expectation(description: "新增网络服务写入已挂起")
        let gate = WriteGate(entered)
        backend.applyGate = { await gate.wait() }
        backend.add(ethernet)
        state.networkServicesChanged()
        await fulfillment(of: [entered], timeout: 3)
        profile.host = "b.corp.example"
        state.update(profile)
        profile.host = "c.corp.example"
        state.update(profile)
        state.networkServicesChanged()
        await gate.release()
        try await wait(state)
        XCTAssertEqual(backend.value("wifi")?.snapshot.httpHost, "c.corp.example")
        XCTAssertEqual(backend.value("ethernet")?.snapshot.httpHost, "c.corp.example")
        XCTAssertEqual(state.persisted.originalSystemServices?["wifi"], wifiOriginal)
        XCTAssertEqual(backend.written.filter { $0 == "wifi" }.count, 2)
        XCTAssertEqual(backend.written.filter { $0 == "ethernet" }.count, 2)
        state.turnOff()
        try await wait(state)
        XCTAssertEqual(backend.value("wifi"), wifi)
        XCTAssertEqual(backend.value("ethernet"), ethernet)
    }

    @MainActor
    func testRemovedSystemScopeRestoresServicesWhoseWritesAllFailed() async throws {
        let wifi = try service("wifi")
        let ethernet = try service("ethernet", host: "original.corp.example", enabled: true)
        let backend = Backend([wifi, ethernet])
        backend.failWrite = ["wifi", "ethernet"]
        let state = state(backend)
        var profile = try XCTUnwrap(state.selectedProfile)
        let entered = expectation(description: "系统范围首次写入已挂起")
        let gate = WriteGate(entered)
        backend.applyGate = { await gate.wait() }
        state.turnOn(profile, askForPassword: false)
        await fulfillment(of: [entered], timeout: 3)
        profile.targets = [.git]
        state.update(profile)
        await gate.release()
        try await wait(state)
        XCTAssertEqual(backend.value("wifi"), wifi)
        XCTAssertEqual(backend.value("ethernet"), ethernet)
        XCTAssertEqual(Set(backend.restored), ["wifi", "ethernet"])
        XCTAssertNil(state.persisted.originalSystemServices)
        XCTAssertNil(state.persisted.pendingCleanup)
        XCTAssertEqual(state.appliedTargets, [.git])
    }


    @MainActor
    func testNetworkChangeDuringFailedTurnOffNeverAppliesEditedProfileToNewService() async throws {
        let wifi = try service("wifi")
        let ethernet = try service("ethernet", host: "untouched.corp.example", enabled: true)
        let backend = Backend([wifi])
        let state = state(backend)
        var profile = try XCTUnwrap(state.selectedProfile)
        state.turnOn(profile, askForPassword: false)
        try await wait(state)
        backend.failRestore = ["wifi"]
        let entered = expectation(description: "关闭恢复在失败前挂起")
        let gate = WriteGate(entered)
        backend.restoreGate = { await gate.wait() }
        state.turnOff()
        await fulfillment(of: [entered], timeout: 3)
        profile.host = "edited.corp.example"
        state.update(profile)
        backend.add(ethernet)
        state.networkServicesChanged()
        await gate.release()
        try await wait(state)
        XCTAssertEqual(backend.written, ["wifi"])
        XCTAssertEqual(backend.value("ethernet"), ethernet)
        XCTAssertNotNil(state.persisted.originalSystemServices?["wifi"])
        XCTAssertNotNil(state.lastError)
        // 关闭失败后的另一个独立网络通知同样不能重新扩展代理。
        state.networkServicesChanged()
        try await wait(state)
        XCTAssertEqual(backend.written, ["wifi"])
        XCTAssertEqual(backend.value("ethernet"), ethernet)
        backend.failRestore = []
        state.turnOff()
        try await wait(state)
        XCTAssertEqual(backend.value("wifi"), wifi)
        XCTAssertEqual(backend.value("ethernet"), ethernet)
        XCTAssertFalse(state.persisted.enabledByUs)
    }


    @MainActor
    func testPendingStartupCleanupDoesNotApplyNewServicesBeforeCleanupStarts() async throws {
        let original = try service("wifi", host: "original.corp.example", enabled: true)
        let owned = try service("wifi", host: "debug.corp.example", enabled: true)
        let ethernet = try service("ethernet", host: "untouched.corp.example", enabled: true)
        let backend = Backend([owned, ethernet])
        var persisted = PersistedState()
        persisted.enabledByUs = true
        persisted.appliedTargets = [.system]
        persisted.originalSystemServices = ["wifi": backup(original)]
        persisted.pendingCleanup = PendingCleanup(profileName: "开发代理", targets: [.system])
        let state = state(backend, persisted: persisted)
        state.networkServicesChanged()
        try await wait(state)
        XCTAssertTrue(backend.written.isEmpty)
        XCTAssertEqual(backend.value("ethernet"), ethernet)
        XCTAssertNotNil(state.persisted.pendingCleanup)
        await state.resumePendingCleanup()
        XCTAssertEqual(backend.value("wifi"), original)
        XCTAssertEqual(backend.value("ethernet"), ethernet)
        XCTAssertNil(state.persisted.pendingCleanup)
        XCTAssertFalse(state.persisted.enabledByUs)
    }

}
