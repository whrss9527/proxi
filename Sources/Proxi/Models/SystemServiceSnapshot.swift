import Foundation
import SystemConfiguration

/// 服务 ID 不随重命名改变。完整协议字典保留禁用协议的地址及系统未知字段。
struct SystemServiceSettings: Equatable, Sendable {
    var id: String
    var name: String
    var configuration: Data?
    var protocolEnabled: Bool

    init(id: String, name: String, configuration: Data?, protocolEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.configuration = configuration
        self.protocolEnabled = protocolEnabled
    }

    init(id: String, name: String, dictionary: [String: Any]?, protocolEnabled: Bool = true) throws {
        self.id = id
        self.name = name
        self.protocolEnabled = protocolEnabled
        configuration = try dictionary.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
    }

    var dictionary: [String: Any]? {
        guard let configuration else { return nil }
        return (try? PropertyListSerialization.propertyList(from: configuration, options: [], format: nil)) as? [String: Any]
    }

    var snapshot: ProxySnapshot { ProxySnapshot(dictionary: dictionary ?? [:]) }

    /// 二进制 plist 的键顺序不影响设置；未知字段和协议开关都参与比较。
    func matches(configuration current: [String: Any]?, protocolEnabled: Bool) -> Bool {
        guard self.protocolEnabled == protocolEnabled else { return false }
        switch (dictionary, current) {
        case (nil, nil): return true
        case (let saved?, let current?): return NSDictionary(dictionary: saved).isEqual(to: current)
        default: return false
        }
    }

    func backup(storeSecret: (String, UUID) throws -> Void = { try ProxyKeychain.set($0, for: $1) }) throws -> SystemServiceBackup {
        let values = ["configuration": configuration.map { [$0.base64EncodedString()] } ?? [], "enabled": [protocolEnabled ? "1" : "0"]]
        let original = try ProxyScopeSnapshot.protected(values, display: ["proxy": [Redact.secrets(snapshot.summary)]], storeSecret: storeSecret)
        return SystemServiceBackup(id: id, name: name, original: original, autoDiscovery: snapshot.autoDiscovery)
    }
}

struct SystemServiceBackup: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var original: ProxyScopeSnapshot
    var autoDiscovery: Bool

    func resolved(loadSecret: (UUID) -> String? = { ProxyKeychain.password(for: $0) }) throws -> SystemServiceSettings {
        let values = try original.resolved(loadSecret: loadSecret)
        guard let configuration = values["configuration"] else { throw RestorationError.unavailable }
        let enabled = values["enabled"] ?? ["1"]
        guard enabled == ["1"] || enabled == ["0"] else { throw RestorationError.unavailable }
        if configuration.isEmpty { return try SystemServiceSettings(id: id, name: name, dictionary: nil, protocolEnabled: enabled == ["1"]) }
        guard configuration.count == 1, let data = Data(base64Encoded: configuration[0]),
              (try PropertyListSerialization.propertyList(from: data, options: [], format: nil)) is [String: Any] else {
            throw RestorationError.unavailable
        }
        return SystemServiceSettings(id: id, name: name, configuration: data, protocolEnabled: enabled == ["1"])
    }
}

struct SystemServiceRead: Sendable {
    var settings: [SystemServiceSettings] = []
    var failures: [String: String] = [:]
}

struct SystemServiceResult: Sendable {
    var succeeded: [String] = []
    var failures: [String: String] = [:]
    var error: String? { failures.isEmpty ? nil : failures.keys.sorted().map { "\($0): \(failures[$0] ?? "")" }.joined(separator: "; ") }
}

extension ProxySnapshot {
    /// 旧版只有全局快照：保留其恢复语义，不把已经由 Proxi 改过的服务反向当原值。
    var legacyDictionary: [String: Any] {
        [kSCPropNetProxiesHTTPEnable as String: httpEnabled ? 1 : 0,
         kSCPropNetProxiesHTTPProxy as String: httpHost, kSCPropNetProxiesHTTPPort as String: httpPort,
         kSCPropNetProxiesHTTPSEnable as String: httpsEnabled ? 1 : 0,
         kSCPropNetProxiesHTTPSProxy as String: httpsHost, kSCPropNetProxiesHTTPSPort as String: httpsPort,
         kSCPropNetProxiesSOCKSEnable as String: socksEnabled ? 1 : 0,
         kSCPropNetProxiesSOCKSProxy as String: socksHost, kSCPropNetProxiesSOCKSPort as String: socksPort,
         kSCPropNetProxiesProxyAutoConfigEnable as String: pacEnabled ? 1 : 0,
         kSCPropNetProxiesProxyAutoConfigURLString as String: pacURL,
         kSCPropNetProxiesProxyAutoDiscoveryEnable as String: autoDiscovery ? 1 : 0,
         kSCPropNetProxiesExcludeSimpleHostnames as String: excludeSimpleHostnames ? 1 : 0,
         kSCPropNetProxiesExceptionsList as String: exceptions]
    }
}
