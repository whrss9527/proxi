import XCTest
@testable import Proxi

@MainActor
final class PasswordReentryTests: XCTestCase {
    private final class Recorder {
        var reads = 0
        var prompts = 0
        var saved: [String] = []
        var logs: [(String, Bool)] = []
        var allowsUI: [Bool] = []
        var read: @MainActor () -> String? = { nil }
        var prompt: @MainActor () -> String? = { "fixture-password" }
        var saveFails = false
    }

    private func makeState(_ recorder: Recorder, backend: AppliedTargetsTests.Backend) -> AppState {
        var profile = Profile(name: "公司代理", color: "#2563eb", host: "proxy.corp.example", port: 3128)
        profile.username = "fixture-user"
        profile.hasPassword = true
        profile.targets = [.system, .git]
        var config = AppConfig()
        config.profiles = [profile]
        config.notifyLevel = .none
        config.healthCheck = false
        return AppState(config: config, persisted: PersistedState(), backend: backend, persists: false,
                        passwordAccess: .init(read: { _, allowUI in
                            recorder.reads += 1
                            recorder.allowsUI.append(allowUI)
                            return recorder.read()
                        }, prompt: { _ in
                            recorder.prompts += 1
                            return recorder.prompt()
                        }, save: { password, _ in
                            recorder.saved.append(password)
                            if recorder.saveFails { throw CancellationError() }
                        }), operationLog: { recorder.logs.append(($0, $1)) })
    }

    private func waitForOperation(_ state: AppState) async throws {
        for _ in 0..<100 {
            if !state.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("代理操作没有结束")
    }

    func testPromptRejectsNestedTurnOnToggleAndTurnOff() async throws {
        let recorder = Recorder()
        let backend = AppliedTargetsTests.Backend()
        let state = makeState(recorder, backend: backend)
        let profile = try XCTUnwrap(state.selectedProfile)
        recorder.prompt = { [weak state] in
            guard let state else { XCTFail("状态已释放"); return nil }
            XCTAssertTrue(state.busy)
            if recorder.prompts == 1 {
                state.turnOn(profile)
                state.toggle()
                state.turnOff()
            } else {
                XCTFail("密码框被重复打开")
            }
            XCTAssertTrue(backend.calls.isEmpty)
            return "fixture-password"
        }
        state.turnOn(profile)
        XCTAssertTrue(state.busy) // 提示已结束，后端操作仍未结束，不能过早解锁。
        try await waitForOperation(state)
        XCTAssertEqual(recorder.reads, 1)
        XCTAssertEqual(recorder.prompts, 1)
        XCTAssertEqual(recorder.saved, ["fixture-password"])
        XCTAssertEqual(backend.calls, [.system, .git])
        XCTAssertEqual(recorder.logs.filter { $0.0.contains("忽略重复开启") }.count, 2)
        XCTAssertNil(state.lastError)
    }

    func testKeychainAuthorizationAlsoRejectsReentryBeforePrompt() async throws {
        let recorder = Recorder()
        let backend = AppliedTargetsTests.Backend()
        let state = makeState(recorder, backend: backend)
        let profile = try XCTUnwrap(state.selectedProfile)
        recorder.read = { [weak state] in
            guard let state else { XCTFail("状态已释放"); return nil }
            XCTAssertTrue(state.busy)
            if recorder.reads == 1 { state.turnOn(profile) }
            else { XCTFail("钥匙串授权被重复进入") }
            return "saved-fixture"
        }
        state.turnOn(profile)
        try await waitForOperation(state)
        XCTAssertEqual(recorder.reads, 1)
        XCTAssertEqual(recorder.prompts, 0)
        XCTAssertTrue(recorder.saved.isEmpty)
        XCTAssertEqual(backend.calls, [.system, .git])
    }

    func testCancelledOrEmptyPromptUnlocksAndAllowsRetry() async throws {
        for answer in [nil, ""] as [String?] {
            let recorder = Recorder()
            let backend = AppliedTargetsTests.Backend()
            let state = makeState(recorder, backend: backend)
            let profile = try XCTUnwrap(state.selectedProfile)
            recorder.prompt = { answer }
            state.turnOn(profile)
            XCTAssertFalse(state.busy)
            XCTAssertNotNil(state.lastError)
            XCTAssertTrue(backend.calls.isEmpty)
            XCTAssertTrue(recorder.saved.isEmpty)
            XCTAssertNil(state.persisted.original)
            recorder.prompt = { "fixture-password" }
            state.turnOn(profile)
            try await waitForOperation(state)
            XCTAssertEqual(recorder.prompts, 2)
            XCTAssertEqual(backend.calls, [.system, .git])
            XCTAssertNil(state.lastError)
        }
    }

    func testNoninteractiveMissingPasswordDoesNotPromptAndUnlocks() throws {
        let recorder = Recorder()
        let backend = AppliedTargetsTests.Backend()
        let state = makeState(recorder, backend: backend)
        state.turnOn(try XCTUnwrap(state.selectedProfile), askForPassword: false)
        XCTAssertEqual(recorder.allowsUI, [false])
        XCTAssertEqual(recorder.prompts, 0)
        XCTAssertFalse(state.busy)
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertNotNil(state.lastError)
    }

    func testPasswordSaveFailureStillCompletesOneOperation() async throws {
        let recorder = Recorder()
        recorder.saveFails = true
        let backend = AppliedTargetsTests.Backend()
        let state = makeState(recorder, backend: backend)
        state.turnOn(try XCTUnwrap(state.selectedProfile))
        try await waitForOperation(state)
        XCTAssertFalse(state.busy)
        XCTAssertEqual(backend.calls, [.system, .git])
        XCTAssertTrue(recorder.logs.contains { $0.1 && $0.0.contains("保存") })
        XCTAssertNil(state.lastError)
    }

    func testFailedBackendUnlocksAfterPrompt() async throws {
        let recorder = Recorder()
        let backend = AppliedTargetsTests.Backend()
        backend.failing = [.system, .git]
        let state = makeState(recorder, backend: backend)
        state.turnOn(try XCTUnwrap(state.selectedProfile))
        try await waitForOperation(state)
        XCTAssertFalse(state.busy)
        XCTAssertNotNil(state.lastError)
        XCTAssertEqual(backend.calls, [.system, .git])
        XCTAssertFalse(state.persisted.enabledByUs)
    }
}
