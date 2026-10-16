import Foundation

/// 内核自己的 DNS：给直连的网站解析域名、给 IP 类规则（GEOIP、IP-CIDR）判断归属。默认不开，用系统的 DNS。
/// 开了以后国内的域名交给国内的加密 DNS，解析结果不在国内的再问海外 DNS（经「节点」查询，不怕污染）。
struct DNSSettings: Codable, Equatable {
    static let defaultNameservers = ["https://doh.pub/dns-query", "https://dns.alidns.com/dns-query"]
    static let defaultFallback = ["https://1.1.1.1/dns-query", "https://dns.google/dns-query"]
    static let defaultBootstrap = ["223.5.5.5", "119.29.29.29"]

    var enabled: Bool = false
    /// 主要的 DNS：支持 IP、udp://、tcp://、tls://（DoT）、https://（DoH）、quic://（DoQ）、system。
    var nameservers: [String] = DNSSettings.defaultNameservers
    /// 海外 DNS：主要的 DNS 给出的结果不在国内（可能被污染）时改用它的结果。空表示不用。
    var fallback: [String] = DNSSettings.defaultFallback
    /// 海外 DNS 经「节点」查询。
    var fallbackViaProxy: Bool = true
    /// 解析 DoH / DoT 服务器自己的域名用的 DNS，只能填 IP。
    var bootstrap: [String] = DNSSettings.defaultBootstrap
    /// 按域名指定 DNS，比如公司内网的域名交给公司的 DNS。
    var policies: [DNSPolicy] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, nameservers, fallback, fallbackViaProxy, bootstrap, policies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        nameservers = try container.decodeIfPresent([String].self, forKey: .nameservers) ?? DNSSettings.defaultNameservers
        fallback = try container.decodeIfPresent([String].self, forKey: .fallback) ?? DNSSettings.defaultFallback
        fallbackViaProxy = try container.decodeIfPresent(Bool.self, forKey: .fallbackViaProxy) ?? true
        bootstrap = try container.decodeIfPresent([String].self, forKey: .bootstrap) ?? DNSSettings.defaultBootstrap
        policies = try container.decodeIfPresent([DNSPolicy].self, forKey: .policies) ?? []
    }

    /// 校验，返回问题；没问题返回 nil。
    func validate() -> String? {
        guard enabled else { return nil }
        if nameservers.isEmpty { return L("至少填一个 DNS 服务器") }
        for server in nameservers + fallback {
            if let problem = DNSSettings.validateServer(server) { return problem }
        }
        if bootstrap.isEmpty { return L("至少填一个用来解析 DNS 服务器域名的 IP") }
        for server in bootstrap {
            let host = DNSSettings.plainHost(server)
            if !IPPrefix.isIPv4Address(host) && !IPPrefix.isIPv6Address(host) { return L("「%@」要填 IP 地址", server) }
        }
        var domains = Set<String>()
        for policy in policies {
            if let problem = policy.validate() { return problem }
            if !domains.insert(policy.domain.lowercased()).inserted { return L("域名「%@」已经指定了 DNS，请编辑已有条目", policy.domain) }
        }
        return nil
    }

    /// 按稳定 ID 编辑，域名不能重复，避免生成同名的 YAML 键。
    mutating func savePolicy(_ policy: DNSPolicy) -> String? {
        if let problem = policy.validate() { return problem }
        if policies.contains(where: { $0.id != policy.id && $0.domain.lowercased() == policy.domain.lowercased() }) {
            return L("域名「%@」已经指定了 DNS，请编辑已有条目", policy.domain)
        }
        if let index = policies.firstIndex(where: { $0.id == policy.id }) { policies[index] = policy }
        else { policies.append(policy) }
        return nil
    }

    /// DNS 服务器的写法：IP（可带端口）、udp:// tcp:// tls:// https:// quic:// dhcp://网卡、system。
    static func validateServer(_ raw: String) -> String? {
        let server = raw.trimmingCharacters(in: .whitespaces)
        if server.isEmpty { return L("DNS 服务器不能为空") }
        if server.contains(where: { $0.isWhitespace || $0 == "," || $0 == "\"" }) { return L("「%@」里不能有空格、逗号或引号", server) }
        if server == "system" || server == "system://" { return nil }
        if let range = server.range(of: "://") {
            let scheme = server[..<range.lowerBound].lowercased()
            guard ["udp", "tcp", "tls", "https", "http", "quic", "dhcp"].contains(scheme) else {
                return L("「%@」的协议不认识：支持 udp、tcp、tls、https、quic、dhcp", server)
            }
            let rest = server[range.upperBound...]
            return rest.isEmpty ? L("「%@」没有写服务器地址", server) : nil
        }
        let host = plainHost(server)
        if IPPrefix.isIPv4Address(host) || IPPrefix.isIPv6Address(host) { return nil }
        return L("「%@」不是 IP：域名形式的服务器要写成 https://… 或 tls://…", server)
    }

    /// 「1.1.1.1:53」「[2606:4700::1111]:53」去掉端口。
    static func plainHost(_ server: String) -> String {
        var text = server.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), let end = text.firstIndex(of: "]") {
            return String(text[text.index(after: text.startIndex)..<end])
        }
        if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon])
        }
        return text
    }

    /// 从一段文字（逗号、空格、换行分隔）拆出服务器列表。
    static func parseList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace })  // l10n-ignore：全角逗号
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 海外 DNS 经某个策略组查询：内核的写法是在地址后面加 #组名。
    static func routed(_ server: String, via group: String) -> String {
        server.contains("#") ? server : server + "#" + group
    }
}

