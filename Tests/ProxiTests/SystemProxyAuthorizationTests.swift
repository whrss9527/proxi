import XCTest
import Security
import os
@testable import Proxi

final class SystemProxyAuthorizationTests: XCTestCase {
    private struct Events {
        var grants = 0
        var writes = 0
        var active = 0
        var maximumActive = 0
        var authorizedIDs: [[String]] = []
    }

    private func settings() throws -> [SystemServiceSettings] {
        [try SystemServiceSettings(id: "wifi", name: "Wi-Fi", dictionary: ["HTTPEnable": 0])]
    }

    func testValidAuthorizationReusedAcrossRestores() async throws {
        let events = OSAllocatedUnfairLock(initialState: Events())
        let session = SystemServiceProxy.RestorationSession(write: { items, authorization, _ in
            events.withLock { $0.writes += 1 }
            guard authorization != nil else { return (.init(), true) }
            return (.init(succeeded: items.map(\.id)), false)
        }, grant: { _ in events.withLock { $0.grants += 1 }; return errAuthorizationSuccess })
        let items = try settings()
        let first = await session.restore(items)
        let second = await session.restore(items)
        XCTAssertEqual(first.succeeded, ["wifi"])
        XCTAssertEqual(second.succeeded, ["wifi"])
        XCTAssertEqual(events.withLock { $0.grants }, 1)
        XCTAssertEqual(events.withLock { $0.writes }, 3)
    }

    func testCancelledAuthorizationCanBeRetriedAndKeepsSuccessfulServices() async throws {
        let events = OSAllocatedUnfairLock(initialState: Events())
        let session = SystemServiceProxy.RestorationSession(write: { items, authorization, _ in
            guard authorization != nil else {
                return (.init(succeeded: ["wifi"], failures: ["Ethernet": "access denied"]), true)
            }
            events.withLock { $0.authorizedIDs.append(items.map(\.id)) }
            return (.init(succeeded: items.map(\.id)), false)
        }, grant: { _ in
            events.withLock { value in
                value.grants += 1
                return value.grants == 1 ? errAuthorizationCanceled : errAuthorizationSuccess
            }
        })
        let items = try settings() + [SystemServiceSettings(id: "ethernet", name: "Ethernet", dictionary: [:])]
        let cancelled = await session.restore(items)
        XCTAssertEqual(cancelled.succeeded, ["wifi"])
        XCTAssertNotNil(cancelled.failures["Ethernet"])
        XCTAssertNil(cancelled.failures["Wi-Fi"])
        let retried = await session.restore(items)
        XCTAssertEqual(retried.succeeded, ["wifi", "ethernet"])
        XCTAssertTrue(retried.failures.isEmpty)
        XCTAssertEqual(events.withLock { $0.grants }, 2)
        XCTAssertEqual(events.withLock { $0.authorizedIDs }, [["ethernet"]])
    }

    func testConcurrentRestoresSerializeAuthorizationAndWrites() async throws {
        let events = OSAllocatedUnfairLock(initialState: Events())
        let session = SystemServiceProxy.RestorationSession(write: { items, authorization, _ in
            events.withLock { value in
                value.active += 1
                value.maximumActive = max(value.maximumActive, value.active)
            }
            defer { events.withLock { $0.active -= 1 } }
            // 模拟独立队列上的阻塞系统调用，让并发请求有机会重叠。
            Thread.sleep(forTimeInterval: 0.005)
            return (.init(succeeded: authorization == nil ? [] : items.map(\.id)), authorization == nil)
        }, grant: { _ in events.withLock { $0.grants += 1 }; return errAuthorizationSuccess })
        let items = try settings()
        let results = await withTaskGroup(of: SystemServiceResult.self) { group in
            for _ in 0..<8 { group.addTask { await session.restore(items) } }
            var results: [SystemServiceResult] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0.succeeded == ["wifi"] && $0.failures.isEmpty })
        XCTAssertEqual(events.withLock { $0.grants }, 1)
        XCTAssertEqual(events.withLock { $0.maximumActive }, 1)
    }

    func testNoChangeAndEmptyRestoreDoNotRequestAuthorization() async throws {
        let events = OSAllocatedUnfairLock(initialState: Events())
        let session = SystemServiceProxy.RestorationSession(write: { items, _, _ in
            events.withLock { $0.writes += 1 }
            return (.init(succeeded: items.map(\.id)), false)
        }, grant: { _ in events.withLock { $0.grants += 1 }; return errAuthorizationDenied })
        _ = await session.restore([])
        let unchanged = await session.restore(try settings())
        XCTAssertEqual(unchanged.succeeded, ["wifi"])
        XCTAssertEqual(events.withLock { $0.writes }, 1)
        XCTAssertEqual(events.withLock { $0.grants }, 0)
    }

    func testConfigurationComparisonIncludesUnknownFieldsAndProtocolState() throws {
        let original: [String: Any] = ["HTTPEnable": 0, "HTTPProxy": "disabled.corp.example", "UnknownData": Data([0, 1, 2])]
        let target = try SystemServiceSettings(id: "wifi", name: "Wi-Fi", dictionary: original, protocolEnabled: false)
        XCTAssertTrue(target.matches(configuration: ["UnknownData": Data([0, 1, 2]), "HTTPProxy": "disabled.corp.example", "HTTPEnable": 0], protocolEnabled: false))
        XCTAssertFalse(target.matches(configuration: original, protocolEnabled: true))
        var changed = original
        changed["UnknownData"] = Data([3])
        XCTAssertFalse(target.matches(configuration: changed, protocolEnabled: false))
        changed = original
        changed["HTTPProxy"] = "another.corp.example"
        XCTAssertFalse(target.matches(configuration: changed, protocolEnabled: false))
        let absent = try SystemServiceSettings(id: "wifi", name: "Wi-Fi", dictionary: nil)
        XCTAssertTrue(absent.matches(configuration: nil, protocolEnabled: true))
        XCTAssertFalse(absent.matches(configuration: [:], protocolEnabled: true))
    }

    func testFailedApplicationForcesRetryEvenIfDiskConfigurationMatches() async throws {
        let events = OSAllocatedUnfairLock(initialState: Events())
        let session = SystemServiceProxy.RestorationSession(write: { items, _, retryIDs in
            let count = events.withLock { value in value.writes += 1; return value.writes }
            if count == 1 { return (.init(failures: ["Wi-Fi": "apply failed"]), false) }
            // 第二次磁盘配置可能已经一致，仍须应用上次未完成的服务。
            return (.init(succeeded: items.filter { retryIDs.contains($0.id) }.map(\.id)), false)
        }, grant: { _ in events.withLock { $0.grants += 1 }; return errAuthorizationDenied })
        let items = try settings()
        let failed = await session.restore(items)
        XCTAssertNotNil(failed.error)
        let retried = await session.restore(items)
        XCTAssertEqual(retried.succeeded, ["wifi"])
        XCTAssertNil(retried.error)
        XCTAssertEqual(events.withLock { $0.grants }, 0)
    }

    func testCurrentNetworkConfigurationNeedsNoWriteAuthorization() {
        let current = SystemServiceProxy.read()
        XCTAssertTrue(current.failures.isEmpty, String(describing: current.failures))
        XCTAssertFalse(current.settings.isEmpty, "测试机器应有网络服务")
        let unchanged = SystemServiceProxy.writeConfigurations(current.settings, authorization: nil)
        XCTAssertFalse(unchanged.needsAuthorization)
        XCTAssertNil(unchanged.result.error)
        XCTAssertEqual(Set(unchanged.result.succeeded), Set(current.settings.map(\.id)))
    }
}
