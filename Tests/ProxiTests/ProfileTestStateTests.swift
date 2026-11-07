import XCTest
@testable import Proxi

@MainActor
final class ProfileTestStateTests: XCTestCase {
    private func input(port: Int = 8080, password: String = "", url: String = "https://fixture.invalid") -> ProfileTestInput {
        ProfileTestInput(profile: Profile(name: "fixture", color: "", host: "fixture.invalid", port: port), password: password, testURL: url)
    }

    func testEditingDuringRequestDiscardsLateResponse() async {
        let started = expectation(description: "request started")
        var response: CheckedContinuation<TestResult, Never>?
        let state = ProfileTestState { _ in
            await withCheckedContinuation { response = $0; started.fulfill() }
        }
        let first = input()
        let pending = state.start(first)
        await fulfillment(of: [started], timeout: 2)
        var edited = first
        edited.profile.port = 9090
        state.inputChanged(edited)
        XCTAssertFalse(state.testing)
        XCTAssertNil(state.result)
        // 故意让假请求忽略取消，模拟已经排队到达的旧响应。
        response?.resume(returning: TestResult(ok: true, latencyMs: 1, message: "old response"))
        await pending.value
        XCTAssertNil(state.result)
    }

    func testReplacementRequestKeepsItsResultWhenOldResponseArrivesLast() async {
        let started = expectation(description: "old request started")
        var response: CheckedContinuation<TestResult, Never>?
        var calls = 0
        let state = ProfileTestState { _ in
            calls += 1
            if calls == 1 {
                return await withCheckedContinuation { response = $0; started.fulfill() }
            }
            return TestResult(ok: false, latencyMs: 2, message: "new response")
        }
        let first = input()
        let old = state.start(first)
        await fulfillment(of: [started], timeout: 2)
        var edited = first
        edited.profile.port = 9090
        let current = state.start(edited)
        await current.value
        XCTAssertEqual(state.result?.message, "new response")
        response?.resume(returning: TestResult(ok: true, latencyMs: 1, message: "old response"))
        await old.value
        XCTAssertEqual(state.result?.message, "new response")
        XCTAssertFalse(state.testing)
    }

    func testSameInputKeepsResultAndChangedPasswordOrURLClearsIt() async {
        let state = ProfileTestState { _ in TestResult(ok: true, latencyMs: 1, message: "current") }
        let first = input()
        await state.start(first).value
        state.inputChanged(first)
        XCTAssertNotNil(state.result)
        var edited = first
        edited.password = "changed"
        state.inputChanged(edited)
        XCTAssertNil(state.result)
        await state.start(first).value
        edited = first
        edited.testURL += "/changed"
        state.inputChanged(edited)
        XCTAssertNil(state.result)
    }

    func testClosingBeforeTaskStartsDoesNotRunTheRequest() async {
        var calls = 0
        let state = ProfileTestState { _ in
            calls += 1
            return TestResult(ok: true, latencyMs: 1, message: "unused")
        }
        let pending = state.start(input())
        state.cancel()
        await pending.value
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(state.testing)
        XCTAssertNil(state.result)
    }

    func testClosingWhileRequestIsPendingDiscardsItsResponse() async {
        let started = expectation(description: "request started")
        var response: CheckedContinuation<TestResult, Never>?
        let state = ProfileTestState { _ in
            await withCheckedContinuation { response = $0; started.fulfill() }
        }
        let pending = state.start(input())
        await fulfillment(of: [started], timeout: 2)
        state.cancel()
        response?.resume(returning: TestResult(ok: true, latencyMs: 1, message: "closed"))
        await pending.value
        XCTAssertFalse(state.testing)
        XCTAssertNil(state.result)
    }
}
