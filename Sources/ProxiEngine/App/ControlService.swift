import AppKit
import Combine

/// 经本机控制接口（命令行、MCP、URL 命令）做过的一件事。改配置的会留着改之前的配置，可以撤销。
struct ControlChange: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    /// 谁做的：命令行、AI 助手（MCP）、URL 命令、导入。
    var client: String
    var tool: String
    var summary: String
    /// 改之前的配置；nil 表示不能撤销（开关代理、切节点这类操作）。
    var before: AppConfig?
    var undone = false

    var canUndo: Bool { before != nil && !undone }

    var clientTitle: String {
        switch client {
        case "cli": return L("命令行")
        case "mcp": return L("AI 助手")
        case "url": return L("URL 命令")
        case "ui": return L("设置")
        default: return client
        }
    }
}

/// 本机控制接口：Unix 套接字上的 JSON-RPC 服务，命令行和 MCP 都经它操作正在运行的 Proxi。
/// 按「自动化」里的权限决定能做什么；改配置的操作记在操作记录里，可以撤销。只在主线程上用。
@MainActor
final class ControlService: ObservableObject {
    static let journalLimit = 20
    static var journalURL: URL { Store.directory.appendingPathComponent("journal.json") }

    @Published private(set) var changes: [ControlChange] = []
    @Published private(set) var listening = false
    @Published private(set) var problem: String?
    /// 最近一次有人调用接口的时间和来源。
    @Published private(set) var lastCall: (client: String, tool: String, date: Date)?

    private weak var state: AppState?
    private var server: ControlSocketServer?
    /// 正在处理的请求来自谁（导入时当来源名用）。
    private var currentClient = "cli"
    private var cancellables = Set<AnyCancellable>()
    private lazy var diagnoser: Diagnoser? = state.map { Diagnoser(state: $0, engine: $0.engine) }

    init() {}

    func start(state: AppState) {
        self.state = state
        changes = Self.loadJournal()
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
            guard let self else { return JSONRPC.encode(JSONRPC.error(id: nil, code: JSONRPC.internalError, message: L("代理引擎正在退出"))) }
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
                box.data = JSONRPC.encode(JSONRPC.error(id: nil, code: JSONRPC.internalError, message: L("代理引擎正在退出")))
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
        guard let state else { throw ControlError.failed(L("代理引擎还没准备好")) }
        guard let tool = ControlCatalog.tool(named: method) else {
            throw ControlError(code: JSONRPC.methodNotFound, message: L("没有这个工具：%@。可用的有：%@", method, ControlCatalog.tools.map(\.name).joined(separator: L("、"))))
        }
        let permission = state.config.automation.permission
        guard permission.allows(tool.permission) else {
            throw ControlError(code: JSONRPC.permissionDenied, message: L("权限不够：「%@」需要「%@」，现在是「%@」。在代理引擎设置的「高级」页可以调整。", tool.title, tool.permission.title, permission.title))
        }
        lastCall = (client, method, Date())
        let params = ControlParams(raw)
        let before = state.config
        currentClient = client
        var result = try await perform(tool, params: params, state: state)
        // 改动了东西的记进操作记录：改了配置的可以撤销。
        if tool.permission != .readOnly && method != "undo" {
            let summary = (result["text"] as? String) ?? tool.title
            let changedConfig = state.config != before
            record(ControlChange(client: client, tool: method, summary: summary, before: changedConfig ? before : nil))
            if changedConfig {
                result["undo"] = L("可以用 undo 撤销这次改动")
            }
        }
        return result
    }

    // MARK: - 操作记录

    private func record(_ change: ControlChange) {
        changes.insert(change, at: 0)
        if changes.count > Self.journalLimit {
            changes.removeLast(changes.count - Self.journalLimit)
        }
        saveJournal()
    }

    /// 撤销最近一次能撤销的改动；返回说明。
    @discardableResult
    func undoLatest() throws -> String {
        guard let state else { throw ControlError.failed(L("代理引擎还没准备好")) }
        guard let index = changes.firstIndex(where: \.canUndo), let before = changes[index].before else {
            throw ControlError.failed(L("没有能撤销的改动"))
        }
        state.config = before
        changes[index].undone = true
        saveJournal()
        Log.info("已撤销：\(changes[index].summary)")
        return L("已撤销：%@", changes[index].summary)
    }

