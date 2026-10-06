import AppKit
import SwiftUI

struct PanelActions {
    var openSettings: (SettingsPage?) -> Void
    /// 打开扩展「代理引擎」的设置窗口（它没有自己的菜单栏图标）。
    var openEngineSettings: () -> Void
    var close: () -> Void
    var quit: () -> Void
    /// 面板内容高度变了，窗口要跟着调整。
    var layoutChanged: () -> Void
    /// SwiftUI 量出来的面板实际尺寸。
    var sizeChanged: (CGSize) -> Void
}

/// 菜单栏面板：状态卡片和大开关、配置列表、快捷操作。
struct PanelView: View {
    @ObservedObject var state: AppState
    let actions: PanelActions
    @State private var testing = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusCard
            if state.status.isOn || !state.targetFailures.isEmpty {
                VStack(spacing: 4) {
                    ForEach(ProxyTarget.allCases) { target in
                        HStack {
                            Text(target.title)
                            Spacer()
                            Text((state.targetStatuses[target] ?? .notApplied).title)
                                .foregroundStyle(state.targetStatuses[target] == .applied ? Color.green : Color.secondary)
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(10)
                .glassCard()
            }
            if case .external = state.status {
                externalCard
            }
            UpdateBanner(updater: state.updater) { actions.openSettings(.about) }
            if !state.config.profiles.isEmpty {
                profileList
            } else {
                emptyCard
            }
            if let error = state.lastError {
                errorCard(error)
            }
            footer
        }
        .padding(12)
        .frame(width: 320)
        .background(GlassPanelBackground())
        .padding(8)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(PanelSizeKey.self) { size in
            actions.sizeChanged(size)
        }
    }

    // MARK: - 状态

    /// 别的程序设置的系统代理也算开着（和菜单栏图标一致）：这时拨开关就是把它关掉。
    private var isOn: Binding<Bool> {
        Binding(get: { state.status.isOn || isExternal }, set: { _ in state.toggle() })
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            StatusBadge(status: state.status, health: state.health)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if state.busy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Toggle(L("开 / 关代理"), isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(state.config.profiles.isEmpty && !state.status.isOn && !isExternal)
            }
        }
        .padding(12)
        .glassCard(prominent: true)
    }

    private var isExternal: Bool {
        if case .external = state.status { return true }
        return false
    }

    private var title: String {
        switch state.status {
        case .on(let profile): return state.isPartiallyApplied ? L("部分开启 · %@", profile.name) : L("已开启 · %@", profile.name)
        case .external: return L("系统代理由其他程序设置")
        case .off(let next): return next == nil ? L("还没有代理配置") : L("代理已关闭")
        }
    }

    private var subtitle: String {
        switch state.status {
        case .on(let profile):
            if state.systemProxyChangedExternally { return L("配置开着，系统代理被别的程序改了") }
            if state.health == .down { return L("代理服务器连不上") }
            if let result = state.testResults[profile.id], result.ok, let latency = result.latencyMs {
                return "\(profile.summary) · \(latency) ms"
            }
            return profile.summary
        case .external(let description):
            return description
        case .off(let next):
            if let next { return L("下次开启 %@ · %@", next.name, next.summary) }
            return L("在设置里添加一个代理配置")
        }
    }

    private var externalCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(L("别的程序改了系统代理，可以保存成配置以后一键切换"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(L("保存")) { state.saveExternalAsProfile() }
                .controlSize(.small)
        }
        .padding(10)
        .glassCard()
    }

    // MARK: - 配置列表

    /// 配置多了以后面板里的列表在这么多行以内滚动，面板不会高过屏幕。
    private static let maxVisibleRows = 8

    private var profileList: some View {
        Group {
            if state.config.profiles.count > Self.maxVisibleRows {
                ScrollView { profileRows }
                    .frame(height: CGFloat(Self.maxVisibleRows) * 43)
            } else {
                profileRows
            }
        }
        .padding(6)
        .glassCard()
    }

    private var profileRows: some View {
        VStack(spacing: 2) {
            ForEach(state.config.profiles) { profile in
                Button {
                    state.use(profile)
                } label: {
                    ProfileRow(profile: profile, active: isActive(profile), result: state.testResults[profile.id])
                }
                .buttonStyle(HoverRowStyle())
            }
        }
    }

