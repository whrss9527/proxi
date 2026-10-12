import XCTest
@testable import ProxiWidgets

final class SnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func value(running: Bool = true) -> ProxyWidgetSnapshot {
        ProxyWidgetSnapshot(now: now, mode: .on, health: .ok, healthCheckedAt: now,
                            selectedName: "Work", profiles: [WidgetProfile(id: "id", name: "Work")],
                            busy: false, partial: false, appRunning: running)
    }
    func testRoundTripAndMinimalFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try value().write(in: directory)
        XCTAssertEqual(ProxyWidgetSnapshot.read(in: directory), value())
        let text = String(decoding: try JSONEncoder().encode(value()), as: UTF8.self)
        for field in ["password", "token", "host", "port", "username"] { XCTAssertFalse(text.contains(field)) }
        try Data("broken".utf8).write(to: directory.appendingPathComponent("status-v1.json"))
        XCTAssertNil(ProxyWidgetSnapshot.read(in: directory))
    }
    func testStaleAndStoppedStates() {
        XCTAssertFalse(value().isStale(at: now))
        XCTAssertTrue(value().isStale(at: now.addingTimeInterval(901)))
        XCTAssertTrue(value().isStale(at: now.addingTimeInterval(-120)))
        XCTAssertTrue(value(running: false).isStale(at: now))
    }
    func testUnknownSchemaCannotMasqueradeAsCurrentState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try value().write(in: directory)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value())) as? [String: Any])
        json["version"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("status-v1.json"))
        XCTAssertNil(ProxyWidgetSnapshot.read(in: directory))
    }
    func testLinkNamesAreEncodedWithoutNewCommands() {
        let profile = WidgetProfile(id: "id", name: "公司 & test/#")
        let components = URLComponents(url: profile.link, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.host, "use")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "name", value: profile.name)])
    }
}
