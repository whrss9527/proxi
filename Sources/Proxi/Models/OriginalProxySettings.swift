import Foundation

/// 只保存代理字段。缺少某个键表示开启前没有它；数组保留 Git 多值、npm 重复行和空值。
struct ProxyScopeSnapshot: Codable, Equatable, Sendable {
    typealias Values = [String: [String]]
    var values: Values
    var secretID: UUID?
    var unreadable = false

    init(values: Values, secretID: UUID? = nil, unreadable: Bool = false) {
        self.values = values
        self.secretID = secretID
        self.unreadable = unreadable
    }

    private enum CodingKeys: String, CodingKey { case values, secretID, unreadable }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decode(Values.self, forKey: .values)
        secretID = try container.decodeIfPresent(UUID.self, forKey: .secretID)
        unreadable = try container.decodeIfPresent(Bool.self, forKey: .unreadable) ?? false
    }

    static func capture(_ values: Values, storeSecret: (String, UUID) throws -> Void = { try ProxyKeychain.set($0, for: $1) }) throws -> Self {
        let containsSecret = values.values.joined().contains { Redact.secrets($0) != $0 }
        guard containsSecret else { return Self(values: values) }
        let id = UUID()
        let data = try JSONEncoder().encode(values)
        try storeSecret(String(decoding: data, as: UTF8.self), id)
        return Self(values: values.mapValues { $0.map(Redact.secrets) }, secretID: id)
    }

    func resolved(loadSecret: (UUID) -> String? = { ProxyKeychain.password(for: $0) }) throws -> Values {
        guard !unreadable else { throw RestorationError.unavailable }
        guard let secretID else { return values }
        guard let text = loadSecret(secretID), let result = try? JSONDecoder().decode(Values.self, from: Data(text.utf8)) else {
            throw RestorationError.unavailable
        }
        return result
    }

    func discardSecret() {
        if let secretID { ProxyKeychain.delete(for: secretID) }
    }

    var summary: String {
        if unreadable { return L("无法读取") }
        let lines = values.keys.sorted().flatMap { key in
            (values[key] ?? []).map { key + "=" + Redact.secrets($0) }
        }
        return lines.isEmpty ? L("未设置") : lines.joined(separator: "; ")
    }
}

enum RestorationError: LocalizedError {
    case unavailable
    var errorDescription: String? { L("无法读取开启前的代理设置，保留当前设置以便重试") }
}

struct OriginalProxySettings: Codable, Equatable, Sendable {
    var environment: ProxyScopeSnapshot?
    var git: ProxyScopeSnapshot?
    var npm: ProxyScopeSnapshot?

    init() {}

    subscript(_ target: ProxyTarget) -> ProxyScopeSnapshot? {
        get {
            switch target {
            case .environment: return environment
            case .git: return git
            case .npm: return npm
            case .system: return nil
            }
        }
        set {
            switch target {
            case .environment: environment = newValue
            case .git: git = newValue
            case .npm: npm = newValue
            case .system: break
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case environment, git, npm }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys) -> ProxyScopeSnapshot? {
            do { return try container.decodeIfPresent(ProxyScopeSnapshot.self, forKey: key) }
            catch { return ProxyScopeSnapshot(values: [:], unreadable: true) }
        }
        environment = read(.environment)
        git = read(.git)
        npm = read(.npm)
    }
}
