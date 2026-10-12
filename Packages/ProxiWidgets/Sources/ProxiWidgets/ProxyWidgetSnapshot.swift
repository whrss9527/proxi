import Foundation

public struct WidgetProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = String(name.prefix(256)) }

    public var link: URL {
        var url = URLComponents()
        url.scheme = "proxi"
        url.host = "use"
        url.queryItems = [URLQueryItem(name: "name", value: name)]
        return url.url!
    }
}

public struct ProxyWidgetSnapshot: Codable, Equatable, Sendable {
    public static let group = "group.com.whrss9527.proxyswitch.widgets"
    public enum Mode: String, Codable, Sendable { case on, off, external }
    public enum Health: String, Codable, Sendable { case unknown, ok, down }
    public let version: Int
    public let recordedAt: Date
    public let mode: Mode
    public let health: Health
    public let healthCheckedAt: Date?
    public let selectedName: String?
    public let profiles: [WidgetProfile]
    public let busy: Bool
    public let partial: Bool
    public let appRunning: Bool

    public init(now: Date, mode: Mode, health: Health, healthCheckedAt: Date?, selectedName: String?, profiles: [WidgetProfile], busy: Bool, partial: Bool, appRunning: Bool = true) {
        version = 1; recordedAt = now; self.mode = mode; self.health = health
        self.healthCheckedAt = healthCheckedAt
        self.selectedName = selectedName.map { String($0.prefix(256)) }
        var seen = Set<String>()
        self.profiles = Array(profiles.filter { seen.insert($0.id).inserted }.prefix(100))
        self.busy = busy; self.partial = partial; self.appRunning = appRunning
    }

    public func isStale(at now: Date) -> Bool {
        !appRunning || now.timeIntervalSince(recordedAt) > 15 * 60 || recordedAt > now.addingTimeInterval(60)
    }

    public static func read(in directory: URL) -> Self? {
        let file = directory.appendingPathComponent("status-v1.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1, value.profiles.count <= 100,
              Set(value.profiles.map(\.id)).count == value.profiles.count else { return nil }
        return value
    }

    public func write(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("status-v1.json"), options: .atomic)
    }
}