/// 一条按域名指定的 DNS。
struct DNSPolicy: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// 域名：example.com 只管它自己，+.example.com 连同子域名，*.example.com 只管一级子域名。
    var domain: String = ""
    var servers: [String] = []

    init(domain: String, servers: [String]) {
        self.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.servers = servers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, domain, servers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        domain = (try container.decodeIfPresent(String.self, forKey: .domain) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        servers = (try container.decodeIfPresent([String].self, forKey: .servers) ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func validate() -> String? {
        if !HostEntry.validDomainPattern(domain) { return L("认不出域名「%@」", domain) }
        if servers.isEmpty { return L("「%@」没有填 DNS 服务器", domain) }
        for server in servers {
            if let problem = DNSSettings.validateServer(server) { return problem }
        }
        return nil
    }
}

/// 一条 Hosts：把域名固定解析到某个 IP（或者另一个域名）。
struct HostEntry: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// 域名，可以用 *. 或 +. 开头。
    var domain: String = ""
    /// 一个或多个 IP（逗号分隔），或者一个域名（别名）。
    var value: String = ""
    var enabled: Bool = true

    init(domain: String, value: String) {
        self.domain = domain.trimmingCharacters(in: .whitespaces).lowercased()
        self.value = value.trimmingCharacters(in: .whitespaces)
    }

    private enum CodingKeys: String, CodingKey {
        case id, domain, value, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// 值拆成 IP 列表；是域名别名时是那一个域名。
    var values: [String] {
        value.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }  // l10n-ignore：全角逗号
    }

    func validate() -> String? {
        if !HostEntry.validDomainPattern(domain) { return L("认不出域名「%@」", domain) }
        let items = values
        if items.isEmpty { return L("「%@」没有填 IP", domain) }
        // 一个域名（至少有一个字母，1.2.3 这种写错的 IP 不算）就是别名。
        if items.count == 1, RuleConverter.looksLikeDomain(items[0]), items[0].contains(where: \.isLetter) { return nil }
        for item in items where !IPPrefix.isIPv4Address(item) && !IPPrefix.isIPv6Address(item) {
            return L("「%@」不是 IP（要么填一个或多个 IP，要么填一个域名当别名）", item)
        }
        return nil
    }

    /// 域名写法：example.com、*.example.com、+.example.com、.example.com。
    static func validDomainPattern(_ text: String) -> Bool {
        var value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("*.") || value.hasPrefix("+.") {
            value = String(value.dropFirst(2))
        } else if value.hasPrefix(".") {
            value = String(value.dropFirst())
        }
        if value.isEmpty { return false }
        if !value.contains(".") {
            // 单个词的主机名（比如 router、nas）也行。
            return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        return RuleConverter.looksLikeDomain(value)
    }
}
