import Foundation
import XCTest
@testable import ProxiProcess

final class ProcessCommandTests: XCTestCase {
    func testOutputAndNonzeroExit() async throws {
        let result = try await ProcessCommand.run("/bin/sh", ["-c", "printf out; printf err >&2; exit 7"])
        XCTAssertEqual(result.output, "outerr")
        XCTAssertEqual(result.status, 7)
    }

    func testDrainsMoreThanPipeCapacityAndFinalBytes() async throws {
        let result = try await ProcessCommand.run("/bin/sh", ["-c", "head -c 1048576 /dev/zero; printf tail"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.utf8.count, 1048580)
        XCTAssertTrue(result.output.hasSuffix("tail"))
    }

    func testMissingExecutableDoesNotHang() async throws {
        do {
            _ = try await ProcessCommand.run("/does-not-exist/proxi-test", [])
            XCTFail("应该启动失败")
        } catch CommandError.launchFailed { }
    }

    func testTimeoutTerminatesCommand() async throws {
        do {
            _ = try await ProcessCommand.run("/bin/sleep", ["30"], timeout: 0.1)
            XCTFail("应该超时")
        } catch CommandError.timeout { }
    }

    func testTimeoutEscalatesForIgnoredTermination() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await ProcessCommand.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2)
            XCTFail("应该超时")
        } catch CommandError.timeout { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(6))
    }

    func testTimeoutDoesNotWaitForeverForInheritedPipe() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await ProcessCommand.run("/bin/sh", ["-c", "sleep 4 & exit 0"], timeout: 0.1)
            XCTFail("后代持有输出管道时也应该有截止时间")
        } catch CommandError.timeout { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3.5))
    }

    func testSignalCrashIsNotReportedAsTimeout() async throws {
        let result = try await ProcessCommand.run("/bin/sh", ["-c", "kill -KILL $$"])
        XCTAssertNotEqual(result.status, 0)
    }

    func testCancellationOfRunningCommand() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await ProcessCommand.run("/bin/sh", ["-c", "echo $$ > \"$1\"; trap '' TERM; while :; do :; done", "proxi-test", marker.path])
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = Int32(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("应该取消")
        } catch is CancellationError { }
        for _ in 0..<100 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "取消必须结束直接启动的进程")
    }

    func testAlreadyCancelledTaskDoesNotLaunch() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessCommand.run("/usr/bin/touch", [marker.path])
        }
        do {
            _ = try await task.value
            XCTFail("应该取消")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testConcurrentCommandsCompleteWithoutStarvingTasks() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let result = try await ProcessCommand.run("/bin/sh", ["-c", "sleep 0.05; printf '\(index)'"])
                    XCTAssertEqual(result.output, String(index))
                }
            }
            try await group.waitForAll()
        }
    }
}