    func undo(_ id: UUID) {
        guard let state, let index = changes.firstIndex(where: { $0.id == id }), let before = changes[index].before, !changes[index].undone else { return }
        state.config = before
        // 比它新的改动也一起失效了。
        for position in 0...index {
            changes[position].undone = true
        }
        saveJournal()
        Log.info("已撤销：\(changes[index].summary)")
    }

    func clearJournal() {
        changes = []
        saveJournal()
    }

    /// 设置页里的导入也记一笔，能撤销。
    func recordImport(summary: String, before: AppConfig) {
        record(ControlChange(client: "ui", tool: "import_config", summary: summary, before: before))
    }

    private static func loadJournal() -> [ControlChange] {
        guard let data = try? Data(contentsOf: journalURL) else { return [] }
        return (try? JSONDecoder().decode([ControlChange].self, from: data)) ?? []
    }

    private func saveJournal() {
        let changes = self.changes
        DispatchQueue.global(qos: .utility).async {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(changes) else { return }
            try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
            try? data.write(to: Self.journalURL, options: .atomic)
        }
    }

    // MARK: - 各个工具

    private func perform(_ tool: ControlTool, params: ControlParams, state: AppState) async throws -> [String: Any] {
        let engine = state.engine
        switch tool.name {
        case "get_status":
            return status(state)
        case "list_nodes":
            var nodes = engine.sortedNodes
            if let filter = params.string("filter") {
                nodes = nodes.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.subscription.localizedCaseInsensitiveContains(filter) }
            }
            // 负数会让 prefix 直接崩溃（只能查看的客户端也能传）：限制在 0…5000。
            let limit = min(5000, max(0, params.int("limit") ?? 200))
            let favorites = Set(state.config.engine.favoriteNodes)
            let list = nodes.prefix(limit).map { node -> [String: Any] in
                var item: [String: Any] = ["name": node.name, "type": node.type, "source": node.subscription]
                if let delay = node.delay { item["delay"] = delay }
                if favorites.contains(node.name) { item["favorite"] = true }
                if engine.effectiveNode == node.name { item["inUse"] = true }
                return item
            }
            let selection = engine.currentSelection ?? ""
            return ["text": L("%@ 个节点", nodes.count) + (selection.isEmpty ? "" : L("，「节点」组现在选的是 %@", selection)), "selected": selection, "nodes": Array(list)]
        case "list_groups":
            var groups: [[String: Any]] = [["name": Engine.selectorGroup, "type": "select", "now": engine.currentSelection ?? "", "builtin": true]]
            groups.append(["name": Engine.autoGroup, "type": "url-test", "now": engine.autoNode ?? "", "builtin": true])
            for group in state.config.engine.groups {
                var item: [String: Any] = ["name": group.name, "type": group.kind.coreType]
                if !group.filter.isEmpty { item["filter"] = group.filter }
                if !group.exclude.isEmpty { item["exclude"] = group.exclude }
                if !group.includeGroups.isEmpty { item["groups"] = group.includeGroups }
                if let live = engine.groupStates.first(where: { $0.name == group.name }) {
                    item["now"] = live.now ?? ""
                    item["members"] = live.members
                }
                groups.append(item)
            }
            return ["text": L("%@ 个自定义策略组", state.config.engine.groups.count), "groups": groups]
        case "list_rules":
            let config = state.config.engine
            let rules = config.customRules.map { rule -> [String: Any] in
                ["id": rule.id.uuidString, "type": rule.kind.rawValue, "value": rule.pattern, "policy": ConfigImporter.policyText(rule.policy), "enabled": rule.enabled]
            }
            let sets = config.ruleSets.map { set -> [String: Any] in
                var item: [String: Any] = ["name": set.name, "url": ConfigImporter.hiddenRuleSetURL(set.url), "enabled": set.enabled, "policy": set.policy.map(ConfigImporter.policyText) ?? "follow"]
                if let count = engine.ruleSetStatus[set.id]?.count { item["rules"] = count }
                if let problem = engine.ruleSetStatus[set.id]?.problem { item["problem"] = problem }
                return item
            }
            return ["text": L("%@ 条自定义规则、%@ 个规则集；%@", rules.count, sets.count, engine.rulesInfo), "mode": config.mode.rawValue, "customRules": rules, "ruleSets": sets, "final": config.finalPolicy.map(ConfigImporter.policyText) ?? "follow"]
        case "list_subscriptions":
            let config = state.config.engine
            let subscriptions = config.subscriptions.map { subscription -> [String: Any] in
                var item: [String: Any] = ["name": subscription.name, "url": ConfigImporter.hiddenURL(subscription.url), "enabled": subscription.enabled]
                if let status = engine.subscriptionStatus[subscription.id] {
                    item["nodes"] = status.nodeCount
                    if let info = status.info {
                        if let total = info.total, total > 0 { item["usage"] = "\(Engine.bytesText(info.used)) / \(Engine.bytesText(total))" }
                        if let expire = info.expireDate { item["expires"] = ISO8601DateFormatter().string(from: expire) }
                    }
                }
                if !subscription.filter.isEmpty { item["filter"] = subscription.filter }
                if !subscription.exclude.isEmpty { item["exclude"] = subscription.exclude }
                if let dialer = subscription.dialer { item["dialer"] = DialerReference.title(dialer, profiles: state.config.profiles) }
                return item
            }
            let manual = config.manualNodes.map { ["name": $0.name, "server": $0.server, "enabled": $0.enabled] as [String: Any] }
            return ["text": L("%@ 条订阅、%@ 个手动节点", subscriptions.count, manual.count), "subscriptions": subscriptions, "manualNodes": manual]
        case "list_connections":
            let limit = min(5000, max(0, params.int("limit") ?? 50))
            let filter = params.string("filter")
            func matches(_ record: ConnectionRecord) -> Bool {
                guard let filter else { return true }
                return [record.host, record.process, record.client, record.rule, record.outbound, record.group].contains { $0.localizedCaseInsensitiveContains(filter) }
            }
            let active = engine.connections.map(ConnectionRecord.init).filter(matches).sorted { $0.start > $1.start }
            let recent = engine.history.filter(matches)
            return ["text": L("现在开着 %@ 条连接", engine.connections.count), "active": active.prefix(limit).map(Self.connection), "recent": recent.prefix(limit).map(Self.connection)]
        case "get_traffic":
            let traffic = engine.traffic
            func entries(_ list: [TrafficEntry], _ count: Int) -> [[String: Any]] {
                list.prefix(count).map { entry -> [String: Any] in
                    ["name": entry.name, "upload": entry.traffic.upload, "download": entry.traffic.download, "text": "↑ \(Engine.bytesText(entry.traffic.upload)) ↓ \(Engine.bytesText(entry.traffic.download))"]
                }
            }
            let total = traffic.total
            return [
                "text": L("从 %@ 起共 ↑ %@ ↓ %@", ISO8601DateFormatter().string(from: traffic.since), Engine.bytesText(total.upload), Engine.bytesText(total.download)),
                "session": ["upload": engine.sessionTraffic.upload, "download": engine.sessionTraffic.download] as [String: Any],
                "byNode": entries(traffic.ranked, 20),
                "bySource": entries(traffic.rankedSources, 20),
                "byDay": entries(Array(traffic.recentDays(14).reversed()), 14),
            ]
        case "get_logs":
            let lines = min(500, max(10, params.int("lines") ?? 80))
            let core = engine.logTail.split(separator: "\n").suffix(lines).joined(separator: "\n")
            return ["text": L("最近的日志"), "app": ControlService.masked(Log.tail(lines: lines), config: state.config), "core": ControlService.masked(core, config: state.config)]
        case "diagnose_url":
            let text = try params.require("url")
            guard let url = DiagnoseTarget.normalize(text) else { throw ControlError.invalid(L("认不出网址：%@", text)) }
            guard let diagnoser else { throw ControlError.failed(L("诊断没准备好")) }
            let verdict = await diagnoser.runAndWait(DiagnoseTarget(url: url, perspective: .mac))
            let checks = diagnoser.rows.map { ["title": $0.title, "result": $0.summary, "detail": $0.detail] }
            return ["text": verdict.map { L("%@：%@", $0.headline, $0.explanation) } ?? L("诊断没有完成"), "checks": checks, "suggestions": verdict?.actions.map(\.title) ?? []]
        case "export_config":
            switch params.string("format") ?? "describe" {
            case "backup":
                let content = try ConfigImporter.backupJSON(ConfigImporter.hidingSecrets(state.config))
                return ["text": L("完整备份（订阅和规则集的地址、手动节点的链接已隐藏）"), "content": content]
            case "core":
                let text = (try? String(contentsOf: engine.configURL, encoding: .utf8)) ?? ""
                let cleaned = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("secret:") }.joined(separator: "\n")
                return ["text": cleaned.isEmpty ? L("内核还没有生成配置") : L("内核配置（去掉了密钥，订阅地址已隐藏）"), "content": ControlService.masked(cleaned, config: state.config)]
            default:
                return ["text": L("Proxi 配置描述（订阅和规则集的地址、手动节点的链接已隐藏；改了以后可以用 import_config 导入，隐藏了的按名字用现有的）"), "content": ConfigImporter.describeJSON(ConfigImporter.hidingSecrets(state.config))]
            }
        case "preview_import":
            let plan = try await state.prepareImport(text: params.string("content"), url: params.string("url"), sourceName: sourceName)
            return ["text": L("导入「%@」（%@）会改动：", plan.sourceName, plan.format.title) + (plan.summaryLines.isEmpty ? L("没有") : plan.summaryLines.joined(separator: L("；"))), "changes": plan.summaryLines, "warnings": plan.warnings]
        case "list_changes":
            let list = changes.map { change -> [String: Any] in
                ["date": ISO8601DateFormatter().string(from: change.date), "client": change.clientTitle, "tool": change.tool, "summary": change.summary, "canUndo": change.canUndo, "undone": change.undone]
            }
            return ["text": list.isEmpty ? L("还没有操作记录") : L("%@ 条操作记录", list.count), "changes": list]

