import XCTest
import Security
@testable import Proxi

final class SystemServiceRestorerTests: XCTestCase {
    private func service(_ id: String) throws -> SystemServiceSettings {
        try SystemServiceSettings(id: id, name: id, dictionary: ["HTTPEnable": 0, "HTTPProxy": "saved.example", "Unknown": ["Value": 1]])
    }

    /// 只创建没有任何权限的引用；写入替身不会访问网络设置，也不会请求系统授权。
    private func emptyAuthorization() -> (OSStatus, AuthorizationRef?) {
        var reference: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &reference)
        return (status, reference)
    }

    func testReusesAuthorizationForSubsequentRestores() async throws {
        let settings = [try service("wifi")]
        var creations = 0
        var unauthenticated = 0
        var authenticated = 0
        let restorer = SystemServiceRestorer(write: { items, reference in
            if reference == nil {
                unauthenticated += 1
                return (SystemServiceResult(failures: ["wifi": "access denied"]), true)
            }
            authenticated += 1
            return (SystemServiceResult(succeeded: items.map(\.id)), false)
        }, createAuthorization: {
            creations += 1
            return self.emptyAuthorization()
        })
        let first = await restorer.restore(settings)
        let second = await restorer.restore(settings)
        XCTAssertEqual(first.succeeded, ["wifi"])
        XCTAssertEqual(second.succeeded, ["wifi"])
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(unauthenticated, 1)
        XCTAssertEqual(authenticated, 2)
    }

    func testCancelledAuthorizationIsNotRetriedInSameOperation() async throws {
        var writes = 0
        let restorer = SystemServiceRestorer(write: { _, _ in
            writes += 1
            return (SystemServiceResult(failures: ["wifi": "cancelled"]), true)
        }, createAuthorization: emptyAuthorization)
        let settings = [try service("wifi")]
        let first = await restorer.restore(settings)
        XCTAssertEqual(writes, 2) // 普通尝试一次，创建引用后由框架检查一次。
        XCTAssertEqual(first.failures["wifi"], "cancelled")
        let second = await restorer.restore(settings)
        XCTAssertEqual(writes, 3) // 已有引用的检查失败后不再弹第二次。
        XCTAssertEqual(second.failures["wifi"], "cancelled")
    }

    func testAlreadyRestoredServiceIsNotRetriedWithAuthorization() async throws {
        let settings = [try service("wifi"), try service("ethernet")]
        var retried: [String] = []
        let restorer = SystemServiceRestorer(write: { items, reference in
            if reference == nil {
                return (SystemServiceResult(succeeded: ["wifi"], failures: ["ethernet": "access denied"]), true)
            }
            retried = items.map(\.id)
            return (SystemServiceResult(succeeded: retried), false)
        }, createAuthorization: emptyAuthorization)
        let result = await restorer.restore(settings)
        XCTAssertEqual(retried, ["ethernet"])
        XCTAssertEqual(Set(result.succeeded), ["wifi", "ethernet"])
        XCTAssertNil(result.error)
    }

    func testAuthorizationCreationFailurePreservesCompletedServices() async throws {
        let restorer = SystemServiceRestorer(write: { _, _ in
            (SystemServiceResult(succeeded: ["wifi"], failures: ["ethernet": "access denied"]), true)
        }, createAuthorization: { (errAuthorizationDenied, nil) })
        let result = await restorer.restore([try service("wifi"), try service("ethernet")])
        XCTAssertEqual(result.succeeded, ["wifi"])
        XCTAssertNil(result.failures["wifi"])
        XCTAssertNotNil(result.failures["ethernet"])
    }

    func testConcurrentRestoresAreSerializedWithoutUnneededAuthorization() async throws {
        let lock = NSLock()
        var active = 0
        var peak = 0
        let restorer = SystemServiceRestorer(write: { items, _ in
            lock.lock()
            active += 1
            peak = max(peak, active)
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.02)
            lock.lock()
            active -= 1
            lock.unlock()
            return (SystemServiceResult(succeeded: items.map(\.id)), false)
        }, createAuthorization: {
            XCTFail("不需要权限的写入不应创建授权引用")
            return (errAuthorizationDenied, nil)
        })
        let wifi = try service("wifi")
        let ethernet = try service("ethernet")
        async let first = restorer.restore([wifi])
        async let second = restorer.restore([ethernet])
        let results = await [first, second]
        XCTAssertTrue(results.allSatisfy { $0.error == nil })
        XCTAssertEqual(peak, 1)
    }

    func testConfigurationComparisonIncludesDisabledAndUnknownFields() throws {
        let original = try service("wifi")
        var current: [String: Any] = ["Unknown": ["Value": 1], "HTTPProxy": "saved.example", "HTTPEnable": 0]
        XCTAssertTrue(original.matches(dictionary: current, protocolEnabled: true))
        current["HTTPProxy"] = "other.example"
        XCTAssertFalse(original.matches(dictionary: current, protocolEnabled: true))
        current = original.dictionary ?? [:]
        current["Unknown"] = ["Value": 2]
        XCTAssertFalse(original.matches(dictionary: current, protocolEnabled: true))
        XCTAssertFalse(original.matches(dictionary: original.dictionary, protocolEnabled: false))
        let empty = try SystemServiceSettings(id: "empty", name: "Empty", dictionary: nil)
        XCTAssertTrue(empty.matches(dictionary: nil, protocolEnabled: true))
        XCTAssertFalse(empty.matches(dictionary: [:], protocolEnabled: true))
    }
}
