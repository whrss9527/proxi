import AppKit
import Combine

/// 当前代理状态：关着（下次会开哪个配置）、由本程序开着某个配置、系统代理被别的程序设置了。
enum ProxyStatus: Equatable {
    case off(next: Profile?)
    case on(Profile)
    case external(String)

    var isOn: Bool {
        if case .on = self { return true }
        return false
    }

    var profile: Profile? {
        switch self {
        case .on(let profile): return profile
        case .off(let next): return next
        case .external: return nil
        }
    }
}

enum Health: Equatable {
    case unknown
    case ok
    case down
}

/// 代理引擎的核心状态：配置、内核、局域网共享、增强模式，所有界面都观察它。只在主线程上使用。
/// 系统代理、终端、git 和 npm 由 Proxi 设置（它的配置列表里有一条「代理引擎」指向这里的端口），
/// 这里只读系统代理的现状，用来判断本机是不是在用代理引擎（局域网共享和增强模式跟着它走）。
/// profiles、turnOn 这些是从 Proxi 以前的版本带过来的：配置里的代理配置还要用来当前置代理。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var config: AppConfig
    @Published private(set) var persisted: PersistedState
    @Published private(set) var snapshot: ProxySnapshot = SystemProxy.current()
    @Published private(set) var health: Health = .unknown
    @Published private(set) var busy = false
    @Published var lastError: String?
    @Published var testResults: [UUID: TestResult] = [:]
    @Published var loginItemEnabled = false
    /// 这台 Mac 在局域网里的地址，主网卡在前；PS5 等设备填代理服务器时用。
    @Published private(set) var lanAddresses: [LocalNetwork.Address] = []
    let engine = Engine()
    /// 内核和 GeoIP 数据库的下载（第一次运行时下载，校验 SHA-256）。
    let core = CoreDownload()
    /// 写给 Proxi 看的状态文件（端口、在不在运行）。
    let statusFile = EngineStatusPublisher()
    let speed = SpeedMeter()
    let sleepGuard = SleepGuard()
    /// 本机控制接口（命令行、AI 助手）。
    let control = ControlService()
    /// 特权助手（增强模式、网关模式要用）。
    let helper = HelperManager()
    /// 更新后正在重新启动：退出时不要按「退出时关闭代理」清理。
    var relaunching = false

    private var watcher: SystemWatcher?
    private var refreshTimer: Timer?
    private var healthTimer: Timer?
    private var healthFailures = 0
    private var cancellables = Set<AnyCancellable>()

    private init() {
        config = Store.loadConfig() ?? AppConfig()
        persisted = Store.loadState()
        $config
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { config in Store.save(config) }
            .store(in: &cancellables)
    }

    /// 启动时调用：开始监听系统代理的变化，启动内核。
    func start() {
        watcher = SystemWatcher { [weak self] in self?.refresh() }
        watcher?.start()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer?.tolerance = 2
        refresh()
        engine.readConfig = { [weak self] in self?.config ?? AppConfig() }
        engine.writeEngine = { [weak self] engine in self?.config.engine = engine }
        engine.coreReady = { [weak self] in self?.core.isReady ?? false }
        // 按出口累计的流量存在本机状态里，跨重启接着算。
        engine.loadTraffic(persisted.traffic)
        engine.persistTraffic = { [weak self] stats in
            guard let self else { return }
            self.persisted.traffic = stats
            Store.save(self.persisted)
        }
        $config
            .map { EngineInputs(engine: $0.engine, testURL: $0.testURL, profiles: $0.profiles) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.engineConfigChanged() } }
            .store(in: &cancellables)
        ensureEngineProfile()
        sleepGuard.start()
        helper.wanted = { [weak self] in
            guard let tun = self?.persisted.tun else { return false }
            return tun.enabled || tun.gateway
        }
        helper.start()
        shareStateChanged()
        engine.start()
        // 本机的代理状态、共享设置、配置任何一个变了，都重新算一遍共享和网关的上游，内核跟着热加载。
        Publishers.CombineLatest3($snapshot, $persisted, $config)
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.shareStateChanged() } }
            .store(in: &cancellables)
        // 特权助手装好或者停了、这台 Mac 换了局域网地址：重新算虚拟网卡的参数。
        helper.$state
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] state in
                Task { @MainActor in
                    // 助手重新装好、起来了：上次增强模式没开起来（比如重装助手时它正好停着）就再试一次。
                    if case .ready = state {
                        self?.engine.retryTunIfFailed()
                    }
                    self?.shareStateChanged()
                }
            }
            .store(in: &cancellables)
        $lanAddresses
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.shareStateChanged() } }
            .store(in: &cancellables)
        engine.$tunStatus
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in
                Task { @MainActor in
                    if case .failed(let message) = status {
                        self?.notify(title: L("增强模式没有开起来"), body: message, problem: true)
                    }
                }
            }
            .store(in: &cancellables)
        engine.$shareStatus
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in
                Task { @MainActor in
                    if case .failed(let message) = status {
                        self?.notify(title: L("局域网共享出错"), body: message, problem: true)
                    }
                }
            }
            .store(in: &cancellables)
        control.start(state: self)
        statusFile.start(state: self)
        // 第一次运行（或者内核被删了、校验不对）时下载内核，下好了内核接着启动。
        core.onInstalled = { [weak self] in
            guard let self else { return }
            Task { await self.engine.restartCore() }
            self.statusFile.publish()
        }
        Task { await core.prepare() }
    }

    /// 代理引擎相关的设置变了：配置列表里对应的条目跟着变，内核重新加载。
    private func engineConfigChanged() {
        ensureEngineProfile()
        if let index = config.profiles.firstIndex(where: { $0.engine }), config.profiles[index].port != config.engine.mixedPort {
            config.profiles[index].port = config.engine.mixedPort
        }
        engine.scheduleReconcile()
    }

    /// 代理引擎在配置列表里的那一条；有订阅时自动加上。
    var engineProfile: Profile? { config.profiles.first { $0.engine } }

    @discardableResult
    func ensureEngineProfile() -> Profile? {
        if let existing = engineProfile { return existing }
        guard config.engine.wantsCore else { return nil }
        let profile = Profile.engineProfile(port: config.engine.mixedPort)
        config.profiles.insert(profile, at: 0)
        if config.profiles.count == 1 {
            persisted.lastProfileID = profile.id
            Store.save(persisted)
        }
        return profile
    }

    /// 让代理引擎成为下次开启的配置（选了节点时用）。
    func selectEngineProfile() {
        guard let profile = ensureEngineProfile() else { return }
        persisted.lastProfileID = profile.id
        Store.save(persisted)
    }

    // MARK: - 状态

    var status: ProxyStatus {
        if snapshot.isActive {
            if let profile = matchingProfile() {
                return .on(profile)
            }
            return .external(snapshot.summary)
        }
        let next = selectedProfile
        if let next, persisted.enabledByUs, !next.targets.contains(.system) {
            // 不含系统代理的配置（只设环境变量、git、npm）无法从系统代理判断，按记录的状态算。
            return .on(next)
        }
        return .off(next: next)
    }

    /// 最近使用的配置，没有记录时是第一个。
    var selectedProfile: Profile? {
        config.profile(id: persisted.lastProfileID) ?? config.profiles.first
    }

    private func matchingProfile() -> Profile? {
        if let selected = selectedProfile, snapshot.matches(selected) {
            return selected
        }
        return config.profiles.first { snapshot.matches($0) }
    }

    func refresh() {
        let current = SystemProxy.current()
        if current != snapshot { snapshot = current }
        let addresses = LocalNetwork.addresses()
        if addresses != lanAddresses {
            lanAddresses = addresses
        }
    }

    // MARK: - 局域网共享

    /// 局域网共享的设置（本机的，不同步）。
    var share: ShareConfig { persisted.share }

    /// 主网卡的地址，设备上填它。
    var lanAddress: LocalNetwork.Address? { lanAddresses.first }

    /// 共享出去的流量往哪走：跟着本机现在的代理状态。
    var shareUpstream: ShareUpstream { ShareUpstream(status: status, snapshot: snapshot) }

    /// 交给内核的共享参数；没开时是 nil。
    var shareInputs: ShareInputs? {
        guard share.enabled else { return nil }
        return ShareInputs(port: share.port, allowedPrefixes: share.allowedPrefixes, upstream: shareUpstream)
    }

    func setShare(_ share: ShareConfig) {
        guard share != persisted.share else { return }
        persisted.share = share
        Store.save(persisted)
        Log.info(share.enabled ? "局域网共享：开启，端口 \(share.port)" : "局域网共享：关闭")
        shareStateChanged()
    }

    func setShareEnabled(_ enabled: Bool) {
        var updated = share
        updated.enabled = enabled
        setShare(updated)
    }

    private func shareStateChanged() {
        engine.setShare(shareInputs)
        engine.setTun(tunInputs)
        // 局域网设备靠这台 Mac 上网时（共享或者网关）不让它睡着。
        sleepGuard.update(wanted: (share.enabled || persisted.tun.gateway) && share.keepAwake, allowOnBattery: share.keepAwakeOnBattery)
    }

    // MARK: - 增强模式和网关模式

    /// 增强模式和网关模式的设置（本机的，不同步）。
    var tun: TunConfig { persisted.tun }

    /// 交给内核的虚拟网卡参数：特权助手能用，而且开了网关模式、或者开了增强模式又正在用代理引擎时才有。
    var tunInputs: TunInputs? {
        let tun = persisted.tun
        guard tun.enabled || tun.gateway, helper.isReady else { return nil }
        let upstream = shareUpstream
        let captureLocal = tun.enabled && upstream == .engine
        guard captureLocal || tun.gateway else { return nil }
        return TunInputs(stack: tun.stack, dnsMode: tun.dnsMode, captureLocal: captureLocal, gateway: tun.gateway, upstream: upstream, localAddresses: lanAddresses.map(\.ip))
    }

    func setTun(_ tun: TunConfig) {
        guard tun != persisted.tun else { return }
        let before = persisted.tun
        persisted.tun = tun
        Store.save(persisted)
        if tun.enabled != before.enabled {
            Log.info(tun.enabled ? "增强模式：开启" : "增强模式：关闭")
        }
        if tun.gateway != before.gateway {
            Log.info(tun.gateway ? "网关模式：开启" : "网关模式：关闭")
        }
        shareStateChanged()
        if tun.enabled || tun.gateway {
            Task { await helper.refresh() }
        }
    }

    func setTunEnabled(_ enabled: Bool) {
        var updated = tun
        updated.enabled = enabled
        setTun(updated)
    }

    func setGatewayEnabled(_ enabled: Bool) {
        var updated = tun
        updated.gateway = enabled
        setTun(updated)
    }

    /// 增强模式现在的情况，给界面和接口用的一句话。
    var tunSummary: String {
        let tun = persisted.tun
        guard tun.enabled || tun.gateway else { return L("没开") }
        guard helper.isReady else { return helper.summary }
        switch engine.tunStatus {
        case .on(let forwarding):
            if tun.gateway && !forwarding { return L("虚拟网卡开着，IP 转发还没打开") }
            if tunInputs?.captureLocal == false && tun.enabled { return L("本机没在用代理引擎，只为网关模式开着虚拟网卡") }
            return tun.gateway ? (tun.enabled ? L("增强模式和网关模式都开着") : L("网关模式开着")) : L("增强模式开着")
        case .starting: return L("正在开启…")
        case .failed(let message): return message
        case .off:
            if tun.enabled && !tun.gateway && shareUpstream != .engine { return L("本机开着代理引擎时才生效") }
            return L("没开")
        }
    }

    // MARK: - 开关

    func toggle() {
        switch status {
        case .on, .external:
            turnOff()
        case .off(let next):
            if let next {
                turnOn(next)
            } else {
                lastError = L("还没有代理配置，请先在设置里添加一个")
            }
        }
    }

    func turnOn(_ profile: Profile) {
        guard !busy else { return }
        busy = true
        let previous: Profile? = {
            if case .on(let current) = status { return current }
            return persisted.enabledByUs ? selectedProfile : nil
        }()
        if !status.isOn || persisted.original == nil {
            persisted.original = snapshot
        }
        let mode = config.offMode
        Task {
            var failures: [String] = []
            if profile.engine {
                do {
                    try await engine.ensureRunning()
                } catch {
                    finish(action: L("开启 %@", profile.name), failures: [L("内核：%@", error.localizedDescription)], successText: "")
                    return
                }
            }
            // 上一个配置设置过、新配置没有的项先清掉。
            if let previous {
                for target in previous.targets where !profile.targets.contains(target) {
                    if let error = await clear(target: target, mode: mode) {
                        failures.append(L("%@（清除）：%@", target.title, error))
                    }
                }
            }
            for target in ProxyTarget.allCases where profile.targets.contains(target) {
                if let error = await set(target: target, profile: profile) {
                    failures.append(L("%@：%@", target.title, error))
                }
            }
            persisted.lastProfileID = profile.id
            persisted.enabledByUs = failures.count < profile.targets.count
            Store.save(persisted)
            finish(action: L("开启 %@", profile.name), failures: failures, successText: profile.summary)
        }
    }

    func turnOff() {
        guard !busy else { return }
        busy = true
        let current = status
        let mode = config.offMode
        Task {
            var failures: [String] = []
            switch current {
            case .external:
                if let error = await clear(target: .system, mode: .direct) {
                    failures.append(L("系统代理：%@", error))
                }
            case .on(let profile):
                for target in ProxyTarget.allCases where profile.targets.contains(target) {
                    if let error = await clear(target: target, mode: mode) {
                        failures.append(L("%@：%@", target.title, error))
                    }
                }
            case .off:
                break
            }
            persisted.enabledByUs = false
            persisted.original = nil
            Store.save(persisted)
            finish(action: L("关闭代理"), failures: failures, successText: mode == .restore ? L("已恢复开启前的设置") : L("已改为直接连接"))
        }
    }

    func use(_ profile: Profile) {
        if case .on(let current) = status, current.id == profile.id {
            turnOff()
        } else {
            turnOn(profile)
        }
    }

    func use(named name: String) -> Bool {
        guard let profile = config.profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        turnOn(profile)
        return true
    }

    private func finish(action: String, failures: [String], successText: String) {
        busy = false
        healthFailures = 0
        refresh()
        if failures.isEmpty {
            Log.info("\(action) 成功")
            lastError = nil
            notify(title: action, body: successText, problem: false)
        } else {
            let text = failures.joined(separator: L("；"))
            Log.error("\(action) 失败：\(text)")
            lastError = text
            notify(title: L("%@时出错", action), body: text, problem: true)
        }
        Task { await checkHealth() }
    }

    private func set(target: ProxyTarget, profile: Profile) async -> String? {
        do {
            switch target {
            case .system:
                try await SystemProxy.apply(DesiredProxy(profile: profile))
            case .environment:
                try await EnvironmentProxy.set(proxyURL: profile.proxyURL, noProxy: profile.noProxy)
            case .git:
                try await GitProxy.set(proxyURL: profile.proxyURL)
            case .npm:
                try NpmProxy.set(proxyURL: profile.proxyURL, noProxy: profile.noProxy)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func clear(target: ProxyTarget, mode: OffMode) async -> String? {
        do {
            switch target {
            case .system:
                let current = SystemProxy.current()
                if mode == .restore, let original = persisted.original {
                    try await SystemProxy.apply(DesiredProxy(restoring: original))
                } else {
                    let autoDiscovery = persisted.original?.autoDiscovery ?? current.autoDiscovery
                    try await SystemProxy.apply(DesiredProxy(offWithAutoDiscovery: autoDiscovery, bypassDomains: current.exceptions))
                }
            case .environment:
                try await EnvironmentProxy.clear()
            case .git:
                try await GitProxy.clear()
            case .npm:
                try NpmProxy.clear()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - 配置

    func addProfile(_ profile: Profile) {
        config.profiles.append(profile)
        if config.profiles.count == 1 {
            persisted.lastProfileID = profile.id
            Store.save(persisted)
        }
    }

    func update(_ profile: Profile) {
        guard let index = config.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let previous = config.profiles[index]
        config.profiles[index] = profile
        // 正在使用的配置改了地址：立即重新应用。
        if case .on(let current) = status, current.id == profile.id, previous != profile {
            turnOn(profile)
        }
    }

    func remove(_ profile: Profile) {
        if case .on(let current) = status, current.id == profile.id {
            turnOff()
        }
        config.profiles.removeAll { $0.id == profile.id }
        if persisted.lastProfileID == profile.id {
            persisted.lastProfileID = config.profiles.first?.id
            Store.save(persisted)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        config.profiles.move(fromOffsets: source, toOffset: destination)
    }

    /// 来自 iCloud 的配置：整个换掉。正在使用的配置如果改了地址就重新应用，被删了就关闭代理。
    private func applyRemoteConfig(_ remote: AppConfig) {
        let active: Profile? = {
            if case .on(let profile) = status { return profile }
            return nil
        }()
        config = remote
        guard let active else { return }
        if let updated = remote.profile(id: active.id) {
            if updated != active {
                turnOn(updated)
            }
        } else {
            turnOff()
        }
    }

    /// 把别的程序设置的系统代理保存成配置。
    func saveExternalAsProfile() {
        guard var profile = snapshot.asProfile(name: L("系统代理")) else { return }
        var index = 1
        while config.profiles.contains(where: { $0.name == profile.name }) {
            index += 1
            profile.name = L("系统代理 %@", index)
        }
        profile.color = ProfilePalette.color(at: config.profiles.count)
        addProfile(profile)
        persisted.lastProfileID = profile.id
        Store.save(persisted)
        refresh()
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled: enabled)
            loginItemEnabled = LoginItem.isEnabled
        } catch {
            lastError = L("设置登录时启动失败：%@", error.localizedDescription)
            loginItemEnabled = LoginItem.isEnabled
        }
    }

    // MARK: - 测速与健康

    func test(_ profile: Profile) async {
        let result = await ProxyTester.test(profile: profile, testURL: config.testURL)
        testResults[profile.id] = result
    }

    func testAll() async {
        await withTaskGroup(of: Void.self) { group in
            for profile in config.profiles {
                group.addTask { await self.test(profile) }
            }
        }
    }

    func checkHealth() async {
        guard config.healthCheck, case .on(let profile) = status, profile.kind != .pac else {
            health = .unknown
            healthFailures = 0
            return
        }
        let reachable = await ProxyTester.reachable(host: profile.host, port: profile.port)
        if reachable {
            if health == .down {
                notify(title: L("代理服务器恢复了"), body: profile.summary, problem: false)
            }
            health = .ok
            healthFailures = 0
        } else {
            healthFailures += 1
            // 连续两次连不上才算故障，避免偶发抖动。
            if healthFailures >= 2 && health != .down {
                health = .down
                notify(title: L("连不上代理服务器"), body: L("%@（%@）没有响应，浏览器可能无法上网", profile.name, profile.summary), problem: true)
            }
        }
    }

    // MARK: - 通知与退出

    func notify(title: String, body: String, problem: Bool, route: String? = nil, category: String? = nil) {
        switch config.notifyLevel {
        case .none: return
        case .problems where !problem: return
        default: break
        }
        Notifier.shared.show(title: title, body: body, route: route, category: category)
    }

    // MARK: - 导入导出

    /// 导入的文件（Clash 配置里的节点、转换后的规则）放在这里。
    static var importsDirectory: URL { Store.directory.appendingPathComponent("imports", isDirectory: true) }

    /// 从文字或网址做导入计划，不改动任何设置。文字本身是一个网址时按网址处理；
    /// 网址的内容认不出来时当作订阅（交给内核解析）。
    func prepareImport(text: String?, url: String?, sourceName: String) async throws -> ImportPlan {
        var address = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if !text.contains(where: \.isNewline), let parsed = URL(string: text), let scheme = parsed.scheme?.lowercased(), (["http", "https", "file"] + URLCommand.schemes).contains(scheme) {
                address = text
            } else {
                return try ConfigImporter.plan(text, sourceName: sourceName, existing: config)
            }
        }
        guard var address, !address.isEmpty else { throw ImportError.empty }
        // proxi://import?url=… 里面的地址。
        if let scheme = URL(string: address)?.scheme?.lowercased(), URLCommand.schemes.contains(scheme),
           let inner = URLComponents(string: address)?.queryItems?.first(where: { $0.name == "url" })?.value {
            address = inner
        }
        guard let parsed = URL(string: address), let scheme = parsed.scheme?.lowercased() else { throw ImportError.invalid(L("认不出网址：%@", address)) }
        if scheme == "file" {
            let text = try String(contentsOf: parsed, encoding: .utf8)
            return try ConfigImporter.plan(text, sourceName: parsed.deletingPathExtension().lastPathComponent, existing: config)
        }
        guard ["http", "https"].contains(scheme), parsed.host != nil else { throw ImportError.invalid(L("网址要以 http:// 或 https:// 开头")) }
        let corePort = engine.isRunning && config.engine.wantsCore ? config.engine.mixedPort : nil
        let data = try await RuleStore.download(address, routes: NetworkRoute.routes(for: parsed, corePort: corePort, system: SystemProxy.current()))
        let text = String(decoding: data, as: UTF8.self)
        let name = parsed.host ?? sourceName
        if ConfigImporter.detect(text) == nil {
            var plan = ImportPlan(format: .links, sourceName: name)
            plan.subscriptions = [Subscription(name: name, url: address)]
            plan.warnings.append(L("认不出内容的格式，当作订阅添加，交给内核解析"))
            return plan
        }
        return try ConfigImporter.plan(text, sourceName: name, sourceURL: address, existing: config)
    }

    /// 应用导入：写文件、改设置，返回一句话。
    @discardableResult
    func applyImport(_ plan: ImportPlan, mode: ImportMode) throws -> String {
        let result = ConfigImporter.apply(plan, to: config, mode: mode, directory: Self.importsDirectory)
        for file in result.files {
            try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: file.url, atomically: true, encoding: .utf8)
        }
        config = result.config
        ensureEngineProfile()
        if !plan.subscriptions.isEmpty || plan.nodeFile != nil || !plan.manualNodes.isEmpty {
            selectEngineProfile()
        }
        Log.info("导入「\(plan.sourceName)」（\(plan.format.title)，\(mode.title)）：\(result.summary)")
        return result.summary
    }

    /// 退出时停掉内核。系统代理、终端、git 和 npm 是 Proxi 设置的，这里不动。
    func handleExit() async {
        control.stop()
        sleepGuard.release()
        statusFile.remove()
        await engine.shutdown()
    }
}

/// 会影响内核配置的那部分设置，变了才重新生成（前置代理可以用配置列表里的代理，所以配置列表也算）。
private struct EngineInputs: Equatable {
    var engine: EngineConfig
    var testURL: String
    var profiles: [Profile]
}
