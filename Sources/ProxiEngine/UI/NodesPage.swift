import AppKit
import SwiftUI

/// 节点与订阅页：订阅地址、节点列表、策略组、代理模式、端口、内核状态和日志。
struct NodesPage: View {
    @Environment(\.settingsWindowVisible) private var windowVisible
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @ObservedObject var navigation: SettingsNavigation
    @State private var newName = ""
    @State private var newURL = ""
    @State private var addProblem: String?
    @State private var mixedPortText = ""
    @State private var apiPortText = ""
    @State private var showLog = false
    @State private var logText = ""
    @State private var editingSubscription: Subscription?
    @State private var editingGroup: PolicyGroup?
    @State private var importing = false
    @State private var newGroupName = ""
    @State private var newGroupKind: PolicyGroupKind = .select
    @State private var newGroupFilter = ""
    @State private var groupProblem: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("节点与订阅"), subtitle: L("填订阅地址或者添加节点，节点就会出现在下面的列表里；策略组给某类流量单独选节点"))
            Form {
                coreSection
                subscriptionsSection
                ManualNodesSection(state: state, engine: engine)
                NodeListSection(state: state, engine: engine)
                groupsSection
                modeSection
                portsSection
                if showLog {
                    logSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            mixedPortText = String(state.config.engine.mixedPort)
            apiPortText = String(state.config.engine.apiPort)
        }
        .sheet(item: $editingSubscription) { subscription in
            SubscriptionEditor(state: state, engine: engine, subscription: subscription)
        }
        .sheet(item: $editingGroup) { group in
            GroupEditor(state: state, engine: engine, group: group)
        }
        .sheet(isPresented: $importing) {
            ImportSheet(state: state, initial: nil)
        }
    }

    // MARK: - 内核

    private var coreSection: some View {
        Section(L("代理引擎")) {
            Toggle(L("启用代理引擎（内核 mihomo）"), isOn: Binding(get: { state.config.engine.enabled }, set: { engine.setEnabled($0) }))
            LabeledContent(L("状态")) { statusView }
            if !engine.coreAvailable {
                Label(L("还没有下载内核，到「内核」页下载"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(L("Proxi 的配置列表里的「代理引擎」就是它：开启后系统代理指向 127.0.0.1:%@，在这里选节点、切换模式。", String(state.config.engine.mixedPort)))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(L("重启内核")) {
                    Task { await engine.restartCore() }
                }
                .disabled(!state.config.engine.wantsCore)
                Button(showLog ? L("隐藏日志") : L("查看日志")) { showLog.toggle() }
            }
            if let error = engine.lastError {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch engine.status {
        case .off:
            Text(!state.config.engine.enabled ? L("已停用") : (state.config.engine.wantsCore ? L("未运行") : L("还没有订阅")))
                .foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(L("正在启动…"))
                    .foregroundStyle(.secondary)
            }
        case .running(let version):
            Label(L("运行中 · mihomo %@ · %@ 个节点", version, engine.nodes.count), systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 订阅

    private var subscriptionsSection: some View {
        Section(L("订阅‖列表")) {
            if state.config.engine.subscriptions.isEmpty {
                Text(L("还没有订阅。把服务提供方给你的订阅地址粘到下面，节点由内核下载和解析。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.config.engine.subscriptions) { subscription in
                SubscriptionRow(
                    subscription: subscription,
                    status: engine.subscriptionStatus[subscription.id],
                    updating: engine.updatingSubscription == subscription.id,
                    canUpdate: engine.isRunning,
                    options: optionsSummary(subscription),
                    onUpdate: { Task { await engine.updateSubscription(subscription.id) } },
                    onToggle: { engine.setSubscription(subscription.id, enabled: $0) },
                    onEdit: { editingSubscription = subscription },
                    onDelete: { engine.removeSubscription(subscription.id) }
                )
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("", text: $newName, prompt: Text(L("名称（可选）")))
                        .labelsHidden()
                        .frame(width: 140)
                    TextField("", text: $newURL, prompt: Text(L("订阅地址 https://…")))
                        .labelsHidden()
                        .onSubmit { add() }
                    Button(L("添加")) { add() }
                        .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addProblem {
                    Text(addProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button(L("导入配置…")) { importing = true }
                    .controlSize(.small)
                    .help(L("导入 mihomo / Surge / Quantumult X 格式的配置，或者代理引擎导出的配置"))
            }
            if !state.config.engine.subscriptions.isEmpty {
                Text(L("订阅每 %@ 小时自动更新一次。内核以 clash.meta 的身份下载，订阅返回 mihomo 格式的配置或 base64 节点列表都可以。齿轮里能设筛选（只要某些地区、去掉「剩余流量」这类假节点）、名字前缀和前置代理。", String(state.config.engine.updateIntervalHours)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 订阅设了哪些选项，一句话。
    private func optionsSummary(_ subscription: Subscription) -> String {
        var parts: [String] = []
        if !subscription.filter.isEmpty { parts.append(L("只保留 %@", subscription.filter)) }
        if !subscription.exclude.isEmpty { parts.append(L("去掉 %@", subscription.exclude)) }
        if !subscription.prefix.isEmpty { parts.append(L("前缀「%@」", subscription.prefix)) }
        if let dialer = subscription.dialer { parts.append(L("经 %@", DialerReference.title(dialer, profiles: state.config.profiles))) }
        return parts.joined(separator: " · ")
    }

    private func add() {
        addProblem = engine.addSubscription(name: newName, url: newURL)
        if addProblem == nil {
            newName = ""
            newURL = ""
            state.selectEngineProfile()
        }
    }

    // MARK: - 策略组

    private var nodeNames: [String] { engine.nodes.map(\.name) }

    /// 内核里这个组现在的状态（内核没在运行时是 nil）。
    private func liveGroup(_ group: PolicyGroup) -> Engine.GroupState? {
        engine.groupStates.first { $0.name == group.name }
    }

    /// 手动选择的组在内核里的候选成员；别的类型、内核没在运行时是空的。
    private func selectableMembers(_ group: PolicyGroup) -> [String] {
        guard let live = liveGroup(group), live.kind == .select else { return [] }
        return live.members
    }

    private var groupsSection: some View {
        Section(L("策略组")) {
            if state.config.engine.groups.isEmpty {
                Text(L("给某类流量单独选节点：比如建一个组，分流规则里把某些域名指到它，这里就能单独给它选节点。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.config.engine.groups) { group in
                PolicyGroupRow(
                    group: group,
                    nodeNames: nodeNames,
                    current: liveGroup(group)?.now,
                    members: selectableMembers(group),
                    onSelect: { member in Task { await engine.select(group: group.name, member: member) } },
                    onSave: { engine.saveGroup($0) },
                    onEdit: { editingGroup = group },
                    onDelete: { engine.removeGroup(group.id) },
                    onMove: { engine.moveGroup(group.id, up: $0) }
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("", text: $newGroupName, prompt: Text(L("名字，比如 组 A")))
                        .labelsHidden()
                        .frame(width: 140)
                    Picker("", selection: $newGroupKind) {
                        ForEach(PolicyGroupKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: AppLanguage.width(110, english: 135))
                    TextField("", text: $newGroupFilter, prompt: Text(L("节点名筛选（正则），比如 node-a|node-b；空为全部节点")))
                        .labelsHidden()
                        .onSubmit { addGroup() }
                    Button(L("添加")) { addGroup() }
                        .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(newGroupPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let groupProblem {
                    Text(groupProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text(L("手动选择的组多了「节点」「自动选择」和直连三个候选，默认跟随「节点」，所以刚建好时行为不变；自动选择、故障转移、负载均衡只在筛出来的节点里挑，一个都筛不到时内核退回直连。组名不能和节点、内核保留的名字重复。每个组的「高级」里能限定只用某几个订阅、排除节点、把别的组放进来、单独设测速地址和间隔；节点列表里也能按筛选条件直接建组。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var newGroupPreview: String {
        let draft = PolicyGroup(name: newGroupName, kind: newGroupKind, filter: newGroupFilter)
        if PolicyGroup.validateFilter(draft.filter) != nil { return L("筛选不是正确的正则表达式") }
        let matched = draft.matches(nodeNames)
        var text = newGroupKind.detail + L("。")
        if nodeNames.isEmpty {
            text += L("内核启动后能预览筛选到的节点。")
        } else if draft.filter.isEmpty {
            text += L("没有筛选：全部 %@ 个节点。", nodeNames.count)
        } else {
            text += L("筛选到 %@ 个节点", matched.count) + (matched.isEmpty ? L("。") : L("：%@%@", matched.prefix(4).joined(separator: L("、")), matched.count > 4 ? L("…") : ""))
        }
        return text
    }

    private func addGroup() {
        groupProblem = engine.addGroup(name: newGroupName, kind: newGroupKind, filter: newGroupFilter)
        if groupProblem == nil {
            newGroupName = ""
            newGroupFilter = ""
            newGroupKind = .select
        }
    }

    // MARK: - 模式

    private var modeSection: some View {
        Section(L("模式")) {
            Picker(L("代理模式"), selection: Binding(get: { state.config.engine.mode }, set: { engine.setMode($0) })) {
                ForEach(EngineMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Text(state.config.engine.mode == .global ? L("全局代理：除局域网和自定义规则外的全部流量都走选中的节点。") : L("规则分流：按规则集和自定义规则决定哪些走节点、哪些直连、哪些拦截。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("管理分流规则")) { navigation.page = .rules }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - 端口

    /// 1024~65535，两个不一样，也不能和局域网共享的端口撞上（两个入口抢同一个端口）。
    private var portsValid: Bool {
        guard let mixed = Int(mixedPortText), let api = Int(apiPortText) else { return false }
        let share = state.share.port
        return (1024...65535).contains(mixed) && (1024...65535).contains(api) && mixed != api && mixed != share && api != share
    }

    private var portsChanged: Bool {
        Int(mixedPortText) != state.config.engine.mixedPort || Int(apiPortText) != state.config.engine.apiPort
    }

    private var portsSection: some View {
        Section(L("端口")) {
            HStack {
                TextField(L("代理端口"), text: $mixedPortText)
                    .onChange(of: mixedPortText) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { mixedPortText = digits }
                    }
                TextField(L("API 端口"), text: $apiPortText)
                    .onChange(of: apiPortText) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { apiPortText = digits }
                    }
                Button(L("应用")) {
                    engine.setPorts(mixed: Int(mixedPortText) ?? 7890, api: Int(apiPortText) ?? 9097)
                }
                .disabled(!portsValid || !portsChanged)
            }
            Text(L("改端口后内核会重启，Proxi 配置列表里「代理引擎」的端口会跟着改。默认代理端口 7890、API 端口 9097。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section(L("内核日志")) {
            ScrollView {
                Text(logText.isEmpty ? L("还没有日志") : logText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            Text(L("完整日志在配置目录的 core/core.log。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: windowVisible) {
            guard windowVisible else { return }
            while !Task.isCancelled {
                let text = engine.logTail
                if text != logText { logText = text }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// 订阅列表里的一行。
struct SubscriptionRow: View {
    var subscription: Subscription
    var status: Engine.SubscriptionStatus?
    var updating: Bool
    var canUpdate: Bool
    /// 筛选、前缀、前置代理的一句话；空表示没设。
    var options: String = ""
    var onUpdate: () -> Void
    var onToggle: (Bool) -> Void
    var onEdit: () -> Void = {}
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { subscription.enabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                    .font(.system(size: 12, weight: .medium))
                Text(subscription.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !options.isEmpty {
                    Text(options)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            Button {
                onEdit()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("筛选、前缀、前置代理"))
            if updating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(L("更新")) { onUpdate() }
                    .controlSize(.small)
                    .disabled(!canUpdate || !subscription.enabled)
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("删除这条订阅"))
        }
    }

    private var detail: String {
        guard subscription.enabled else { return L("已停用") }
        guard let status else { return L("还没有读取到节点") }
        var parts = [L("%@ 个节点", status.nodeCount)]
        if let info = status.info {
            if let total = info.total, total > 0 {
                parts.append(L("已用 %@ / %@", Engine.bytesText(info.used), Engine.bytesText(total)))
            }
            if let expire = info.expireDate {
                parts.append(L("到期 %@", Self.dateFormatter.string(from: expire)))
            }
        }
        if let updated = status.updatedAt {
            parts.append(L("更新于 %@", Engine.relative(updated)))
        }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// 策略组列表里的一行：名字、类型、筛选可以直接改，改了出现「保存」。
struct PolicyGroupRow: View {
    var group: PolicyGroup
    var nodeNames: [String]
    /// 内核里现在用的成员。
    var current: String?
    /// 手动选择的组在内核里的候选成员（别的类型、内核没在运行时是空的）；选一个就切换过去。
    var members: [String]
    var onSelect: (String) -> Void
    var onSave: (PolicyGroup) -> String?
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onMove: (Bool) -> Void
    @State private var name: String
    @State private var kind: PolicyGroupKind
    @State private var filter: String
    @State private var problem: String?

    init(group: PolicyGroup, nodeNames: [String], current: String?, members: [String], onSelect: @escaping (String) -> Void, onSave: @escaping (PolicyGroup) -> String?, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void, onMove: @escaping (Bool) -> Void) {
        self.group = group
        self.nodeNames = nodeNames
        self.current = current
        self.members = members
        self.onSelect = onSelect
        self.onSave = onSave
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onMove = onMove
        _name = State(initialValue: group.name)
        _kind = State(initialValue: group.kind)
        _filter = State(initialValue: group.filter)
    }

    private var changed: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != group.name || kind != group.kind || filter.trimmingCharacters(in: .whitespaces) != group.filter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                TextField("", text: $name, prompt: Text(L("名字")))
                    .labelsHidden()
                    .frame(width: 140)
                    .onSubmit { save() }
                Picker("", selection: $kind) {
                    ForEach(PolicyGroupKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: AppLanguage.width(110, english: 135))
                TextField("", text: $filter, prompt: Text(L("节点名筛选（正则），空为全部")))
                    .labelsHidden()
                    .onSubmit { save() }
                if changed {
                    Button(L("保存")) { save() }
                        .controlSize(.small)
                }
                Button(L("高级")) { onEdit() }
                    .controlSize(.small)
                    .help(L("只用某几个订阅、排除节点、包含别的组、测速地址和间隔"))
                Menu {
                    Button(L("上移")) { onMove(true) }
                    Button(L("下移")) { onMove(false) }
                    Divider()
                    Button(L("删除策略组"), role: .destructive) { onDelete() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("上移、下移、删除"))
            }
            if !members.isEmpty {
                Menu {
                    ForEach(members, id: \.self) { member in
                        Button {
                            onSelect(member)
                        } label: {
                            if member == current {
                                Label(Self.memberTitle(member), systemImage: "checkmark")
                            } else {
                                Text(Self.memberTitle(member))
                            }
                        }
                    }
                } label: {
                    Text(L("现在用 %@", Self.memberTitle(current ?? "")))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("给「%@」选节点", group.name))
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        // 别处改了这个组（「高级」里、命令行、导入、撤销）：没在这里改过的话跟着更新，免得保存时把旧的名字和筛选写回去。
        .onChange(of: group) { old, new in
            if name == old.name, kind == old.kind, filter == old.filter {
                name = new.name
                kind = new.kind
                filter = new.filter
                problem = nil
            }
        }
    }

    private var detail: String {
        var draft = group
        draft.kind = kind
        draft.filter = filter.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        if PolicyGroup.validateFilter(draft.filter) != nil {
            parts.append(L("筛选不是正确的正则表达式"))
        } else if nodeNames.isEmpty {
            parts.append(L("内核启动后能看到筛选到的节点"))
        } else {
            let matched = draft.matches(nodeNames)
            parts.append(draft.filter.isEmpty ? L("全部 %@ 个节点", nodeNames.count) : L("筛选到 %@ 个节点", matched.count))
        }
        if let current, !current.isEmpty, members.isEmpty {
            parts.append(L("现在用 %@", Self.memberTitle(current)))
        }
        if group.hasAdvancedOptions {
            var advanced: [String] = []
            if !group.sources.isEmpty { advanced.append(L("限定来源")) }
            if !group.exclude.isEmpty { advanced.append(L("排除 %@", group.exclude)) }
            if !group.includeGroups.isEmpty { advanced.append(L("包含 %@", group.includeGroups.map(CoreConfigBuilder.displayName).joined(separator: L("、")))) }
            if !group.testURL.isEmpty || group.interval != 0 { advanced.append(L("单独测速")) }
            if group.kind == .loadBalance && group.strategy != .roundRobin { advanced.append(group.strategy.title) }
            parts.append(advanced.joined(separator: L("，")))
        }
        return parts.joined(separator: " · ")
    }

    /// 成员的显示名：DIRECT 写成直连，内部的组名换成显示的名字。
    private static func memberTitle(_ member: String) -> String {
        if member.isEmpty { return L("…") }
        if member == "DIRECT" { return L("直连") }
        return CoreConfigBuilder.displayName(member)
    }

    private func save() {
        guard changed else { return }
        // 只改名字、类型、筛选，高级选项保持原样。
        var updated = group
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.kind = kind
        updated.filter = filter.trimmingCharacters(in: .whitespaces)
        problem = onSave(updated)
    }
}
