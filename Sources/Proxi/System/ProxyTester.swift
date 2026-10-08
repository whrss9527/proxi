import Foundation
import CFNetwork
import Network

struct TestResult: Equatable {
    var ok: Bool
    var latencyMs: Int?
    var message: String

    var latencyText: String {
        guard let latencyMs else { return ok ? L("可用") : L("失败") }
        return "\(latencyMs) ms"
    }
}

/// 经代理实际访问测速地址，测出延迟。PAC 由系统的 CFNetwork 执行，和浏览器一样。
enum ProxyTester {
    static func test(profile: Profile, password: String = "", testURL: String, timeout: TimeInterval = 8) async -> TestResult {
        guard let url = URL(string: testURL), url.host != nil else {
            return TestResult(ok: false, latencyMs: nil, message: L("测速地址格式不对"))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = proxyDictionary(for: profile, password: password)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpMethod = "GET"
        let started = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let route = profile.kind == .pac ? L("按 PAC 脚本") : L("经代理")
            if (200..<400).contains(status) {
                return TestResult(ok: true, latencyMs: millis, message: L("%@访问成功，HTTP %@", route, status))
            }
            return TestResult(ok: false, latencyMs: millis, message: L("%@访问返回 HTTP %@", route, status))
        } catch {
            return TestResult(ok: false, latencyMs: nil, message: friendlyError(error))
        }
    }

    /// URLSession 的代理设置。
    static func proxyDictionary(for profile: Profile, password: String = "") -> [AnyHashable: Any] {
        var dictionary = baseDictionary(for: profile)
        if profile.kind != .pac, profile.hasCredentials {
            dictionary[kCFProxyUsernameKey as String] = profile.username
            dictionary[kCFProxyPasswordKey as String] = password
        }
        return dictionary
    }

    private static func baseDictionary(for profile: Profile) -> [AnyHashable: Any] {
        switch profile.kind {
        case .http:
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: profile.host,
                kCFNetworkProxiesHTTPPort as String: profile.port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: profile.host,
                kCFNetworkProxiesHTTPSPort as String: profile.port,
            ]
        case .socks5:
            return [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: profile.host,
                kCFNetworkProxiesSOCKSPort as String: profile.port,
            ]
        case .pac:
            return [
                kCFNetworkProxiesProxyAutoConfigEnable as String: 1,
                kCFNetworkProxiesProxyAutoConfigURLString as String: profile.pacURL,
            ]
        }
    }

    static func friendlyError(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorTimedOut: return L("超时，代理没有响应")
        case NSURLErrorCannotConnectToHost: return L("连不上代理服务器")
        case NSURLErrorCannotFindHost: return L("解析不了主机名")
        case NSURLErrorNotConnectedToInternet: return L("没有网络连接")
        default: return nsError.localizedDescription
        }
    }

    /// 检查代理服务器的端口能否连上（健康检查用），不发请求。
    static func reachable(host: String, port: Int, timeout: TimeInterval = 3) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            func finish(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                if finished { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                case .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: DispatchQueue.global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }
}

/// 找出本机正在运行的代理软件监听的端口。
struct DetectedProxy: Identifiable, Equatable {
    var id: String { "\(host):\(port)" }
    var host: String
    var port: Int
    var kind: ProxyKind
    var process: String
    var latencyMs: Int?

    var suggestedName: String {
        process.isEmpty ? L("本机代理 %@", port) : process
    }
}

enum LocalProxyDetector {
    /// 常见的本机代理端口：Charles（8888）、Proxyman（9090）、mitmproxy 和各种开发代理（8080、8081）、
    /// Squid（3128）、Privoxy（8118）、SOCKS（1080）。
    static let commonPorts: [Int] = [1080, 3128, 8080, 8081, 8118, 8888, 8889, 9090, 9091]

    struct Listener: Equatable {
        var port: Int
        var process: String
    }