        case "select_node":
            let name = try params.require("name")
            try requireEngine(engine)
            if ["auto", "自动", "自动选择"].contains(name.lowercased()) {  // l10n-ignore：参数里的写法
                state.selectEngineProfile()
                await engine.select(nil)
                return ["text": L("已切到自动选择") + (engine.autoNode.map { L("，现在用的是 %@", $0) } ?? "")]
            }
            let node = try resolve(name, in: engine.nodes.map(\.name), kind: L("节点"))
            state.selectEngineProfile()
            await engine.select(node)
            if let error = engine.lastError, error.hasPrefix(L("切换节点失败：%@", "")) { throw ControlError.failed(error) }
            var text = L("已切换到节点 %@", node)
            if !state.status.isOn || state.status.profile?.engine != true {
                text += L("（在 Proxi 里开启「代理引擎」这个配置后生效）")
            }
            return ["text": text]
        case "select_group":
            try requireEngine(engine)
            let groupName = try params.require("group")
            let group = try resolve(groupName, in: [Engine.selectorGroup] + state.config.engine.groupNames, kind: L("策略组"))
            let memberName = try params.require("member")
            if group == Engine.selectorGroup {
                var node: String?
                if memberName != Engine.autoGroup {
                    node = try resolve(memberName, in: engine.nodes.map(\.name) + ["DIRECT"], kind: L("成员"))
                }
                await engine.select(node)
                return ["text": L("「节点」已切到 %@", node ?? CoreConfigBuilder.displayName(Engine.autoGroup))]
            }
            let members = engine.groupStates.first { $0.name == group }?.members ?? []
            let member = try resolve(memberName, in: members, kind: L("成员"))
            await engine.select(group: group, member: member)
            return ["text": L("策略组「%@」已切到 %@", group, member)]
        case "set_mode":
            let value = try params.require("mode")
            guard let mode = EngineMode(rawValue: value.lowercased()) else { throw ControlError.invalid(L("模式只能是 rule 或 global")) }
            engine.setMode(mode)
            return ["text": L("已切到%@", mode.title)]
        case "test_nodes":
            try requireEngine(engine)
            let filter = params.string("filter")
            var results: [String: Int] = [:]
            if let filter {
                let names = engine.nodes.map(\.name).filter { $0.localizedCaseInsensitiveContains(filter) }
                guard !names.isEmpty else { throw ControlError.invalid(L("没有名字里有「%@」的节点", filter)) }
                await withTaskGroup(of: (String, Int).self) { group in
                    for name in names.prefix(60) {
                        group.addTask { @MainActor in (name, await engine.delay(of: name)) }
                    }
                    for await (name, delay) in group {
                        results[name] = delay
                    }
                }
            } else {
                await engine.testAll()
                for node in engine.nodes {
                    results[node.name] = node.delay ?? 0
                }
            }
            let sorted = results.sorted { ($0.value == 0 ? Int.max : $0.value) < ($1.value == 0 ? Int.max : $1.value) }
            let ok = sorted.filter { $0.value > 0 }
            let delays = sorted.map { item -> [String: Any] in ["name": item.key, "delay": item.value] }
            return ["text": L("测了 %@ 个节点，%@ 个能通", results.count, ok.count) + (ok.first.map { L("，最快的是 %@（%@ ms）", $0.key, $0.value) } ?? ""), "delays": delays]
        case "check_url":
            try requireEngine(engine)
            guard let address = params.string("url"), ServiceClassifier.normalize(address) != nil else {
                throw ControlError.invalid(L("要给一个网址，比如 https://example.com"))
            }
            var node = params.string("node")
            if let name = node {
                node = try resolve(name, in: engine.nodes.map(\.name), kind: L("节点"))
            }
            guard let result = await engine.checkURL(address, node: node) else {
                throw ControlError.failed(L("没有检测：内核没在运行，或者正在检测别的网址"))
            }
            return [
                "text": L("经%@访问 %@：%@", node ?? L("现在的节点"), result.url, result.summary),
                "results": [["service": result.url, "result": result.summary, "available": result.isAvailable]],
            ]
        case "update_subscriptions":
            try requireEngine(engine)
            await engine.updateAllSubscriptions()
            return ["text": L("订阅已更新，现在有 %@ 个节点", engine.nodes.count)]
        case "update_rule_sets":
            await engine.refreshAllRuleSets()
            return ["text": L("规则集已重新下载：%@", engine.rulesInfo)]
        case "close_connections":
            if let id = params.string("id") {
                await engine.close(connection: id)
                return ["text": L("已断开连接 %@", id)]
            }
            await engine.closeAllConnections()
            return ["text": L("已断开全部连接")]
        case "set_share":
            guard let enabled = params.bool("enabled") else { throw ControlError.invalid(L("enabled 要写 true 或 false")) }
            state.setShareEnabled(enabled)
            return ["text": enabled ? L("局域网共享已开启，设备填 %@:%@", state.lanAddress?.ip ?? L("这台 Mac 的 IP"), state.share.port) : L("局域网共享已关闭")]
        case "set_tun":
            guard let enabled = params.bool("enabled") else { throw ControlError.invalid(L("enabled 要写 true 或 false")) }
            state.setTunEnabled(enabled)
            guard enabled else { return ["text": L("增强模式已关闭")] }
            guard state.helper.isReady else { return ["text": L("增强模式已打开，但特权助手还不能用（%@），请用户在设置的「高级」页安装", state.helper.summary)] }
            return ["text": state.shareUpstream == .engine ? L("增强模式已开启，所有程序的流量都经过代理引擎") : L("增强模式已打开，本机开着代理引擎时生效")]
        case "set_gateway":
            guard let enabled = params.bool("enabled") else { throw ControlError.invalid(L("enabled 要写 true 或 false")) }
            state.setGatewayEnabled(enabled)
            guard enabled else { return ["text": L("网关模式已关闭")] }
            guard state.helper.isReady else { return ["text": L("网关模式已打开，但特权助手还不能用（%@），请用户在设置的「高级」页安装", state.helper.summary)] }
            let address = state.lanAddress?.ip ?? L("这台 Mac 的 IP")
            return ["text": L("网关模式已开启：设备的「路由器」和 DNS 都填 %@", address)]

