import Foundation
import XCTest
@testable import ProxiProcess

private actor Events {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

final class CommandBatchesTests: XCTestCase {
    func testServicesOverlapButTheirCommandsStayOrdered() async throws {
        let events = Events()
        let start = ContinuousClock.now
        try await CommandBatches.run([[ ["a1"], ["a2"] ], [ ["b1"], ["b2"] ]]) { command in
            await events.add(command[0] + "-start")
            // 用真实进程验证命令执行层，不写系统网络配置。
            _ = try await ProcessCommand.run("/bin/sleep", ["0.15"])
            await events.add(command[0] + "-end")
        }
        let values = await events.values
        XCTAssertEqual(Set(values.prefix(2)), Set(["a1-start", "b1-start"]))
        for service in ["a", "b"] {
            XCTAssertEqual(values.filter { $0.hasPrefix(service) }, [service + "1-start", service + "1-end", service + "2-start", service + "2-end"])
        }
        print("networksetup 模拟开关：2 个服务 × 2 条命令，耗时 \(start.duration(to: .now))")
    }

    func testFailureWaitsForOtherServicesBeforeRetryAndKeepsOrder() async throws {
        enum Failure: Error { case first, second }
        let events = Events()
        do {
            try await CommandBatches.run([[ ["first"], ["must-not-run"] ], [ ["second"] ]]) { command in
                if command[0] == "first" {
                    try await Task.sleep(for: .milliseconds(100))
                    await events.add("first-finished")
                    throw Failure.first
                }
                if command[0] == "second" {
                    await events.add("second-finished")
                    throw Failure.second
                }
                XCTFail("失败的服务不能继续写后续设置")
            }
            XCTFail("应该失败")
        } catch Failure.first { }
        let values = await events.values
        XCTAssertEqual(values, ["second-finished", "first-finished"])
    }

    func testCancelledBatchDoesNotStartCommands() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await CommandBatches.run([[ ["first"], ["second"] ]]) { _ in
                XCTFail("取消后不能启动命令")
            }
        }
        do {
            try await task.value
            XCTFail("应该取消")
        } catch is CancellationError { }
    }
}
