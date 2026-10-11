import XCTest
import Darwin
@testable import Proxi

final class OriginalProxySettingsTests: XCTestCase {
    final class Backend: ProxyBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var settings: [ProxyTarget: ProxyScopeSnapshot.Values]
        private var captures: [ProxyTarget: Int] = [:]
        var failCapture: Set<ProxyTarget> = []
        var failWrite: Set<ProxyTarget> = []
        var failRestore: Set<ProxyTarget> = []

        init(_ settings: [ProxyTarget: ProxyScopeSnapshot.Values]) { self.settings = settings }
        func values(_ target: ProxyTarget) -> ProxyScopeSnapshot.Values {
            lock.lock(); defer { lock.unlock() }
            return settings[target] ?? [:]
        }
        func captureCount(_ target: ProxyTarget) -> Int {
            lock.lock(); defer { lock.unlock() }
            return captures[target] ?? 0
        }
        private func replace(_ target: ProxyTarget, _ values: ProxyScopeSnapshot.Values) {
            lock.lock(); defer { lock.unlock() }
            settings[target] = values
        }
        private func recordCapture(_ target: ProxyTarget) {
            lock.lock(); defer { lock.unlock() }
            captures[target, default: 0] += 1
        }
        private func write(_ target: ProxyTarget, _ url: String) throws {
            replace(target, ["proxy": [url]])
            if failWrite.contains(target) { throw RestorationError.unavailable }
        }
        func captureProxySettings(for target: ProxyTarget) async throws -> ProxyScopeSnapshot.Values {
            if failCapture.contains(target) { throw RestorationError.unavailable }
            recordCapture(target)
            return values(target)
        }
        func restoreProxySettings(_ values: ProxyScopeSnapshot.Values, for target: ProxyTarget) async throws {
            if failRestore.contains(target) { throw RestorationError.unavailable }
            replace(target, values)
        }
        func currentSystemProxy() -> ProxySnapshot { ProxySnapshot() }
        func applySystemProxy(_ desired: DesiredProxy, also services: [String]) async throws -> [String] { services }
        func setEnvironment(proxyURL: String, noProxy: String) async throws { try write(.environment, proxyURL) }
        func clearEnvironment() async throws { replace(.environment, [:]) }
        func setGit(proxyURL: String) async throws { try write(.git, proxyURL) }
        func clearGit() async throws { replace(.git, [:]) }
        func setNpm(proxyURL: String, noProxy: String) throws { try write(.npm, proxyURL) }
        func clearNpm() throws { replace(.npm, [:]) }
    }

    private var originals: [ProxyTarget: ProxyScopeSnapshot.Values] {
        [.environment: ["HTTP_PROXY": ["http://corp.example:8080"], "http_proxy": [""], "NO_PROXY": ["corp.example"]],
         .git: ["http.proxy": ["http://corp.example:8080", "http://backup.example:8081"]],
         .npm: ["proxy": [" proxy = http://corp.example:8080"], "noproxy": ["noproxy="]]]
    }

    @MainActor
    private func state(_ backend: Backend, mode: OffMode = .restore, targets: Set<ProxyTarget> = [.environment, .git, .npm], persisted: PersistedState = PersistedState()) -> AppState {
        var profile = Profile(name: "开发代理", color: "#2563eb", host: "debug.corp.example", port: 8888)
        profile.targets = targets
        var config = AppConfig()
        config.profiles = [profile]
        config.offMode = mode
        config.notifyLevel = .none
        config.healthCheck = false
        config.disableOnExit = true
        return AppState(config: config, persisted: persisted, backend: backend, persists: false)
    }

    @MainActor
    private func wait(_ state: AppState) async throws {
        for _ in 0..<300 {
            if !state.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("代理操作没有完成")
    }

    @MainActor
    func testSwitchKeepsFirstSnapshotAndRestoresRemovedScope() async throws {
        let backend = Backend(originals)
        let state = state(backend)
        var profile = try XCTUnwrap(state.selectedProfile)
        state.turnOn(profile, askForPassword: false)
        try await wait(state)
        profile.host = "other.corp.example"
        profile.targets.remove(.npm)
        state.update(profile)
        try await wait(state)
        XCTAssertEqual(backend.values(.npm), originals[.npm])
        XCTAssertNil(state.persisted.originalScopes.npm)
        for target in [ProxyTarget.environment, .git] { XCTAssertEqual(backend.captureCount(target), 1) }
        state.turnOff()
        try await wait(state)
        for target in [ProxyTarget.environment, .git, .npm] {
            XCTAssertEqual(backend.values(target), originals[target])
            XCTAssertNil(state.persisted.originalScopes[target])
        }
    }

    @MainActor
    func testDirectAndDiagnosticClearDoNotRestore() async throws {
        for diagnostic in [false, true] {
            let backend = Backend(originals)
            let state = state(backend, mode: diagnostic ? .restore : .direct)
            state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false)
            try await wait(state)
            if diagnostic { await state.clearAllProxySettings() }
            else { state.turnOff(); try await wait(state) }
            for target in [ProxyTarget.environment, .git, .npm] {
                XCTAssertEqual(backend.values(target), [:])
                XCTAssertNil(state.persisted.originalScopes[target])
            }
        }
    }

    @MainActor
    func testCaptureFailureDoesNotOverwriteOriginal() async throws {
        let backend = Backend(originals)
        backend.failCapture = [.git]
        let state = state(backend, targets: [.git])
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false)
        try await wait(state)
        XCTAssertEqual(backend.values(.git), originals[.git])
        XCTAssertEqual(state.appliedTargets, [])
        XCTAssertNil(state.persisted.originalScopes.git)
        XCTAssertNotNil(state.lastError)
    }

    @MainActor
    func testPartialWriteAndFailedRestoreRetainSnapshotForRetry() async throws {
        let backend = Backend(originals)
        backend.failWrite = [.git]
        let state = state(backend, targets: [.git])
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false)
        try await wait(state)
        XCTAssertNotEqual(backend.values(.git), originals[.git])
        XCTAssertEqual(state.appliedTargets, [], "失败不能报告为写成功")
        XCTAssertEqual(state.persisted.pendingCleanup?.targets, [.git])
        backend.failRestore = [.git]
        state.turnOff()
        try await wait(state)
        XCTAssertNotNil(state.persisted.originalScopes.git)
        XCTAssertEqual(state.appliedTargets, [.git])
        backend.failRestore = []
        state.turnOff()
        try await wait(state)
        XCTAssertEqual(backend.values(.git), originals[.git])
        XCTAssertNil(state.persisted.originalScopes.git)
        XCTAssertNil(state.persisted.pendingCleanup)
    }

    @MainActor
    func testExitRestoresAllOriginals() async throws {
        let backend = Backend(originals)
        let state = state(backend)
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false)
        try await wait(state)
        state.handleExit()
        for target in [ProxyTarget.environment, .git, .npm] {
            XCTAssertEqual(backend.values(target), originals[target])
            XCTAssertNil(state.persisted.originalScopes[target])
        }
    }

    @MainActor
    func testRelaunchResumesFailedRestoration() async throws {
        var persisted = PersistedState()
        persisted.originalScopes.git = try ProxyScopeSnapshot.capture(try XCTUnwrap(originals[.git]))
        persisted.pendingCleanup = PendingCleanup(profileName: "开发代理", targets: [.git])
        let backend = Backend([.git: ["http.proxy": ["http://debug.corp.example:8888"]]])
        let state = state(backend, targets: [.git], persisted: persisted)
        await state.resumePendingCleanup()
        XCTAssertEqual(backend.values(.git), originals[.git])
        XCTAssertNil(state.persisted.originalScopes.git)
        XCTAssertNil(state.persisted.pendingCleanup)
    }

    @MainActor
    func testLegacyOwnedScopeIsNotCapturedAsOriginal() async throws {
        var persisted = PersistedState()
        persisted.enabledByUs = true
        persisted.appliedTargets = [.git]
        let backend = Backend([.git: ["http.proxy": ["http://old-proxi.example:8080"]]])
        let state = state(backend, targets: [.git], persisted: persisted)
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false)
        try await wait(state)
        XCTAssertEqual(backend.captureCount(.git), 0)
        XCTAssertNil(state.persisted.originalScopes.git)
        state.turnOff()
        try await wait(state)
        XCTAssertEqual(backend.values(.git), [:])
    }

    func testSecretsAreKeptOutOfStateAndMissingSecretRefusesRestore() throws {
        let raw = ["http.proxy": ["http://dev:fixture-password@corp.example:8080"]]
        var stored: [UUID: String] = [:]
        let snapshot = try ProxyScopeSnapshot.capture(raw) { stored[$1] = $0 }
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fixture-password"))
        XCTAssertFalse(snapshot.summary.contains("fixture-password"))
        XCTAssertEqual(try snapshot.resolved { stored[$0] }, raw)
        XCTAssertThrowsError(try snapshot.resolved { _ in nil })
    }

    func testStateRoundTripAndMalformedScopeDoNotDiscardOtherSnapshots() throws {
        let raw = Data(#"{"originalScopes":{"git":{"values":{"http.proxy":[""]},"unreadable":false},"npm":"broken"},"appliedTargets":["git"]}"#.utf8)
        let state = try JSONDecoder().decode(PersistedState.self, from: raw)
        XCTAssertEqual(state.originalScopes.git?.values, ["http.proxy": [""]])
        XCTAssertEqual(state.originalScopes.npm?.unreadable, true)
        XCTAssertThrowsError(try state.originalScopes.npm?.resolved())
        XCTAssertEqual(try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state)), state)
        XCTAssertFalse(LegacyCleanup.inspect(configData: nil, stateData: try JSONEncoder().encode(state)).hadLegacySettings)
        XCTAssertEqual(try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8)).originalScopes, OriginalProxySettings())
        let broken = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"originalScopes":"broken"}"#.utf8))
        XCTAssertThrowsError(try broken.originalScopes.git?.resolved())
    }

    func testLaunchdSnapshotKeepsCaseEmptyValuesAndMissingKeys() async throws {
        let values = try await EnvironmentProxy.snapshot { name in
            switch name {
            case "HTTP_PROXY": return ShellResult(output: "http://corp.example:8080\n", status: 0)
            case "http_proxy": return ShellResult(output: "\n", status: 0)
            case "NO_PROXY": return ShellResult(output: " corp.example \n", status: 0)
            default: return ShellResult(output: "", status: 113)
            }
        }
        XCTAssertEqual(values["HTTP_PROXY"], ["http://corp.example:8080"])
        XCTAssertEqual(values["http_proxy"], [""])
        XCTAssertEqual(values["NO_PROXY"], [" corp.example "])
        XCTAssertNil(values["HTTPS_PROXY"])
        do {
            _ = try await EnvironmentProxy.snapshot { _ in ShellResult(output: "permission denied", status: 77) }
            XCTFail("读取失败不能视为空设置")
        } catch {}
    }

    func testExitResolvesSnapshotsBeforeWritingAndLeavesUnreadableScopeUntouched() throws {
        let active: ProxyScopeSnapshot.Values = ["proxy": ["http://debug.corp.example:8888"]]
        let backend = Backend([.git: active, .npm: active, .environment: active])
        var snapshots = OriginalProxySettings()
        snapshots.git = ProxyScopeSnapshot(values: try XCTUnwrap(originals[.git]))
        snapshots.npm = ProxyScopeSnapshot(values: try XCTUnwrap(originals[.npm]))
        snapshots.environment = ProxyScopeSnapshot(values: [:], unreadable: true)
        var reads = 0
        let failures = ExitCleanup.run([.git, .npm, .environment], systemProxy: DesiredProxy(offWithAutoDiscovery: false, bypassDomains: []),
                                       services: [], backend: backend, timeout: 2, originals: snapshots, mode: .restore) { snapshot in
            XCTAssertEqual(backend.values(.git), active)
            XCTAssertEqual(backend.values(.npm), active)
            reads += 1
            return try snapshot.resolved()
        }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(Set(failures.keys), [.environment])
        XCTAssertEqual(backend.values(.environment), active)
        XCTAssertEqual(backend.values(.git), originals[.git])
        XCTAssertEqual(backend.values(.npm), originals[.npm])
    }
}

