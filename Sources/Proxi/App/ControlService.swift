import AppKit
import Combine

/// 本机控制接口：Unix 套接字上的 JSON-RPC 服务，命令行和 MCP 都经它操作正在运行的 Proxi。
/// 按「自动化」里的权限决定能做什么。只在主线程上用。
@MainActor
final class ControlService: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var problem: String?
    /// 最近一次有人调用接口的时间和来源。
    @Published private(set) var lastCall: (client: String, tool: String, date: Date)?

    private weak var state: AppState?
    private var server: ControlSocketServer?
    private var cancellables = Set<AnyCancellable>()

    init() {}

    /// 调用来源给人看的名字。
    static func clientTitle(_ client: String) -> String {
        switch client {
        case "cli": return L("命令行")
        case "mcp": return L("AI 助手")
        case "url": return L("URL 命令")
        case "ui": return L("设置")
        default: return client
        }
    }

    func start(state: AppState) {
        self.state = state
        state.$config
            .map(\.automation.permission)
            .removeDuplicates()
            .sink { [weak self] permission in
                Task { @MainActor in self?.apply(permission) }
            }
            .store(in: &cancellables)
    }

    func stop() {
        server?.stop()
        server = nil
        listening = false
    }

    private func apply(_ permission: ControlPermission) {
        if permission == .off {
            if server != nil {
                stop()
                Log.info("本机控制接口已关闭")
            }
            return
        }
        guard server == nil else { return }
        let server = ControlSocketServer { [weak self] line in
            guard let self else { return JSONRPC.encode(JSONRPC.error(id: nil, code: JSONRPC.internalError, message: L("Proxi 正在退出"))) }
            return self.handleBlocking(line)
        }
        do {
            try server.start()
            self.server = server
            listening = true
            problem = nil
            Log.info("本机控制接口已开启：\(server.path)")
        } catch {
            listening = false
            problem = error.localizedDescription
            Log.error("本机控制接口开启失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 请求

    /// 套接字线程上调用：转到主线程处理，等结果。
    nonisolated func handleBlocking(_ line: Data) -> Data {
        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor [weak self] in
            if let self {
                box.data = await self.handle(line)
            } else {
                box.data = JSONRPC.encode(JSONRPC.error(id: nil, code: JSONRPC.internalError, message: L("Proxi 正在退出")))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.data
    }

    func handle(_ line: Data) async -> Data {
        guard let message = JSONRPC.decode(line) else {
            return JSONRPC.encode(JSONRPC.error(id: nil, code: JSONRPC.parseError, message: L("不是正确的 JSON")))
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return JSONRPC.encode(JSONRPC.error(id: id, code: JSONRPC.invalidRequest, message: L("缺少 method")))
        }
        let params = (message["params"] as? [String: Any]) ?? [:]
        let client = (message["client"] as? String) ?? "cli"
        do {
            let result = try await call(method, params: params, client: client)
            return JSONRPC.encode(JSONRPC.result(id: id, result))
        } catch let error as ControlError {
            return JSONRPC.encode(JSONRPC.error(id: id, code: error.code, message: error.message))
        } catch {
            return JSONRPC.encode(JSONRPC.error(id: id, code: JSONRPC.internalError, message: error.localizedDescription))
        }
    }

    /// 执行一个工具。URL 命令也走这里（client 是 "url"）。
    func call(_ method: String, params raw: [String: Any], client: String) async throws -> [String: Any] {
        guard let state else { throw ControlError.failed(L("Proxi 还没准备好")) }
        guard let tool = ControlCatalog.tool(named: method) else {
            throw Self.unknownTool(method)
        }
        let permission = state.config.automation.permission
        guard permission.allows(tool.permission) else {
            throw ControlError(code: JSONRPC.permissionDenied, message: L("权限不够：「%@」需要「%@」，现在是「%@」。在 Proxi 设置的「自动化」页可以调整。", tool.title, tool.permission.title, permission.title))
        }
        lastCall = (client, method, Date())
        if tool.permission != .readOnly {
            Log.info("\(Self.clientTitle(client)) 调用了 \(method)")
        }
        // URL 命令多半是用户自己点的（快捷指令、启动器），钥匙串里没有密码时可以弹窗问；命令行和 AI 助手不弹。
        return try await perform(tool, params: ControlParams(raw), state: state, askForPassword: client == "url")
    }

    private static func unknownTool(_ name: String) -> ControlError {
        ControlError(code: JSONRPC.methodNotFound, message: L("没有这个工具：%@。可用的有：%@", name, ControlCatalog.tools.map(\.name).joined(separator: L("、"))))
    }

    // MARK: - 各个工具

    private func perform(_ tool: ControlTool, params: ControlParams, state: AppState, askForPassword: Bool) async throws -> [String: Any] {
        switch tool.name {
        case "get_status":
            return status(state)
        case "list_profiles":
            let profiles = state.config.profiles.map { profile -> [String: Any] in
                [
                    "name": profile.name,
                    "type": profile.kind.rawValue,
                    "summary": profile.summary,
                    "targets": profile.targets.map(\.rawValue).sorted(),
                    "active": state.status.isOn && state.status.profile?.id == profile.id,
                ]
            }
            return ["text": L("%@ 个代理配置", profiles.count), "profiles": profiles]
        case "get_logs":
            let lines = min(500, max(10, params.int("lines") ?? 80))
            return ["text": L("最近的日志"), "app": Log.tail(lines: lines)]
        case "turn_on", "use_profile":
            let profile: Profile
            if let name = params.string("profile") {
                profile = try resolveProfile(name, state: state)
            } else if tool.name == "use_profile" {
                throw ControlError.invalid(L("缺少参数 %@", "profile"))
            } else if let current = state.status.profile ?? state.selectedProfile {
                // 关着时是下次开启的那个，开着时是正在用的，系统代理被别的程序设置了时是上次用的。
                profile = current
            } else {
                throw ControlError.failed(L("还没有代理配置"))
            }
            await waitForIdle(state)
            state.turnOn(profile, askForPassword: askForPassword)
            await waitForIdle(state)
            if let error = state.lastError, !(state.status.isOn && state.status.profile?.id == profile.id) { throw ControlError.failed(L("开启失败：%@", error)) }
            return ["text": L("已开启「%@」（%@）", profile.name, profile.summary)]
        case "turn_off":
            await waitForIdle(state)
            state.turnOff()
            await waitForIdle(state)
            return ["text": L("代理已关闭")]
        case "toggle":
            await waitForIdle(state)
            state.toggle(askForPassword: askForPassword)
            await waitForIdle(state)
            return ["text": state.status.isOn ? L("代理已开启：%@", state.status.profile?.name ?? "") : L("代理已关闭")]
        case "test_profiles":
            var profiles = state.config.profiles
            if let name = params.string("profile") {
                profiles = [try resolveProfile(name, state: state)]
            }
            var results: [[String: Any]] = []
            for profile in profiles {
                await state.test(profile, askForPassword: askForPassword)
                let result = state.testResults[profile.id]
                var item: [String: Any] = ["profile": profile.name, "ok": result?.ok ?? false, "message": result?.message ?? ""]
                if let latency = result?.latencyMs { item["latencyMs"] = latency }
                results.append(item)
            }
            let reachable = results.filter { ($0["ok"] as? Bool) == true }.count
            return ["text": L("测了 %@ 个配置，%@ 个能连上", results.count, reachable), "results": results]
        default:
            throw Self.unknownTool(tool.name)
        }
    }

    // MARK: - 小工具

    func status(_ state: AppState) -> [String: Any] {
        var proxy: [String: Any] = [:]
        let text: String
        switch state.status {
        case .on(let profile):
            proxy = ["state": "on", "profile": profile.name, "summary": profile.summary, "targets": profile.targets.map(\.rawValue).sorted()]
            text = state.isPartiallyApplied ? L("代理部分开启：%@", profile.name) : L("代理已开启：%@", profile.name)
        case .off(let next):
            proxy = ["state": "off", "next": next?.name ?? ""]
            text = L("代理已关闭") + (next.map { L("（下次开启「%@」）", $0.name) } ?? "")
        case .external(let summary):
            proxy = ["state": "external", "summary": summary]
            text = L("系统代理由别的程序设置：%@", summary)
        }
        proxy["appliedTargets"] = state.appliedTargets.map(\.rawValue).sorted()
        proxy["targetStates"] = Dictionary(uniqueKeysWithValues: state.targetStatuses.map { ($0.key.rawValue, $0.value.rawValue) })
        proxy["systemProxyChangedExternally"] = state.systemProxyChangedExternally
        var result: [String: Any] = ["text": text, "proxy": proxy, "systemProxy": state.snapshot.summary, "version": UpdateChecker.currentVersion]
        // 自动化和 CI 按状态确认启动、切页和更新，不依赖日志的中文措辞。
        let settings = SettingsWindowController.shared
        result["busy"] = state.busy
        result["interface"] = [
            "english": AppLanguage.isEnglish,
            "language": LanguageSetting.current.rawValue,
            "visibleWindows": NSApp?.windows.filter { $0.isVisible && $0.frame.width > 100 && $0.frame.height > 50 }.count ?? 0,
            "panelVisible": NSApp?.windows.contains { $0 is PanelWindow && $0.isVisible } ?? false,
            "settingsVisible": settings.isShowing,
            "settingsPage": settings.navigation.page.rawValue,
        ] as [String: Any]
        if let release = state.updater.release {
            result["update"] = ["version": release.version, "installing": state.updater.isInstalling] as [String: Any]
        }
        switch state.health {
        case .ok: result["health"] = "ok"
        case .down: result["health"] = "down"
        case .unknown: break
        }
        if let error = state.lastError { result["lastError"] = error }
        // 可选扩展：没开启时只报告没开启，不显示别的。
        let extensions = state.extensions
        var ext: [String: Any] = ["enabled": state.persisted.extensionState.enabled]
        if state.persisted.extensionState.enabled {
            ext["installed"] = extensions.isInstalled
            ext["running"] = extensions.status?.coreRunning ?? false
            if let port = extensions.status?.mixedPort { ext["port"] = port }
        }
        result["extension"] = ext
        return result
    }

    private func resolveProfile(_ name: String, state: AppState) throws -> Profile {
        let profiles = state.config.profiles
        if let exact = profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return exact }
        let matches = profiles.filter { $0.name.localizedCaseInsensitiveContains(name) }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty {
            throw ControlError.invalid(L("没有叫「%@」的配置。有：%@", name, profiles.map(\.name).joined(separator: L("、"))))
        }
        throw ControlError.invalid(L("「%@」对上了 %@ 个配置：%@，写完整一点", name, matches.count, matches.map(\.name).joined(separator: L("、"))))
    }

    /// 等开关代理的操作做完（最多 60 秒：开启「代理引擎」那条配置时要先等代理引擎的内核起来，最多 30 秒）。
    private func waitForIdle(_ state: AppState) async {
        for _ in 0..<600 {
            if !state.busy { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// 套接字线程和主线程之间传结果。
private final class ResponseBox: @unchecked Sendable {
    var data = Data()
}
