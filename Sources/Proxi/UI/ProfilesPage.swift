import SwiftUI

/// 代理配置页：左边是配置列表，右边编辑选中的配置。
struct ProfilesPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var navigation: SettingsNavigation
    @State private var showDetect = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("代理配置"), subtitle: L("每套配置指向一个你自己的代理服务器（公司代理、内网网关、Charles / Proxyman / mitmproxy 这类调试代理），在菜单栏里一键切换"))
            HStack(alignment: .top, spacing: 16) {
                profileList
                    .frame(width: 250)
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showDetect) {
            DetectSheet(state: state) { detected in
                var profile = Profile(name: detected.suggestedName, color: ProfilePalette.color(at: state.config.profiles.count), kind: detected.kind, host: detected.host, port: detected.port)
                profile.name = uniqueName(profile.name)
                state.addProfile(profile)
                navigation.selectedProfileID = profile.id
            }
        }
        .onAppear {
            if navigation.selectedProfileID == nil {
                navigation.selectedProfileID = state.selectedProfile?.id
            }
        }
    }

    /// 配置多了以后列表在这么多行以内滚动，不把「新建」「自动检测」挤出窗口。
    private static let maxVisibleRows = 9

    private var profileList: some View {
        VStack(spacing: 8) {
            Group {
                if state.config.profiles.count > Self.maxVisibleRows {
                    ScrollView { profileRows }
                        .frame(height: CGFloat(Self.maxVisibleRows) * 45)
                } else {
                    profileRows
                }
            }
            .padding(6)
            .glassCard()
            HStack(spacing: 8) {
                Button {
                    var profile = Profile(name: uniqueName(L("新配置")), color: ProfilePalette.color(at: state.config.profiles.count))
                    profile.name = uniqueName(L("新配置"))
                    state.addProfile(profile)
                    navigation.selectedProfileID = profile.id
                } label: {
                    Label(L("新建"), systemImage: "plus")
                }
                Button {
                    showDetect = true
                } label: {
                    Label(L("自动检测"), systemImage: "wand.and.stars")
                }
                .help(L("找出本机正在运行的代理软件"))
            }
            .controlSize(.small)
            Spacer()
        }
    }

    private var profileRows: some View {
        VStack(spacing: 2) {
            if state.config.profiles.isEmpty {
                Text(L("还没有配置"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
            ForEach(state.config.profiles) { profile in
                Button {
                    navigation.selectedProfileID = profile.id
                } label: {
                    HStack(spacing: 10) {
                        ColorDot(hex: profile.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(profile.summary)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if case .on(let current) = state.status, current.id == profile.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(hex: profile.color))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(navigation.selectedProfileID == profile.id ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
                .buttonStyle(HoverRowStyle())
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let id = navigation.selectedProfileID, let profile = state.config.profile(id: id) {
            ProfileEditor(state: state, profile: profile, onDelete: {
                state.remove(profile)
                navigation.selectedProfileID = state.config.profiles.first?.id
            })
            .id(profile.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(state.config.profiles.isEmpty ? L("点「新建」手动填写，或者「自动检测」找出本机的代理软件") : L("在左边选择一个配置"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassCard()
        }
    }

    private func uniqueName(_ base: String) -> String {
        var name = base
        var index = 1
        while state.config.profiles.contains(where: { $0.name == name }) {
            index += 1
            name = "\(base) \(index)"
        }
        return name
    }
}

/// 编辑一套配置。改动先放在草稿里，点「保存」才生效。
struct ProfileEditor: View {
    @ObservedObject var state: AppState
    @AppStorage(AdvancedSettings.key) private var showAdvanced = false
    @State var draft: Profile
    let original: Profile
    let onDelete: () -> Void
    @State private var portText: String
    /// 钥匙串里的密码（编辑时显示在密码框里，保存时写回钥匙串）。打开编辑页时读一次，不在每次重画时读。
    @State private var passwordText = ""
    @State private var originalPassword = ""
    @State private var passwordLoaded = false
    @State private var problem: String?
    @State private var testing = false
    @State private var result: TestResult?
    @State private var saved = false
    @State private var confirmingDelete = false

    init(state: AppState, profile: Profile, onDelete: @escaping () -> Void) {
        self.state = state
        self.original = profile
        self.onDelete = onDelete
        _draft = State(initialValue: profile)
        _portText = State(initialValue: String(profile.port))
    }

    private func loadPassword() {
        guard !passwordLoaded else { return }
        passwordLoaded = true
        let saved = original.hasPassword ? (ProxyKeychain.password(for: original.id) ?? "") : ""
        originalPassword = saved
        passwordText = saved
    }

    private var dirty: Bool { draft != original || passwordText != originalPassword }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L("名称"), text: $draft.name)
                    HStack {
                        Text(L("颜色"))
                        Spacer()
                        ForEach(ProfilePalette.colors, id: \.self) { hex in
                            Button {
                                draft.color = hex
                            } label: {
                                ZStack {
                                    Circle().fill(Color(hex: hex)).frame(width: 18, height: 18)
                                    if draft.color == hex {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Picker(L("类型"), selection: $draft.kind) {
                        ForEach(ProxyKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(draft.engine)
                    if draft.engine {
                        Text(L("这条配置由扩展「代理引擎」管理：地址是它在本机的端口，跟着它变。在「设置 → 扩展」里关闭扩展时它会一起去掉。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if draft.kind == .pac {
                        TextField(L("PAC 地址"), text: $draft.pacURL, prompt: Text("http://proxy.corp.example/proxy.pac"))
                    } else {
                        TextField(L("主机"), text: $draft.host, prompt: Text("proxy.corp.example"))
                            .onChange(of: draft.host) { old, value in
                                // 一次多出好几个字是粘贴进来的整段地址，马上拆开；一个个字打的等保存、测试时再拆，
                                // 不然打到「127.0.0.1:8」就被拆成端口 8，后面的数字跑到主机里。
                                if value.count - old.count > 1 {
                                    splitPastedAddress(value)
                                }
                            }
                        TextField(L("端口"), text: $portText, prompt: Text("8080"))
                            .onChange(of: portText) { _, value in
                                let digits = value.filter(\.isNumber)
                                if digits != value {
                                    portText = digits
                                }
                                draft.port = Int(digits) ?? 0
                            }
                    }
                } header: {
                    Text(draft.kind == .pac ? L("PAC 脚本") : L("代理服务器"))
                } footer: {
                    if draft.kind != .pac {
                        Text(L("可以直接把 proxy.corp.example:3128、127.0.0.1:8888 或 socks5://127.0.0.1:1080 这样的整段地址粘到「主机」里，会自动拆开。常见的本机调试代理：Charles 是 8888，Proxyman 是 9090，mitmproxy 是 8080。"))
                    }
                }
                .disabled(draft.engine)
                if draft.kind != .pac && !draft.engine {
                    Section {
                        TextField(L("用户名"), text: $draft.username, prompt: Text(L("不需要登录就留空")))
                        SecureField(L("密码"), text: $passwordText)
                    } header: {
                        Text(L("登录（可选）"))
                    } footer: {
                        Text(L("代理服务器要求登录时填写。密码只保存在这台 Mac 的钥匙串里，不写进配置文件、不跟 iCloud 同步，别的 Mac 第一次开启这个配置时会请你输入一次。开启时密码会写进系统代理设置，以及环境变量、git 和 npm 用的代理地址。"))
                    }
                }
                Section(L("生效范围")) {
                    ForEach(ProxyTarget.allCases) { target in
                        Toggle(isOn: Binding(
                            get: { draft.targets.contains(target) },
                            set: { enabled in
                                if enabled { draft.targets.insert(target) } else { draft.targets.remove(target) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(target.title)
                                Text(target.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(target != .system && !draft.supportsNonSystemTargets)
                    }
                    if !draft.supportsNonSystemTargets {
                        Text(L("PAC 脚本只能用于系统代理"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // 高级设置收起时，改过的（不是默认值）照样显示，免得看不到它在起作用。
                if showAdvanced || draft.bypass != Profile.defaultBypass || draft.noProxy != Profile.defaultNoProxy {
                    Section(L("不经代理的地址")) {
                        TextField(L("系统代理的例外（逗号分隔）"), text: $draft.bypass, axis: .vertical)
                            .lineLimit(2...4)
                        if draft.supportsNonSystemTargets {
                            TextField(L("NO_PROXY（环境变量和 npm）"), text: $draft.noProxy)
                        }
                    }
                }
                if let result {
                    Section(L("测试结果")) {
                        Label(result.ok ? L("%@，%@", result.latencyText, result.message) : result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.ok ? Color.green : Color.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onSubmit { save() }
            .onAppear(perform: loadPassword)
            // 别处改了这条配置（iCloud 同步、代理引擎换了端口）、这里又没有没保存的改动时跟着更新，免得保存时把旧的写回去。
            .onChange(of: original) { old, new in
                if draft == old {
                    draft = new
                    portText = String(new.port)
                }
            }

            Divider()
                .padding(.horizontal, 20)

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label(L("删除"), systemImage: "trash")
                }
                .disabled(draft.engine)
                .confirmationDialog(L("删除「%@」？", original.name), isPresented: $confirmingDelete) {
                    Button(L("删除"), role: .destructive) { onDelete() }
                } message: {
                    Text(L("配置和它在钥匙串里的密码都会删掉；开着 iCloud 同步时别的 Mac 上也会删掉。"))
                }
                Button {
                    test()
                } label: {
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L("测试连接"), systemImage: "speedometer")
                    }
                }
                .accessibilityLabel(Text(L("测试连接")))
                .disabled(testing)
                Spacer()
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if saved {
                    Label(L("已保存"), systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(L("保存")) { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .glassCard()
    }

    /// 粘贴了带类型、端口或者用户名密码的整段地址时拆到各个字段。
    private func splitPastedAddress(_ text: String) {
        guard let address = ProxyAddress.parse(text), address.splitsFields else { return }
        if let kind = address.kind {
            draft.kind = kind
        }
        if let port = address.port {
            draft.port = port
            portText = String(port)
        }
        if !address.username.isEmpty {
            draft.username = address.username
            if let password = address.password {
                passwordText = password
            }
        }
        draft.host = address.host
    }

    private func save() {
        if draft.kind != .pac {
            splitPastedAddress(draft.host)
        }
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        draft.host = draft.host.trimmingCharacters(in: .whitespaces)
        draft.username = draft.username.trimmingCharacters(in: .whitespaces)
        draft.pacURL = draft.pacURL.trimmingCharacters(in: .whitespaces)
        if draft.kind == .pac {
            draft.targets = [.system]
        }
        if let error = draft.validate() {
            problem = error
            return
        }
        if state.config.profiles.contains(where: { $0.id != draft.id && $0.name == draft.name }) {
            problem = L("已经有叫「%@」的配置了", draft.name)
            return
        }
        problem = nil
        let passwordChanged = passwordText != originalPassword
        let user = draft.username.trimmingCharacters(in: .whitespaces)
        if draft.kind == .pac || user.isEmpty {
            ProxyKeychain.delete(for: draft.id)
            draft.hasPassword = false
        } else if passwordText.isEmpty {
            // 密码框空着：原来有密码、被用户清空了才删。这台 Mac 的钥匙串里本来就没有（配置是从别的 Mac 同步来的）时
            // 保留「有密码」的标记，开启时再问，不然这个标记同步回去，别的 Mac 开启时也不带密码了。
            if !originalPassword.isEmpty {
                ProxyKeychain.delete(for: draft.id)
                draft.hasPassword = false
            }
        } else if passwordText != originalPassword || !draft.hasPassword {
            do {
                try ProxyKeychain.set(passwordText, for: draft.id)
                draft.hasPassword = true
            } catch {
                problem = error.localizedDescription
                return
            }
        }
        state.update(draft, passwordChanged: passwordChanged)
        originalPassword = draft.hasPassword ? passwordText : ""
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }

    private func test() {
        if draft.kind != .pac {
            splitPastedAddress(draft.host)
        }
        if let error = draft.validate() {
            problem = error
            return
        }
        problem = nil
        testing = true
        let profile = draft
        let password = passwordText
        let testURL = state.config.testURL
        Task { @MainActor in
            result = await ProxyTester.test(profile: profile, password: password, testURL: testURL)
            testing = false
        }
    }
}

/// 自动检测本机代理软件。
struct DetectSheet: View {
    @ObservedObject var state: AppState
    let onAdd: (DetectedProxy) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detecting = true
    @State private var found: [DetectedProxy] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("自动检测本机代理"))
                .font(.system(size: 16, weight: .semibold))
            Text(L("检查本机监听的端口，找出能当代理用的，并测出延迟。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Group {
                if detecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("正在检测…"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else if found.isEmpty {
                    Text(L("没有找到正在运行的代理软件。请先启动代理软件，或者手动填写地址。"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    VStack(spacing: 4) {
                        ForEach(found) { item in
                            HStack {
                                Image(systemName: item.kind == .socks5 ? "point.3.filled.connected.trianglepath.dotted" : "globe")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.suggestedName)
                                        .font(.system(size: 12, weight: .medium))
                                    Text("\(item.kind.title) · \(item.host):\(item.port)" + (item.latencyMs.map { " · \($0) ms" } ?? ""))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(L("添加")) {
                                    onAdd(item)
                                    dismiss()
                                }
                                .controlSize(.small)
                            }
                            .padding(8)
                        }
                    }
                    .glassCard()
                }
            }
            HStack {
                Button(L("重新检测")) { detect() }
                    .disabled(detecting)
                Spacer()
                Button(L("关闭‖按钮")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { detect() }
    }

    private func detect() {
        detecting = true
        let testURL = state.config.testURL
        Task { @MainActor in
            found = await LocalProxyDetector.detect(testURL: testURL)
            detecting = false
        }
    }
}
