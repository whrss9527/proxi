import Foundation

/// 要写入系统的代理设置，以及生成 networksetup 命令的逻辑（纯函数，便于测试）。
struct DesiredProxy: Equatable, Sendable {
    struct Endpoint: Equatable, Sendable {
        var host: String
        var port: Int
        /// 代理要求登录时的用户名和密码；用户名为空表示不用登录。
        var username: String = ""
        var password: String = ""
    }

    var http: Endpoint?
    /// HTTPS（安全网页代理）；开启配置时和 http 一样，恢复开启前的设置时可能是别的地址或者关着。
    var https: Endpoint?
    var socks: Endpoint?
    var pacURL: String?
    var autoDiscovery = false
    var bypassDomains: [String] = []

    /// 开启一个配置时的设置：开启期间关掉自动发现（WPAD），避免网络里的自动配置盖过手动设置。
    /// password 是从钥匙串里取出来的密码（不用登录时是空的）。
    init(profile: Profile, password: String = "") {
        switch profile.kind {
        case .http:
            http = Endpoint(host: profile.host, port: profile.port, username: profile.username, password: password)
            https = http
        case .socks5:
            socks = Endpoint(host: profile.host, port: profile.port, username: profile.username, password: password)
        case .pac:
            pacURL = profile.pacURL.trimmingCharacters(in: .whitespaces)
        }
        bypassDomains = profile.bypassDomains
    }

    /// 关闭代理：所有协议关掉，例外列表保留；autoDiscovery 恢复成开启前的值。
    init(offWithAutoDiscovery autoDiscovery: Bool, bypassDomains: [String]) {
        self.autoDiscovery = autoDiscovery
        self.bypassDomains = bypassDomains
    }

    /// 恢复到某个快照（关闭代理时的“恢复开启前的设置”）：HTTP 和 HTTPS 各按各的恢复，原来只开了其中一个或者地址不同时也一样。
    init(restoring snapshot: ProxySnapshot) {
        if snapshot.httpActive {
            http = Endpoint(host: snapshot.httpHost, port: snapshot.httpPort)
        }
        if snapshot.httpsActive {
            https = Endpoint(host: snapshot.httpsHost, port: snapshot.httpsPort)
        }
        if snapshot.socksActive {
            socks = Endpoint(host: snapshot.socksHost, port: snapshot.socksPort)
        }
        if snapshot.pacActive {
            pacURL = snapshot.pacURL
        }
        autoDiscovery = snapshot.autoDiscovery
        bypassDomains = snapshot.exceptions
    }

    /// 命令里带的密码（要登录时才带；出错时从输出里去掉）。
    var passwords: [String] {
        [http, https, socks].compactMap { $0 }.filter { !$0.username.trimmingCharacters(in: .whitespaces).isEmpty && !$0.password.isEmpty }.map(\.password)
    }

    /// 写到一个网络服务所需的 networksetup 参数列表（不含程序名），按顺序执行。
    /// 关闭某个协议时只改开关，保留记录的地址，和系统设置界面的行为一致。
    func commands(service: String) -> [[String]] {
        var commands: [[String]] = []
        func set(_ setter: String, _ switcher: String, _ endpoint: Endpoint?) {
            if let endpoint {
                let user = endpoint.username.trimmingCharacters(in: .whitespaces)
                if user.isEmpty {
                    commands.append([setter, service, endpoint.host, String(endpoint.port)])
                } else {
                    // 要登录的代理：networksetup 把用户名和密码交给系统保存。
                    commands.append([setter, service, endpoint.host, String(endpoint.port), "on", user, endpoint.password])
                }
                commands.append([switcher, service, "on"])
            } else {
                commands.append([switcher, service, "off"])
            }
        }
        set("-setwebproxy", "-setwebproxystate", http)
        set("-setsecurewebproxy", "-setsecurewebproxystate", https)
        set("-setsocksfirewallproxy", "-setsocksfirewallproxystate", socks)
        if let pacURL, !pacURL.isEmpty {
            commands.append(["-setautoproxyurl", service, pacURL])
            commands.append(["-setautoproxystate", service, "on"])
        } else {
            commands.append(["-setautoproxystate", service, "off"])
        }
        commands.append(["-setproxyautodiscovery", service, autoDiscovery ? "on" : "off"])
        commands.append(["-setproxybypassdomains", service] + (bypassDomains.isEmpty ? ["Empty"] : bypassDomains))
        return commands
    }
}