        case "add_rule":
            let value = try params.require("value")
            let groups = state.config.engine.groupNames
            let policyText = try params.require("policy")
            let policy = ConfigImporter.target(policyText, groups: groups)
            if case .proxy = policy, !["proxy", "节点", "走节点", "代理"].contains(policyText.lowercased()) {  // l10n-ignore：参数里的写法
                throw ControlError.invalid(L("认不出去向「%@」：%@（现有的策略组：%@）", policyText, ControlCatalog.policyHelp, groups.isEmpty ? L("无") : groups.joined(separator: L("、"))))
            }
            let kind = ConfigImporter.ruleKind(params.string("type")) ?? .auto
            if let problem = engine.addCustomRule(pattern: value, policy: policy, kind: kind) { throw ControlError.invalid(problem) }
            let rule = CustomRule(pattern: value, policy: policy, kind: kind)
            return ["text": L("已加规则：%@%@ → %@", kind == .auto ? "" : kind.title + " ", rule.displayValue, policy.title)]
        case "remove_rule":
            let rules = state.config.engine.customRules
            var targets: [CustomRule] = []
            if let id = params.string("id").flatMap(UUID.init(uuidString:)) {
                targets = rules.filter { $0.id == id }
            } else if let value = params.string("value") {
                targets = rules.filter { $0.pattern == value || $0.pattern == CustomRule.normalize(value, kind: $0.kind) || $0.displayValue == value }
            } else {
                throw ControlError.invalid(L("写上规则的内容（value）或 id"))
            }
            guard !targets.isEmpty else { throw ControlError.invalid(L("没有找到这条规则")) }
            for rule in targets {
                engine.removeCustomRule(rule.id)
            }
            return ["text": L("已删掉 %@ 条规则：%@", targets.count, targets.map(\.displayValue).joined(separator: L("、")))]
        case "set_final":
            let text = try params.require("policy")
            if ["follow", "跟随", "跟随规则文件"].contains(text.lowercased()) {  // l10n-ignore：参数里的写法
                engine.setFinalPolicy(nil)
                return ["text": L("其余流量跟随规则文件")]
            }
            let policy = ConfigImporter.target(text, groups: state.config.engine.groupNames)
            engine.setFinalPolicy(policy)
            return ["text": L("其余流量：%@", policy.title)]
        case "add_subscription":
            let url = try params.require("url")
            if let problem = engine.addSubscription(name: params.string("name") ?? ConfigImporter.subscriptionName(for: url, fallback: ""), url: url) { throw ControlError.invalid(problem) }
            state.selectEngineProfile()
            return ["text": L("已加订阅，内核会去下载节点")]
        case "remove_subscription":
            let name = try params.require("name")
            guard let subscription = state.config.engine.subscriptions.first(where: { $0.name == name || $0.url == name }) ?? uniqueMatch(name, in: state.config.engine.subscriptions, key: \.name) else {
                throw ControlError.invalid(L("没有叫「%@」的订阅", name))
            }
            engine.removeSubscription(subscription.id)
            return ["text": L("已删掉订阅「%@」", subscription.name)]
        case "add_nodes":
            let result = engine.addManualNodes(from: try params.require("links"))
            if let problem = result.problem { throw ControlError.invalid(problem) }
            state.selectEngineProfile()
            return ["text": L("已加 %@ 个手动节点", result.added)]
        case "add_rule_set":
            let groups = state.config.engine.groupNames
            let policy = params.string("policy").map { ConfigImporter.target($0, groups: groups) }
            if let library = params.string("library") {
                guard let entry = RuleLibrary.entry(named: library) else {
                    throw ControlError.invalid(L("规则库里没有「%@」。有：%@", library, RuleLibrary.all.map(\.name).joined(separator: L("、"))))
                }
                if let problem = engine.addRuleSet(name: entry.name, url: entry.url, policy: policy ?? entry.policy, behavior: entry.behavior) { throw ControlError.invalid(problem) }
                return ["text": L("已加规则集「%@」→ %@", entry.name, (policy ?? entry.policy)?.title ?? L("按文件里的"))]
            }
            let url = try params.require("url")
            let draft = RuleSet(name: "", url: url, policy: nil)
            let resolved: RuleTarget? = policy ?? (draft.kind == .inline ? nil : .proxy)
            if let problem = engine.addRuleSet(name: params.string("name") ?? "", url: url, policy: resolved) { throw ControlError.invalid(problem) }
            return ["text": L("已加规则集 %@", RuleSet.defaultName(for: url))]
        case "remove_rule_set":
            let name = try params.require("name")
            let sets = state.config.engine.ruleSets
            guard let set = sets.first(where: { $0.name == name || $0.url == name }) ?? uniqueMatch(name, in: sets, key: \.name) else {
                throw ControlError.invalid(L("没有叫「%@」的规则集", name))
            }
            engine.removeRuleSet(set.id)
            return ["text": L("已删掉规则集「%@」", set.name)]
        case "add_group":
            let name = try params.require("name")
            var group = PolicyGroup(name: name, kind: ConfigImporter.groupKind(params.string("type")) ?? .select, filter: params.string("filter") ?? "")
            group.exclude = params.string("exclude") ?? ""
            if let problem = engine.addGroup(group) { throw ControlError.invalid(problem) }
            return ["text": L("已加策略组「%@」（%@），用 add_rule 把流量指到它", group.name, group.kind.title)]
        case "remove_group":
            let name = try params.require("name")
            guard let group = state.config.engine.groups.first(where: { $0.name == name }) else { throw ControlError.invalid(L("没有叫「%@」的策略组", name)) }
            engine.removeGroup(group.id)
            return ["text": L("已删掉策略组「%@」，指向它的规则改成走节点", name)]
        case "import_config":
            let plan = try await state.prepareImport(text: params.string("content"), url: params.string("url"), sourceName: sourceName)
            let mode = ImportMode(rawValue: params.string("mode") ?? "merge") ?? .merge
            let summary = try state.applyImport(plan, mode: mode)
            var result: [String: Any] = ["text": summary]
            if !plan.warnings.isEmpty { result["warnings"] = plan.warnings }
            return result
        case "undo":
            return ["text": try undoLatest()]
        default:
            throw ControlError(code: JSONRPC.methodNotFound, message: L("没有这个工具：%@", tool.name))
        }
    }

    // MARK: - 小工具

    /// 导入内容的来源名：看是谁发来的。
    private var sourceName: String {
        ControlChange(client: currentClient, tool: "", summary: "").clientTitle
    }

    private func status(_ state: AppState) -> [String: Any] {
        let engine = state.engine
        var proxy: [String: Any] = [:]
        var text: String
        switch state.status {
        case .on(let profile):
            proxy = ["state": "on", "profile": profile.name, "summary": profile.summary]
        case .off:
            proxy = ["state": "off"]
        case .external(let summary):
            proxy = ["state": "external", "summary": summary]
        }
        text = L("代理引擎：%@", engine.statusTitle) + L("，本机端口 %@", String(state.config.engine.mixedPort))
        var core: [String: Any] = ["mode": state.config.engine.mode.rawValue, "nodes": engine.nodes.count]
        switch engine.status {
        case .off: core["status"] = "off"
        case .starting: core["status"] = "starting"
        case .running(let version): core["status"] = "running"; core["version"] = version
        case .failed(let message): core["status"] = "failed"; core["error"] = message
        }
        if let selection = engine.currentSelection { core["selected"] = selection }
        if let node = engine.effectiveNode { core["node"] = node }
        if engine.isRunning, let node = engine.effectiveNode {
            text += L("；节点 %@，%@", node, state.config.engine.mode.title)
        }
        var result: [String: Any] = ["text": text, "proxy": proxy, "engine": core]
        let navigation = SettingsWindowController.shared.navigation
        result["interface"] = [
            "settingsActive": navigation.windowVisible,
            "settingsPage": navigation.page.rawValue,
            "liveLogStreaming": engine.isLiveLogStreaming,
            "speedHistoryPublishing": engine.isSpeedHistoryPublishing,
        ] as [String: Any]
        var share: [String: Any] = ["enabled": state.share.enabled, "port": state.share.port]
        if case .listening = engine.shareStatus { share["listening"] = true }
        if let address = state.lanAddress { share["address"] = address.ip }
        result["share"] = share
        var tun: [String: Any] = ["enabled": state.tun.enabled, "gateway": state.tun.gateway, "summary": state.tunSummary]
        switch state.helper.state {
        case .unknown: tun["helper"] = "unknown"
        case .notInstalled: tun["helper"] = "not-installed"
        case .notRunning: tun["helper"] = "not-running"
        case .outdated: tun["helper"] = "outdated"
        case .ready: tun["helper"] = "ready"
        }
        switch engine.tunStatus {
        case .off: tun["status"] = "off"
        case .starting: tun["status"] = "starting"
        case .on(let forwarding): tun["status"] = "on"; tun["forwarding"] = forwarding
        case .failed(let message): tun["status"] = "failed"; tun["error"] = message
        }
        result["tun"] = tun
        if let exit = engine.exitInfo {
            result["exit"] = ["ip": exit.ip, "country": exit.countryCode, "place": exit.place, "isp": exit.organization]
        }
        if let error = state.lastError ?? engine.lastError { result["lastError"] = error }
        return result
    }

    private static func connection(_ record: ConnectionRecord) -> [String: Any] {
        var item: [String: Any] = ["id": record.id, "target": record.target, "source": record.source, "route": record.route, "rule": record.rule, "upload": record.upload, "download": record.download]
        if !record.network.isEmpty { item["network"] = record.network }
        if record.isShare { item["device"] = record.client }
        return item
    }

    private func requireEngine(_ engine: Engine) throws {
        guard engine.isRunning, state?.config.engine.wantsCore == true else {
            throw ControlError.failed(L("内核没有运行：先用 add_subscription 加订阅，或者 add_nodes 加节点"))
        }
    }

    /// 名字可以只写一部分：完全相同的优先，否则要唯一包含。
    private func resolve(_ name: String, in candidates: [String], kind: String) throws -> String {
        if let exact = candidates.first(where: { $0 == name }) ?? candidates.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return exact }
        let matches = candidates.filter { $0.localizedCaseInsensitiveContains(name) }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty { throw ControlError.invalid(L("没有叫「%@」的%@", name, kind)) }
        throw ControlError.invalid(L("「%@」对上了 %@ 个%@：%@%@，写完整一点", name, matches.count, kind, matches.prefix(8).joined(separator: L("、")), matches.count > 8 ? L("…") : ""))
    }

    private func uniqueMatch<T>(_ name: String, in items: [T], key: KeyPath<T, String>) -> T? {
        let matches = items.filter { $0[keyPath: key].localizedCaseInsensitiveContains(name) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// 等开关代理的操作做完（最多 20 秒）。
    private func waitUntilIdle(_ state: AppState) async {
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(100))
            if !state.busy { return }
        }
    }

    /// 把文字里（内核配置、日志）出现的订阅和规则集地址换成隐藏的写法。
    static func masked(_ text: String, config: AppConfig) -> String {
        var result = text
        let addresses = config.engine.subscriptions.map { ($0.url, ConfigImporter.hiddenURL($0.url)) }
            + config.engine.ruleSets.map { ($0.url, ConfigImporter.hiddenRuleSetURL($0.url)) }
        for (address, hidden) in addresses where !address.isEmpty && address != hidden {
            result = result.replacingOccurrences(of: address, with: hidden)
        }
        return result
    }
}

/// 套接字线程和主线程之间传结果。
private final class ResponseBox: @unchecked Sendable {
    var data = Data()
}