    /// 按表头找列，兼容旧系统的 pid 和新系统的 process:pid；地址里的最后一个点分隔端口。
    static func parseNetstat(_ output: String, processName: (Int32) -> String = { _ in "" }) -> [Listener] {
        var columns: [String] = []
        var listeners: [Listener] = []
        var seen = Set<Int>()
        for line in output.split(separator: "\n") {
            let fields = line.replacingOccurrences(of: "Local Address", with: "Local-Address")
                .replacingOccurrences(of: "Foreign Address", with: "Foreign-Address")
                .split(whereSeparator: \.isWhitespace).map(String.init)
            if fields.first == "Proto" { columns = fields; continue }
            guard fields.first?.hasPrefix("tcp") == true,
                  let local = columns.firstIndex(of: "Local-Address"),
                  let state = columns.firstIndex(of: "(state)"),
                  let owner = columns.firstIndex(of: "pid") ?? columns.firstIndex(of: "process:pid"),
                  fields.count > max(local, max(state, owner)), fields[state] == "LISTEN",
                  let dot = fields[local].lastIndex(of: "."),
                  let port = Int(fields[local][fields[local].index(after: dot)...]),
                  (1...65535).contains(port), seen.insert(port).inserted else { continue }
            let pid = Int32(fields[owner].split(separator: ":").last ?? "") ?? 0
            listeners.append(Listener(port: port, process: pid > 0 ? processName(pid) : ""))
        }
        return listeners
    }

    static func listeners() async -> [Listener] {
        let result = try? await Shell.run("/usr/sbin/netstat", ["-anv", "-p", "tcp"], timeout: 0.5)
        return parseNetstat(result?.output ?? "") { pid in
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
            return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
        }
    }

    /// 查询、补查和协议探测共用截止时间；没有响应的端口不会让整个检测等待数秒。
    static func detect(testURL: String) async -> [DetectedProxy] {
        let started = ProcessInfo.processInfo.systemUptime
        defer { Log.info(String(format: "本机代理检测耗时 %.3f 秒", ProcessInfo.processInfo.systemUptime - started)) }
        return await detect(testURL: testURL, listeners: listeners,
                     reachable: { await ProxyTester.reachable(host: "127.0.0.1", port: $0, timeout: $1) },
                     probe: { await ProxyTester.test(profile: $0, testURL: $1, timeout: $2) })
    }

    static func detect(testURL: String, listeners: () async -> [Listener],
                       reachable: @escaping (Int, TimeInterval) async -> Bool,
                       probe: @escaping (Profile, String, TimeInterval) async -> TestResult) async -> [DetectedProxy] {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 2.7
        var candidates: [Int: String] = [:]
        for listener in await listeners() where (1...65535).contains(listener.port) {
            candidates[listener.port] = listener.process
        }
        await withTaskGroup(of: Int?.self) { group in
            let timeout = min(0.2, max(0, deadline - ProcessInfo.processInfo.systemUptime))
            guard timeout > 0 else { return }
            for port in commonPorts where candidates[port] == nil {
                group.addTask { await reachable(port, timeout) ? port : nil }
            }
            for await port in group { if let port { candidates[port] = "" } }
        }
        var found: [Int: DetectedProxy] = [:]
        await withTaskGroup(of: DetectedProxy?.self) { group in
            let timeout = min(2, max(0, deadline - ProcessInfo.processInfo.systemUptime))
            guard timeout > 0 else { return }
            for (port, process) in candidates {
                for kind in [ProxyKind.http, .socks5] {
                    group.addTask {
                        let profile = Profile(name: "", color: "#16a34a", kind: kind, host: "127.0.0.1", port: port)
                        let result = await probe(profile, testURL, timeout)
                        guard result.ok else { return nil }
                        return DetectedProxy(host: "127.0.0.1", port: port, kind: kind, process: process, latencyMs: result.latencyMs)
                    }
                }
            }
            for await item in group {
                // 两种协议都可用时沿用 HTTP 优先的顺序，不由任务完成先后决定。
                if let item, found[item.port] == nil || item.kind == .http { found[item.port] = item }
            }
        }
        return found.values.sorted { $0.port < $1.port }
    }
}
