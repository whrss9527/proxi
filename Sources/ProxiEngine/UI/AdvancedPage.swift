import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 高级页：导入导出、增强模式、DNS、Hosts、IPv6、内核配置补丁、实时日志、通知和本机控制接口。平时用不到，出问题或者有特殊需要时再来。
struct AdvancedPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @ObservedObject var navigation: SettingsNavigation
    @State private var importing = false
    @State private var importTarget: String?
    @State private var exportProblem: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("高级"), subtitle: L("导入导出配置、增强模式、DNS、Hosts、IPv6、内核配置补丁、实时日志、通知和本机控制接口；不常用，有需要时再改"))
            Form {
                importSection
                TunSection(state: state, engine: engine, helper: state.helper)
                DNSSection(engine: engine, current: state.config.engine.dns)
                HostsSection(engine: engine, hosts: state.config.engine.hosts)
                Section("IPv6") {
                    Toggle(L("允许 IPv6"), isOn: Binding(get: { state.config.engine.ipv6 }, set: { engine.setIPv6($0) }))
                    Text(L("打开后内核会解析和连接 IPv6 地址（节点和网络都支持时更快一些）；网络的 IPv6 不稳定时关掉更省事。默认关。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PatchSection(engine: engine, saved: state.config.engine.patch)
                LiveLogSection(engine: engine)
                GeneralSections(state: state)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $importing) {
            ImportSheet(state: state, initial: importTarget)
        }
        .onAppear { takeImportRequest() }
        .onChange(of: navigation.importRequest) { _, _ in takeImportRequest() }
    }

    private func takeImportRequest() {
        guard let request = navigation.importRequest else { return }
        navigation.importRequest = nil
        importTarget = request
        importing = true
    }

    // MARK: - 导入导出

    private var importSection: some View {
        Section(L("导入与导出")) {
            HStack {
                Button(L("导入配置…")) {
                    importTarget = nil
                    importing = true
                }
                Spacer()
                Menu(L("导出")) {
                    Button(L("完整备份（JSON）…")) { export(.backup) }
                    Button(L("配置描述（JSON，订阅、策略组、规则）…")) { export(.describe) }
                    Button(L("内核配置（YAML）…")) { export(.core) }
                }
                .fixedSize()
            }
            if let exportProblem {
                Text(exportProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(L("能导入代理引擎的 JSON、mihomo 的 YAML、Surge / Quantumult X 格式的配置、节点链接和规则列表，也可以把文件直接拖进这个窗口。完整备份导入时选「替换」就能原样恢复；备份里有订阅地址，不要发给别人。内核配置是现在生成给 mihomo 的，供参考。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private enum ExportKind {
        case backup, describe, core
    }

    private func export(_ kind: ExportKind) {
        exportProblem = nil
        let text: String
        let name: String
        do {
            switch kind {
            case .backup:
                text = try ConfigImporter.backupJSON(state.config)
                name = L("Proxi 备份.json")
            case .describe:
                text = ConfigImporter.describeJSON(state.config)
                name = L("Proxi 配置.json")
            case .core:
                let raw = (try? String(contentsOf: engine.configURL, encoding: .utf8)) ?? ""
                guard !raw.isEmpty else {
                    exportProblem = L("内核还没有生成配置")
                    return
                }
                text = raw.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("secret:") }.joined(separator: "\n")
                name = "mihomo.yaml"
            }
        } catch {
            exportProblem = L("导出失败：%@", error.localizedDescription)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            Log.info("已导出到 \(url.path)")
        } catch {
            exportProblem = L("保存失败：%@", error.localizedDescription)
        }
    }
}

// MARK: - DNS

struct DNSSection: View {
    @ObservedObject var engine: Engine
    var current: DNSSettings
    @State private var enabled = false
    @State private var nameservers = ""
    @State private var fallback = ""
    @State private var fallbackViaProxy = true
    @State private var bootstrap = ""
    @State private var policies: [DNSPolicy] = []
    @State private var newDomain = ""
    @State private var newServers = ""
    @State private var problem: String?
    @State private var loaded = false

    var body: some View {
        Section("DNS") {
            Toggle(L("用内核自己的 DNS"), isOn: $enabled)
            Text(L("默认用系统的 DNS。打开后，直连的网站和 IP 类规则（IP 归属地、网段）用这里的 DNS 解析：先查主要的 DNS，结果的归属地不对时改用备用 DNS 的结果。经节点的网站由节点那边解析，不受影响。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if enabled {
                field(L("DNS 服务器"), text: $nameservers, prompt: "https://doh.pub/dns-query, tls://dns.alidns.com, 223.5.5.5")
                field(L("备用 DNS"), text: $fallback, prompt: L("https://1.1.1.1/dns-query（留空不用）"))
                Toggle(L("备用 DNS 经「节点」查询"), isOn: $fallbackViaProxy)
                field(L("解析 DNS 服务器用的 IP"), text: $bootstrap, prompt: "223.5.5.5, 119.29.29.29")
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("按域名指定 DNS"))
                        .font(.system(size: 12, weight: .medium))
                    ForEach(policies) { policy in
                        HStack {
                            Text(policy.domain)
                                .font(.system(size: 11, design: .monospaced))
                            Text("→ " + policy.servers.joined(separator: ", "))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                policies.removeAll { $0.id == policy.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        TextField("", text: $newDomain, prompt: Text("+.corp.example.com"))
                            .frame(width: 180)
                        TextField("", text: $newServers, prompt: Text("10.0.0.53"))
                        Button(L("加")) {
                            let policy = DNSPolicy(domain: newDomain, servers: DNSSettings.parseList(newServers))
                            if let issue = policy.validate() {
                                problem = issue
                            } else {
                                policies.append(policy)
                                newDomain = ""
                                newServers = ""
                                problem = nil
                            }
                        }
                        .disabled(newDomain.isEmpty || newServers.isEmpty)
                    }
                    Text(L("公司内网、家里的 NAS 这类域名交给指定的 DNS；+.example.com 连同子域名。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button(L("恢复默认")) {
                    let defaults = DNSSettings()
                    nameservers = defaults.nameservers.joined(separator: ", ")
                    fallback = defaults.fallback.joined(separator: ", ")
                    fallbackViaProxy = defaults.fallbackViaProxy
                    bootstrap = defaults.bootstrap.joined(separator: ", ")
                }
                .disabled(!enabled)
                Button(L("应用")) {
                    problem = engine.setDNS(draft)
                }
                .disabled(draft == current)
            }
        }
        .onAppear { load(current) }
        .onChange(of: current) { _, value in load(value) }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            TextField("", text: text, prompt: Text(prompt))
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private var draft: DNSSettings {
        var dns = current
        dns.enabled = enabled
        dns.nameservers = DNSSettings.parseList(nameservers)
        dns.fallback = DNSSettings.parseList(fallback)
        dns.fallbackViaProxy = fallbackViaProxy
        dns.bootstrap = DNSSettings.parseList(bootstrap)
        dns.policies = policies
        return dns
    }

    private func load(_ dns: DNSSettings) {
        enabled = dns.enabled
        nameservers = dns.nameservers.joined(separator: ", ")
        fallback = dns.fallback.joined(separator: ", ")
        fallbackViaProxy = dns.fallbackViaProxy
        bootstrap = dns.bootstrap.joined(separator: ", ")
        policies = dns.policies
    }
}

// MARK: - Hosts

struct HostsSection: View {
    @ObservedObject var engine: Engine
    var hosts: [HostEntry]
    @State private var domain = ""
    @State private var value = ""
    @State private var problem: String?

    var body: some View {
        Section("Hosts") {
            ForEach(hosts) { entry in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { entry.enabled }, set: { enabled in
                        update(entry.id) { $0.enabled = enabled }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Text(entry.domain)
                        .font(.system(size: 12, design: .monospaced))
                    Text("→ " + entry.value)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        problem = engine.setHosts(hosts.filter { $0.id != entry.id })
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("", text: $domain, prompt: Text(L("域名，比如 nas.lan、*.test.com")))
                    .frame(width: 200)
                TextField("", text: $value, prompt: Text(L("IP（多个用逗号分开）或者另一个域名")))
                Button(L("添加")) { add() }
                    .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty || value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(L("把域名固定解析到某个地址：对直连的连接和 IP 类规则生效（经节点的网站由节点那边解析）。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let entry = HostEntry(domain: domain, value: value)
        if let issue = entry.validate() {
            problem = issue
            return
        }
        var updated = hosts.filter { $0.domain != entry.domain }
        updated.append(entry)
        problem = engine.setHosts(updated)
        if problem == nil {
            domain = ""
            value = ""
        }
    }

    private func update(_ id: UUID, _ change: (inout HostEntry) -> Void) {
        var updated = hosts
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        change(&updated[index])
        problem = engine.setHosts(updated)
    }
}

// MARK: - 配置补丁

struct PatchSection: View {
    @ObservedObject var engine: Engine
    var saved: String
    @State private var text = ""
    @State private var checking = false
    @State private var problem: String?
    @State private var message: String?

    static var example: String { AppLanguage.isEnglish ? exampleEnglish : exampleChinese }

    // l10n-ignore：中文界面的例子，英文的在 exampleEnglish。
    static let exampleChinese = """
    # 例子：日志多一些，嗅探加上 QUIC，最前面加一条规则
    log-level: info
    sniffer:
      sniff:
        QUIC:
          ports: [443]
    rules:
      - DOMAIN-SUFFIX,example.org,DIRECT
    """

    static let exampleEnglish = """
    # Example: more logging, sniff QUIC too, and add a rule at the top
    log-level: info
    sniffer:
      sniff:
        QUIC:
          ports: [443]
    rules:
      - DOMAIN-SUFFIX,example.org,DIRECT
    """

    var body: some View {
        Section(L("内核配置补丁")) {
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 150)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            HStack {
                if checking {
                    ProgressView()
                        .controlSize(.small)
                }
                if let problem {
                    Label(problem, systemImage: "xmark.octagon")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                } else if let message {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(L("填入例子")) { text = Self.example }
                    .disabled(!text.isEmpty)
                Button(L("还原")) {
                    text = saved
                    problem = nil
                }
                .disabled(text == saved)
                Button(L("检查并保存")) { save() }
                    .disabled(checking || text.trimmingCharacters(in: .whitespacesAndNewlines) == saved)
            }
            if let current = engine.patchProblem {
                Label(L("正在用没打补丁的配置：%@", current), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(engine.patchNotes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(L("写一段 mihomo 的 YAML，合并进 Proxi 生成的配置：rules 里的规则排在最前面；proxies、proxy-groups、listeners 里的追加进去（同名的替换）；dns、sniffer 这类逐层合并；其余的直接替换。API 地址、密钥和代理端口由 Proxi 管理，写了也不用。保存前会让内核检查一遍，有问题就不保存；以后内核不认了会自动退回没打补丁的配置。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { text = saved }
        .onChange(of: saved) { _, value in text = value }
    }

    private func save() {
        checking = true
        problem = nil
        message = nil
        let content = text
        Task { @MainActor in
            problem = await engine.setPatch(content)
            if problem == nil {
                message = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("已清空补丁") : L("已保存，内核会重新加载")
            }
            checking = false
        }
    }
}

// MARK: - 实时日志

struct LiveLogSection: View {
    @Environment(\.settingsWindowVisible) private var windowVisible
    @ObservedObject var engine: Engine
    @State private var level = "all"
    @State private var filter = ""
    @State private var paused = false
    @State private var frozen: [LogLine] = []
    @State private var subscribed = false

    private var shouldSubscribe: Bool { windowVisible && !paused && engine.isRunning }

    private var lines: [LogLine] {
        let source = paused ? frozen : engine.liveLog
        return source.filter { line in
            (level == "all" || line.level == level) && (filter.isEmpty || line.text.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        Section(L("内核实时日志")) {
            HStack {
                Picker("", selection: $level) {
                    Text(L("全部")).tag("all")
                    Text(L("信息")).tag("info")
                    Text(L("警告")).tag("warning")
                    Text(L("错误")).tag("error")
                }
                .labelsHidden()
                .frame(width: 90)
                TextField("", text: $filter, prompt: Text(L("筛选，比如域名或节点名")))
                Toggle(L("暂停"), isOn: $paused)
                    .toggleStyle(.button)
                    .onChange(of: paused) { _, value in
                        if value { frozen = engine.liveLog }
                    }
                Button(L("复制")) {
                    TerminalCommands.copy(lines.map { "\(Self.timeFormatter.string(from: $0.date)) [\($0.level)] \($0.text)" }.joined(separator: "\n"))
                }
                Button(L("清空")) { engine.clearLiveLog() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(Self.timeFormatter.string(from: line.date))
                                    .foregroundStyle(.secondary)
                                Text(line.text)
                                    .foregroundStyle(color(line.level))
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .onChange(of: engine.liveLog.last?.id) { _, id in
                    guard !paused, let id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            Text(engine.isRunning ? L("看每条连接命中了哪条规则、走了哪个节点、有没有出错；最多保留最近 %@ 行。完整日志在配置目录的 core/core.log。", Engine.liveLogLimit) : L("内核没有运行。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: shouldSubscribe, initial: true) { _, wanted in updateSubscription(wanted) }
        .onDisappear { updateSubscription(false) }
    }

    private func updateSubscription(_ wanted: Bool) {
        guard subscribed != wanted else { return }
        subscribed = wanted
        if wanted { engine.subscribeLiveLog() } else { engine.unsubscribeLiveLog() }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": return .red
        case "warning": return .orange
        case "debug": return .secondary
        default: return .primary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