/// 真实 Git 和 npm 文件操作只使用临时路径；不替换 HOME，不写用户配置或 launchd。
final class OriginalProxyFileTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("proxi-original-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testGitMultiValuesAndEmptyValueRestoreWithoutChangingOtherKeys() async throws {
        let directory = try fixture()
        let previous = getenv("GIT_CONFIG_GLOBAL").map { String(cString: $0) }
        setenv("GIT_CONFIG_GLOBAL", directory.appendingPathComponent("gitconfig").path, 1)
        defer {
            if let previous { setenv("GIT_CONFIG_GLOBAL", previous, 1) } else { unsetenv("GIT_CONFIG_GLOBAL") }
            try? FileManager.default.removeItem(at: directory)
        }
        let git = try XCTUnwrap(GitProxy.gitPath)
        for (key, value) in [("http.proxy", "http://corp.example:8080"), ("http.proxy", "http://backup.example:8081"), ("https.proxy", ""), ("user.name", "fixture-user")] {
            let result = try await Shell.run(git, ["config", "--global", "--add", key, value])
            XCTAssertTrue(result.succeeded)
        }
        let credentials = directory.appendingPathComponent("git-proxy.inc")
        let original = try await GitProxy.snapshot(credentialURL: credentials)
        try await GitProxy.set(proxyURL: "http://127.0.0.1:8888", credentialURL: credentials)
        try await GitProxy.restore(original, credentialURL: credentials)
        let restored = try await GitProxy.snapshot(credentialURL: credentials)
        XCTAssertEqual(restored, original)
        let user = try await Shell.run(git, ["config", "--global", "--get", "user.name"])
        XCTAssertEqual(user.trimmedOutput, "fixture-user")
        try await GitProxy.clear(credentialURL: credentials)
        let cleared = try await GitProxy.snapshot(credentialURL: credentials)
        XCTAssertEqual(cleared, [:])
    }

    func testGitCredentialRestorationCanBeCapturedAgain() async throws {
        let directory = try fixture()
        let previous = getenv("GIT_CONFIG_GLOBAL").map { String(cString: $0) }
        setenv("GIT_CONFIG_GLOBAL", directory.appendingPathComponent("gitconfig").path, 1)
        defer {
            if let previous { setenv("GIT_CONFIG_GLOBAL", previous, 1) } else { unsetenv("GIT_CONFIG_GLOBAL") }
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("git-proxy.inc")
        let original = ["http.proxy": ["http://dev:fixture-password@corp.example:8080"], "https.proxy": [""]]
        for _ in 0..<2 {
            try await GitProxy.restore(original, credentialURL: file)
            let captured = try await GitProxy.snapshot(credentialURL: file)
            XCTAssertEqual(captured, original)
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
            try await GitProxy.set(proxyURL: "http://127.0.0.1:8888", credentialURL: file)
        }
    }

    func testNpmRestoresOnlyProxyLinesAndPreservesSymlinkAndNewOtherFields() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("dotfiles-npmrc")
        let link = directory.appendingPathComponent("npmrc")
        try "registry=https://registry.npmjs.org\n proxy = http://corp.example:8080\nproxy=http://backup.example:8081\nnoproxy=\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let original = try NpmProxy.snapshot(file: link)
        try NpmProxy.set(proxyURL: "http://127.0.0.1:8888", noProxy: "localhost", file: link)
        let handle = try FileHandle(forWritingTo: target)
        handle.seekToEndOfFile()
        handle.write(Data("save-exact=true\n".utf8))
        try handle.close()
        try NpmProxy.restore(original, file: link)
        XCTAssertEqual(try NpmProxy.snapshot(file: link), original)
        let content = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(content.contains("registry=https://registry.npmjs.org"))
        XCTAssertTrue(content.contains("save-exact=true"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        try NpmProxy.clear(file: link)
        XCTAssertEqual(try NpmProxy.snapshot(file: link), [:])
    }
}
