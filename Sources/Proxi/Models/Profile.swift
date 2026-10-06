import Foundation

/// 代理的种类：HTTP（同时用于 HTTPS）、SOCKS5，或者 PAC 脚本。
enum ProxyKind: String, Codable, CaseIterable, Identifiable {
    case http
    case socks5
    case pac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .http: return "HTTP / HTTPS"
        case .socks5: return "SOCKS5"
        case .pac: return L("PAC 脚本")
        }
    }
}

/// 开启配置时要改动的地方。
enum ProxyTarget: String, Codable, CaseIterable, Identifiable {
    case system
    case environment
    case git
    case npm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("系统代理")
        case .environment: return L("环境变量")
        case .git: return "git"
        case .npm: return "npm / pnpm / yarn"
        }
    }

    var detail: String {
        switch self {
        case .system: return L("浏览器和大多数软件都走它")
        case .environment: return L("只对之后新启动的程序生效；已运行的终端 App 新开窗口也不算，须重开整个 App 或复制命令。sudo 默认清除环境变量，sudo -E 可尝试保留（须符合 sudo 策略）。")
        case .git: return L("git clone、pull 等（全局 http.proxy）")
        case .npm: return L("写入用户目录的 .npmrc（npm、pnpm 和 yarn 1 都读它）")
        }
    }
}

/// 配置的颜色候选，与 Windows 版一致。
enum ProfilePalette {
    static let colors = ["#16a34a", "#2563eb", "#7c3aed", "#db2777", "#ea580c", "#0891b2"]

