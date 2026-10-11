import Foundation

/// 改系统代理、终端环境变量、git 和 npm 的地方。AppState 经它去改，单元测试换成假的，不碰这台 Mac 的设置。
protocol ProxyBackend: Sendable {
    func currentSystemProxy() -> ProxySnapshot
    /// 写入系统代理，返回写了哪些网络服务（见 SystemProxy.apply）。
    func applySystemProxy(_ desired: DesiredProxy, also services: [String]) async throws -> [String]
    func setEnvironment(proxyURL: String, noProxy: String) async throws
    func clearEnvironment() async throws
    func setGit(proxyURL: String) async throws
    func clearGit() async throws
    func setNpm(proxyURL: String, noProxy: String) throws
    func clearNpm() throws
    func captureProxySettings(for target: ProxyTarget) async throws -> ProxyScopeSnapshot.Values
    func restoreProxySettings(_ values: ProxyScopeSnapshot.Values, for target: ProxyTarget) async throws
}

/// 真正去改这台 Mac 的设置。
struct SystemBackend: ProxyBackend {
    func captureProxySettings(for target: ProxyTarget) async throws -> ProxyScopeSnapshot.Values {
        switch target {
        case .environment: return try await EnvironmentProxy.snapshot()
        case .git: return try await GitProxy.snapshot()
        case .npm: return try NpmProxy.snapshot()
        case .system: return [:]
        }
    }

    func restoreProxySettings(_ values: ProxyScopeSnapshot.Values, for target: ProxyTarget) async throws {
        switch target {
        case .environment: try await EnvironmentProxy.restore(values)
        case .git: try await GitProxy.restore(values)
        case .npm: try NpmProxy.restore(values)
        case .system: break
        }
    }
    func currentSystemProxy() -> ProxySnapshot {
        SystemProxy.current()
    }

    func applySystemProxy(_ desired: DesiredProxy, also services: [String]) async throws -> [String] {
        try await SystemProxy.apply(desired, also: services)
    }

    func setEnvironment(proxyURL: String, noProxy: String) async throws {
        try await EnvironmentProxy.set(proxyURL: proxyURL, noProxy: noProxy)
    }

    func clearEnvironment() async throws {
        try await EnvironmentProxy.clear()
    }

    func setGit(proxyURL: String) async throws {
        try await GitProxy.set(proxyURL: proxyURL)
    }

    func clearGit() async throws {
        try await GitProxy.clear()
    }

    func setNpm(proxyURL: String, noProxy: String) throws {
        try NpmProxy.set(proxyURL: proxyURL, noProxy: noProxy)
    }

    func clearNpm() throws {
        try NpmProxy.clear()
    }
}

/// 退出时清理代理设置。退出时主线程得等它，所以各项同时在后台做，最多等 timeout 秒：
/// 标准账户改系统代理要输管理员密码，密码框开着时终端、git、npm 也照样能先清掉。
enum ExitCleanup {
    /// 返回没清理成功的项和原因；到时间还没做完的也算没成功（下次启动时接着清理）。
    static func run(_ targets: [ProxyTarget], systemProxy desired: DesiredProxy, services: [String], backend: ProxyBackend, timeout: TimeInterval,
                    originals: OriginalProxySettings = OriginalProxySettings(), mode: OffMode = .direct,
                    resolveOriginal: (ProxyScopeSnapshot) throws -> ProxyScopeSnapshot.Values = { try $0.resolved { ProxyKeychain.password(for: $0, allowUI: false) } }) -> [ProxyTarget: String] {
        let outcomes = Outcomes()
        let semaphore = DispatchSemaphore(value: 0)
        // 钥匙串的“禁止交互”是进程级开关，不能让各并行任务相互恢复它。
        // 先串行读出恢复值，再并行修改外部设置；读不到的范围保留原样。
        var loaded: [ProxyTarget: ProxyScopeSnapshot.Values] = [:]
        for target in targets where mode == .restore {
            guard let original = originals[target] else { continue }
            do { loaded[target] = try resolveOriginal(original) }
            catch { outcomes.record(target, problem: Redact.secrets(error.localizedDescription)) }
        }
        let restoreValues = loaded
        let unresolved = Set(outcomes.snapshot().keys)
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for target in targets {
                    group.addTask {
                        guard !unresolved.contains(target) else { return }
                        do {
                            if let values = restoreValues[target] {
                                try await backend.restoreProxySettings(values, for: target)
                            } else {
                                switch target {
                                case .system: _ = try await backend.applySystemProxy(desired, also: services)
                                case .environment: try await backend.clearEnvironment()
                                case .git: try await backend.clearGit()
                                case .npm: try backend.clearNpm()
                                }
                            }
                            outcomes.record(target, problem: nil)
                        } catch {
                            outcomes.record(target, problem: Redact.secrets(error.localizedDescription))
                        }
                    }
                }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        let finished = outcomes.snapshot()
        var failures: [ProxyTarget: String] = [:]
        for target in targets {
            switch finished[target] {
            case .some(.none):
                continue
            case .some(.some(let problem)):
                failures[target] = problem
            case .none:
                failures[target] = L("%@ 秒内没有做完", Int(timeout.rounded()))
            }
        }
        return failures
    }

    /// 各项的结果：nil 是清理成功，字符串是出错的原因；没有记录的是还没做完。
    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [ProxyTarget: String?] = [:]

        func record(_ target: ProxyTarget, problem: String?) {
            lock.lock()
            results.updateValue(problem, forKey: target)
            lock.unlock()
        }

        func snapshot() -> [ProxyTarget: String?] {
            lock.lock()
            defer { lock.unlock() }
            return results
        }
    }
}