    private func isActive(_ profile: Profile) -> Bool {
        if case .on(let current) = state.status { return current.id == profile.id }
        return false
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(L("还没有代理配置"))
                .font(.system(size: 12, weight: .medium))
            Button(L("添加代理配置")) { actions.openSettings(.profiles) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .glassCard()
    }

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                state.lastError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassCard()
    }

    // MARK: - 底部操作

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                testing = true
                Task { @MainActor in
                    await state.testAll()
                    testing = false
                }
            } label: {
                if testing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "speedometer")
                }
            }
            .buttonStyle(IconButtonStyle())
            .help(L("测试全部配置的连接和延迟"))
            .accessibilityLabel(L("测试全部配置的连接和延迟"))
            .disabled(state.config.profiles.isEmpty || testing)

            if case .on(let profile) = state.status, profile.kind != .pac {
                Menu {
                    Button(L("zsh / bash（终端、iTerm）")) { copyCommand(for: profile, fish: false, withPassword: true) }
                    Button("fish") { copyCommand(for: profile, fish: true, withPassword: true) }
                    // 要登录的代理：也可以复制不带密码的（剪贴板里不出现密码，用的时候自己补上）。
                    if profile.needsPassword {
                        Section(L("不带密码")) {
                            Button(L("zsh / bash（终端、iTerm）")) { copyCommand(for: profile, fish: false, withPassword: false) }
                            Button("fish") { copyCommand(for: profile, fish: true, withPassword: false) }
                        }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "terminal")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.05)))
                .help(L("复制在当前终端里使用代理的命令"))
                .accessibilityLabel(L("复制在当前终端里使用代理的命令"))
            }

            Spacer()

            if let hotkey = state.config.toggleHotkey {
                Text(L("%@ 开关", hotkey.display))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if state.persisted.extensionState.enabled {
                Button {
                    actions.openEngineSettings()
                } label: {
                    Image(systemName: "puzzlepiece.extension")
                }
                .buttonStyle(IconButtonStyle())
                .help(L("代理引擎设置"))
                .accessibilityLabel(L("代理引擎设置"))
            }

            Button {
                actions.openSettings(nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help(L("设置"))
            .accessibilityLabel(L("设置"))

            Button {
                actions.quit()
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .help(L("退出 Proxi"))
            .accessibilityLabel(L("退出 Proxi"))
        }
        .padding(.horizontal, 2)
    }

    /// 复制在当前终端里用代理的命令。带着密码时给剪贴板加上「不要记下来」的标记。
    private func copyCommand(for profile: Profile, fish: Bool, withPassword: Bool) {
        let password = withPassword ? state.savedPassword(for: profile) : ""
        let url = profile.proxyURL(password: password)
        let text = fish ? TerminalCommands.fish(proxyURL: url, noProxy: profile.noProxy) : TerminalCommands.export(proxyURL: url, noProxy: profile.noProxy)
        TerminalCommands.copy(text, concealed: !password.isEmpty)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// 状态卡片左侧的圆形图标。
struct StatusBadge: View {
    var status: ProxyStatus
    var health: Health

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
            Circle()
                .strokeBorder(color.opacity(0.5), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: 40, height: 40)
    }

    private var color: Color {
        switch status {
        case .on(let profile): return health == .down ? .red : Color(hex: profile.color)
        case .external: return .orange
        case .off: return .secondary
        }
    }

    private var symbol: String {
        switch status {
        case .on: return health == .down ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
        case .external: return "questionmark.circle.fill"
        case .off: return "power"
        }
    }
}

struct ProfileRow: View {
    var profile: Profile
    var active: Bool
    var result: TestResult?

    var body: some View {
        HStack(spacing: 10) {
            ColorDot(hex: profile.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                Text(profile.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let result {
                Text(result.latencyText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(result.ok ? Color.green : Color.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((result.ok ? Color.green : Color.red).opacity(0.12)))
            }
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color(hex: profile.color) : Color.secondary.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// 面板内容的实际尺寸，窗口按它调整。
struct PanelSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