    static func color(at index: Int) -> String {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// 一套代理配置：指向你自己已经在用的代理服务器，比如公司代理、内网网关，
/// 或者本机的调试代理（Charles、Proxyman、mitmproxy）。
struct Profile: Codable, Identifiable, Equatable, Hashable {
    static let defaultBypass = "localhost, 127.0.0.1, *.local, 169.254/16, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16"
    static let defaultNoProxy = "localhost,127.0.0.1,::1"

    var id: UUID = UUID()
    var name: String = L("新配置")
    var color: String = ProfilePalette.colors[0]
    var kind: ProxyKind = .http
    var host: String = "127.0.0.1"
    var port: Int = 8080
    var pacURL: String = ""
    var bypass: String = Profile.defaultBypass
    var noProxy: String = Profile.defaultNoProxy
    var targets: Set<ProxyTarget> = [.system]
    /// 代理服务器要求登录时的用户名；不需要就留空。
    var username: String = ""
    /// 有没有密码。密码本身只存在这台 Mac 的钥匙串里（ProxyKeychain），不写进配置文件、不跟 iCloud 同步。
    var hasPassword: Bool = false
    /// 扩展「代理引擎」的那条配置（指向代理引擎的本机端口）。只在扩展开着时出现在列表里，由 ExtensionManager 维护，
    /// 不写进 config.json、不跟 iCloud 同步（以前的版本存的是 "engine": true，读配置时去掉）。
    var engine = false

    init() {}

    init(name: String, color: String, kind: ProxyKind = .http, host: String = "127.0.0.1", port: Int = 8080, pacURL: String = "", targets: Set<ProxyTarget> = [.system]) {
        self.name = name
        self.color = color
        self.kind = kind
        self.host = host
        self.port = port
        self.pacURL = pacURL
        self.targets = targets
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, kind, host, port, pacURL, bypass, noProxy, targets, username, hasPassword
    }

    /// 只读不写的键。
    private enum LegacyKeys: String, CodingKey {
        case engine
    }

    /// 每一项单独容错：认不出的类型、生效范围（比如新版本加的）用默认值或者跳过，不让这条配置读失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? L("新配置")
        color = (try? container.decodeIfPresent(String.self, forKey: .color)) ?? ProfilePalette.colors[0]
        kind = (try? container.decodeIfPresent(ProxyKind.self, forKey: .kind)) ?? .http
        host = (try? container.decodeIfPresent(String.self, forKey: .host)) ?? "127.0.0.1"
        port = (try? container.decodeIfPresent(Int.self, forKey: .port)) ?? 8080
        pacURL = (try? container.decodeIfPresent(String.self, forKey: .pacURL)) ?? ""
        bypass = (try? container.decodeIfPresent(String.self, forKey: .bypass)) ?? Profile.defaultBypass
        noProxy = (try? container.decodeIfPresent(String.self, forKey: .noProxy)) ?? Profile.defaultNoProxy
        if let names = try? container.decodeIfPresent([String].self, forKey: .targets) {
            let known = Set(names.compactMap(ProxyTarget.init(rawValue:)))
            targets = known.isEmpty && !names.isEmpty ? Set([ProxyTarget.system]) : known
        } else {
            targets = [.system]
        }
        username = (try? container.decodeIfPresent(String.self, forKey: .username)) ?? ""
        hasPassword = (try? container.decodeIfPresent(Bool.self, forKey: .hasPassword)) ?? false
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        engine = (try? legacy.decodeIfPresent(Bool.self, forKey: .engine)) ?? false
    }

    /// 以前版本里代理引擎那条配置（存的是 "engine": true）。
    static func isLegacyBuiltIn(_ object: Any) -> Bool {
        ((object as? [String: Any])?["engine"] as? Bool) == true
    }

    /// 扩展「代理引擎」的配置：HTTP 和 SOCKS 都指向它在本机的端口。
    static func engineProfile(id: UUID = UUID(), port: Int) -> Profile {
        var profile = Profile(name: L("代理引擎"), color: ProfilePalette.colors[1], kind: .http, host: "127.0.0.1", port: port)
        profile.id = id
        profile.engine = true
        profile.targets = [.system]
        return profile
    }

    /// host:port。
    var serverAddress: String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// 要不要登录。
    var hasCredentials: Bool { !username.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 开启时要不要到钥匙串里取密码。
    var needsPassword: Bool { kind != .pac && hasCredentials && hasPassword }

    /// 不带密码的地址（显示、复制用户名时用）。
    var proxyURL: String { proxyURL(password: "") }

    /// 环境变量、git、npm 使用的地址；要登录时带上用户名和密码（按网址的规则转义）。密码从钥匙串里取出来再传进来。
    func proxyURL(password: String) -> String {
        let scheme = kind == .socks5 ? "socks5" : "http"
        guard hasCredentials else { return "\(scheme)://\(serverAddress)" }
        let user = Profile.escapeUserInfo(username.trimmingCharacters(in: .whitespaces))
        let pass = password.isEmpty ? "" : ":" + Profile.escapeUserInfo(password)
        return "\(scheme)://\(user)\(pass)@\(serverAddress)"
    }

    /// 网址里用户名、密码部分的转义：只保留字母、数字和 -._~，其余都转成 %XX。
    static func escapeUserInfo(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// 菜单和列表里显示的一句话（不含密码）。
    var summary: String {
        switch kind {
        case .pac: return pacURL.isEmpty ? L("PAC 脚本") : pacURL
        case .socks5: return (hasCredentials ? "socks5://\(username)@" : "socks5://") + serverAddress
        case .http: return (hasCredentials ? "\(username)@" : "") + serverAddress
        }
    }

    /// 环境变量、git、npm 需要一个服务器地址；PAC 配置只能设置系统代理。
    var supportsNonSystemTargets: Bool { kind != .pac }

    /// 开启时写进系统的部分一样（名字、颜色不算）：只改了名字或颜色的配置不用重新应用。
    func appliesSame(as other: Profile) -> Bool {
        var mine = self
        var theirs = other
        mine.name = ""
        theirs.name = ""
        mine.color = ""
        theirs.color = ""
        return mine == theirs
    }

    /// 例外列表拆成 networksetup 需要的条目。
    var bypassDomains: [String] { BypassList.domains(from: bypass) }

    /// 校验，返回问题描述；没有问题返回 nil。
    func validate() -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            return L("请填写配置名称")
        }
        switch kind {
        case .pac:
            let text = pacURL.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
                return L("PAC 地址要以 http://、https:// 或 file:// 开头")
            }
        case .http, .socks5:
            let trimmedHost = host.trimmingCharacters(in: .whitespaces)
            if trimmedHost.isEmpty || trimmedHost.contains(where: { $0.isWhitespace || "/?#@".contains($0) }) {
                return L("请填写正确的主机地址，例如 127.0.0.1")
            }
            if port < 1 || port > 65535 {
                return L("端口需要是 1~65535 之间的数字")
            }
        }
        if targets.isEmpty {
            return L("至少选择一个生效范围")
        }
        return nil
    }
}

/// 例外列表（不经代理的地址）的解析。
enum BypassList {
    /// 按逗号、分号、空格拆分，去掉 Windows 风格的 <local>，"10.*" 这样的通配 IP 转成 CIDR。
    static func domains(from text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" }) {
            var item = String(raw).trimmingCharacters(in: .whitespaces)
            if item.isEmpty || item == "*" || item.lowercased() == "<local>" || item.lowercased() == "<-loopback>" {
                continue
            }
            if item.hasSuffix(".*") {
                let octets = item.dropLast(2).split(separator: ".").map(String.init)
                if octets.count >= 1 && octets.count <= 3 && octets.allSatisfy({ Int($0) != nil }) {
                    var padded = octets
                    while padded.count < 4 { padded.append("0") }
                    item = padded.joined(separator: ".") + "/\(octets.count * 8)"
                }
            }
            if seen.insert(item).inserted {
                result.append(item)
            }
        }
        return result
    }
}
