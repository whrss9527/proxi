import AppKit
import Combine

/// 代理引擎：管内核进程、节点列表、策略组、模式、订阅和规则集，以及给局域网设备用的共享入口；
/// 内核在跑时还盯着连接列表、按出口累计流量、查出口 IP。只在主线程上用。
@MainActor
final class Engine: ObservableObject {
    enum Status: Equatable {
        /// 没启用，或者既没有订阅也没开局域网共享。
        case off
        case starting
        /// 内核在跑，附带版本号。
        case running(String)
        case failed(String)
    }

    /// 节点（定义在 ProxyNode.swift，筛选和排序也在那里）。
    typealias Node = ProxyNode

    struct SubscriptionStatus: Equatable {
        var nodeCount: Int
        var info: CoreSubscriptionInfo?
        var updatedAt: Date?
    }

    /// 一个自定义策略组在内核里的状态。
    struct GroupState: Identifiable, Equatable {
        var name: String
        var kind: PolicyGroupKind
        /// 现在用的成员。
        var now: String?
        /// 全部候选：手动选择的组是「节点」「自动选择」「DIRECT」加筛出来的节点，自动类的组只有筛出来的节点。
        var members: [String]

        var id: String { name }
    }

    /// 一个规则集的状态：多少条、什么时候更新的、有没有问题。
    struct RuleSetStatus: Equatable {
        var count: Int?
        var updatedAt: Date?
        var problem: String?
    }

    /// 局域网共享入口的状态。
    enum ShareStatus: Equatable {
        case off
        case starting
        /// 正在监听这个端口。
        case listening(Int)
        case failed(String)
    }

    /// 增强模式 / 网关模式（虚拟网卡）的状态。
    enum TunStatus: Equatable {
        case off
        case starting
        /// 虚拟网卡开着；forwarding 表示网关模式要的 IP 转发也开了。
        case on(forwarding: Bool)
        case failed(String)
    }

    static let selectorGroup = CoreConfigBuilder.selectorGroup
    static let autoGroup = CoreConfigBuilder.autoGroup
    /// 「最近的连接」最多留这么多条。
    static let historyLimit = 200

    @Published private(set) var status: Status = .off
    @Published private(set) var shareStatus: ShareStatus = .off
    /// 局域网共享的参数，AppState 按本机的代理状态算出来；nil 表示没开。
    private(set) var shareInputs: ShareInputs?
    @Published private(set) var tunStatus: TunStatus = .off
    /// 虚拟网卡的参数，AppState 按设置、特权助手和本机的代理状态算出来；nil 表示不开。
    private(set) var tunInputs: TunInputs?
    @Published private(set) var nodes: [Node] = []
    /// 「节点」组当前选中的：某个节点、自动选择或 DIRECT。
    @Published private(set) var currentSelection: String?
    /// 自动选择现在用的节点。
    @Published private(set) var autoNode: String?
    /// 自定义策略组现在的状态，按配置里的顺序。
    @Published private(set) var groupStates: [GroupState] = []
    @Published private(set) var subscriptionStatus: [UUID: SubscriptionStatus] = [:]
    @Published private(set) var ruleSetStatus: [UUID: RuleSetStatus] = [:]
    @Published private(set) var testing = false
    @Published private(set) var updatingSubscription: UUID?
    /// 正在下载的规则集（手动更新和后台补下载都算）。
    @Published private(set) var downloadingRuleSets: Set<UUID> = []
    @Published private(set) var rulesInfo = ""
    @Published var lastError: String?
    /// 现在开着的连接，内核在跑时每两秒刷新一次。
    @Published private(set) var connections: [CoreConnection] = []
    /// 最近的连接（新的在前），短连接也会记下来。
    @Published private(set) var history: [ConnectionRecord] = []
    /// 内核这次运行以来的总流量。
    @Published private(set) var sessionTraffic = TrafficTotal()
    /// 按出口累计的流量，内核重启后接着算，存在本机状态里。
    @Published private(set) var traffic = TrafficStats()
    /// 经节点出去的出口 IP；nil 表示还没查到。
    @Published private(set) var exitInfo: ExitInfo?
    @Published private(set) var exitProblem: String?
    @Published private(set) var checkingExit = false
    /// 本机直连的出口 IP，连接页里点了才查。
    @Published private(set) var directExit: ExitInfo?
    @Published private(set) var directExitProblem: String?
    @Published private(set) var checkingDirectExit = false
    /// 配置补丁的问题（写错了时用的是没打补丁的配置）；nil 表示没问题或没有补丁。
    @Published private(set) var patchProblem: String?
    /// 配置补丁合并时的提示（比如写了由 Proxi 管理的键）。
    @Published private(set) var patchNotes: [String] = []
    /// 手动节点里内核认出来的个数；nil 表示还不知道。
    @Published private(set) var manualNodeCount: Int?
    /// 最近两分钟经内核的网速（每两秒一个点），连接页的图表用。
    @Published private(set) var speedHistory: [SpeedSample] = []
    /// 服务检测的结果，按节点名（当前节点是空字符串）。
    @Published private(set) var serviceResults: [String: [ServiceCheckResult]] = [:]
    /// 正在检测服务的节点；nil 表示没在测。
    @Published private(set) var checkingServices: String?
    /// 实时日志（高级页打开时才订阅），最新的在最后。
    @Published private(set) var liveLog: [LogLine] = []

    var readConfig: () -> AppConfig = { AppConfig() }
    var writeEngine: ((EngineConfig) -> Void)?
    /// 内核下载好、按写死的 SHA-256 校验过了（AppState 按 CoreDownload 提供）。没好之前不启动内核。
    var coreReady: () -> Bool = { true }
    /// 流量统计变了（隔一会儿存一次），交给 AppState 写到本机状态里。
    var persistTraffic: ((TrafficStats) -> Void)?

    private let runner = CoreRunner()
    /// 开虚拟网卡时内核要以 root 运行，经特权助手启动。
    private let helperRunner = HelperCoreRunner()
    /// 现在这个内核是经特权助手运行的。
    private var runningViaHelper = false
    /// 经特权助手开虚拟网卡失败时的参数：参数不变就先不开，免得反复重试；代理照常用本机的内核。
    private var tunFailedFor: TunInputs?
    /// 助手那边的 IP 转发开着（网关模式）。
    private var forwardingOn = false
    /// 经助手运行时要复制过去的文件（相对内核目录）。
    private var helperFiles: [String] = []
    private var api: CoreAPI?
    private let secret = CoreConfigBuilder.makeSecret()
    private var lastConfigText: String?
    private var refreshTimer: Timer?
    private var ruleUpdateTimer: Timer?
    private var restartAttempts = 0
    private var reconcileTask: Task<Void, Never>?
    /// 正在执行的 reconcile；后来的排在它后面，同一时间只有一个在动内核。
    private var reconcileChain: Task<Void, Never>?
    private var connectionsTask: Task<Void, Never>?
    private var accumulator = TrafficAccumulator()
    private var trafficDirty = false
    private var lastTrafficSave = Date()
    private var exitTask: Task<Void, Never>?
    /// 上次查出口 IP 时用的节点。
    private var exitNode: String?
    private var exitCache: [String: ExitInfo] = [:]
    /// 小火箭 / Surge 配置转换的结果，按规则集、去向、组名和文件版本缓存。
    private var inlineCache: [String: InlineRules] = [:]
    /// 生成配置时发现还没下载的规则集和完整配置里引用的列表，由后台补下载，下好了再重新加载。
    private var missingRuleSets: Set<UUID> = []
    private var missingReferences: Set<String> = []
    private var backfillTask: Task<Void, Never>?
    /// 上次下载失败的时间：后台补下载隔一会儿再试，不反复打扰。
    private var lastDownloadFailure: [String: Date] = [:]
    static let downloadRetryInterval: TimeInterval = 5 * 60
    /// 服务检测用的本机入口端口：启动时挑一个空闲的，这次运行期间不变。
    let probePort: Int = Engine.pickFreePort()
    /// 上次校验过的补丁内容和结果：补丁没变就不重复跑 mihomo -t。
    private var checkedPatch: (text: String, problem: String?)?
    private var lastSpeedSample: (date: Date, traffic: TrafficTotal)?
    private var logTask: Task<Void, Never>?
    private var logSubscribers = 0
    private var pendingLog: [LogLine] = []
    private var logFlushScheduled = false
    /// 「最近的网速」保留的点数（每两秒一个，共两分钟）。
    static let speedHistoryLimit = 60
    static let liveLogLimit = 500

    private struct InlineRules {
        var rules: [String]
        var final: String?
        var warnings: [String]
    }

    nonisolated static var directory: URL { Store.directory.appendingPathComponent("core", isDirectory: true) }
    var configURL: URL { Self.directory.appendingPathComponent("config.yaml") }
    var engineConfig: EngineConfig { readConfig().engine }
    var coreAvailable: Bool { CoreBinary.executableURL != nil }

    /// 一句话的状态：没运行、正在启动、运行中、出错。
    var statusTitle: String {
        switch status {
        case .off: return engineConfig.enabled ? L("没在运行") : L("已停用")
        case .starting: return L("正在启动…")
        case .running(let version): return L("运行中（%@）", version)
        case .failed(let message): return L("出错：%@", message)
        }
    }

    /// 有订阅，或者开了局域网共享、网关模式，内核才需要运行。
    var wantsCore: Bool { engineConfig.wantsCore || shareInputs != nil || effectiveTun?.gateway == true }

    /// 这次真正要用的虚拟网卡参数：开过但失败了、参数也没变时是 nil。
    private var effectiveTun: TunInputs? {
        guard let tunInputs, tunInputs != tunFailedFor else { return nil }
        return tunInputs
    }

    /// 内核进程（本机的或者助手那边的）在跑。
    private var coreProcessRunning: Bool { runningViaHelper ? helperRunner.isRunning : runner.isRunning }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// 当前实际在用的节点名（自动选择时是它选中的那个）。
    var effectiveNode: String? {
        guard let currentSelection else { return nil }
        if currentSelection == Self.autoGroup { return autoNode }
        return currentSelection
    }

    var logTail: String { runningViaHelper ? helperRunner.logTail : runner.logTail }

    /// 最近经共享入口的连接（PS5 等设备）。
    var shareConnections: [ConnectionRecord] { history.filter(\.isShare) }

    /// 正在经共享入口上网的设备（按来源 IP 归并现在开着的连接）。
    var shareClients: [ShareClient] { ShareClient.group(connections, listener: CoreConfigBuilder.shareListener) }

    /// 内核的实时流量流；没在跑时是 nil。
    func trafficStream() async throws -> URLSession.AsyncBytes? {
        guard let api, isRunning else { return nil }
        return try await api.trafficBytes()
    }

    // MARK: - 生命周期

    func start() {
        runner.onExit = { [weak self] code in self?.coreExited(code) }
        helperRunner.onExit = { [weak self] code in self?.coreExited(code) }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // 规则集到期了就重新下载（间隔和订阅一样，默认 24 小时）。
        ruleUpdateTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.autoUpdateRuleSets() }
        }
        scheduleReconcile()
    }

    /// 退出时停掉内核（经助手运行的也停掉，助手会恢复 IP 转发）。
    func shutdown() {
        stopPolling()
        saveTraffic(force: true)
        if runningViaHelper {
            helperRunner.stop()
        } else {
            runner.stop()
        }
        runningViaHelper = false
        api = nil
        shareStatus = .off
        tunStatus = .off
    }

    /// 配置变了：该跑就跑（配置内容变了就重新加载），不该跑就停。多次调用合并成一次。
    func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    /// 同一时间只让一个 reconcile 动内核：启动内核要等它响应，期间再来的（比如本机代理状态变了）排在后面执行。
    func reconcile() async {
        let previous = reconcileChain
        let task = Task { @MainActor [weak self] in
            if let previous {
                await previous.value
            }
            await self?.performReconcile()
        }
        reconcileChain = task
        await task.value
    }

    private func performReconcile() async {
        let engine = engineConfig
        let tun = effectiveTun
        guard wantsCore else {
            if api != nil || coreProcessRunning {
                stopCore()
            } else if status != .off {
                status = .off
            }
            updateTunStatus()
            return
        }
        // 内核还没下载好、校验过（第一次运行时正在下载，或者被删了）：先不启动，下好以后（CoreDownload.onInstalled）再来，
        // 不然会报一串「还没有下载内核」的错，也可能运行一个没校验过的内核。
        guard coreReady() else {
            if api != nil || coreProcessRunning {
                stopCore()
            }
            return
        }
        do {
            let text = try await generateConfig(engine)
            if coreProcessRunning, let api {
                if (tun != nil) != runningViaHelper {
                    // 开关虚拟网卡：内核换个方式运行（经助手以 root 运行，或者回到本机进程）。
                    stopCore()
                    try await startCore(with: text)
                } else if text != lastConfigText {
                    if portsChanged(from: lastConfigText, to: text) {
                        stopCore()
                        try await startCore(with: text)
                    } else {
                        try write(text)
                        if runningViaHelper {
                            try await syncHelperFiles()
                        }
                        try await api.reload(configPath: runningViaHelper ? HelperPaths.coreConfig : configURL.path)
                        lastConfigText = text
                        Log.info("内核配置已重新加载")
                        await syncForwarding()
                        await refresh()
                        await verifyShare()
                    }
                } else if shareInputs != nil, shareStatus == .starting {
                    await verifyShare()
                }
            } else {
                try await startCore(with: text)
            }
            lastError = nil
            updateTunStatus()
            // 还没下载的规则集这次先跳过了：内核起来以后在后台补下载（能经节点访问 GitHub），下好了再热加载。
            scheduleBackfill()
        } catch {
            if let tun, tunFailedFor != tun {
                // 虚拟网卡没开起来：记下来，先用本机的内核，代理照常能用。
                tunFailedFor = tun
                tunStatus = .failed(error.localizedDescription)
                Log.error("增强模式没有开起来：\(error.localizedDescription)；先不用虚拟网卡")
                scheduleReconcile()
                return
            }
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            if shareInputs != nil {
                shareStatus = .failed(error.localizedDescription)
            }
            Log.error("代理引擎出错：\(error.localizedDescription)")
        }
    }

    /// 开启内置配置前确保内核在跑，而且加载了订阅（只为共享而跑的内核没有代理端口）。
    func ensureRunning() async throws {
        guard engineConfig.wantsCore else {
            throw CoreRunnerError.notReady(engineConfig.enabled ? L("还没有添加订阅") : L("代理引擎已停用"))
        }
        if isRunning, coreProcessRunning, loadedMixedPort == engineConfig.mixedPort { return }
        reconcileTask?.cancel()
        await reconcile()
        guard isRunning else {
            if case .failed(let message) = status { throw CoreRunnerError.notReady(message) }
            throw CoreRunnerError.notReady(L("内核没有启动"))
        }
    }

    /// 内核现在加载的配置里本机的代理端口；0 表示没开（只在做局域网共享）。
    private var loadedMixedPort: Int? {
        guard let text = lastConfigText else { return nil }
        let prefix = "mixed-port: "
        for line in text.split(separator: "\n") where line.hasPrefix(prefix) {
            return Int(line.dropFirst(prefix.count))
        }
        return nil
    }

    func restartCore() async {
        stopCore()
        await reconcile()
    }

    private func startCore(with text: String) async throws {
        status = .starting
        CoreRunner.killStrays()
        try prepareDirectory()
        try write(text)
        // 内核控制接口的密钥：自己运行时就是 secret，经助手运行时是助手换上的。
        let apiSecret: String
        if effectiveTun != nil {
            // 虚拟网卡要 root：请特权助手把文件复制到它的目录，以 root 运行它那份内核。
            tunStatus = .starting
            let helper = helperRunner
            let source = Self.directory.path
            let files = helperFiles
            // root 的内核用助手换上的密钥（用户目录里那份配置里的密钥对它没用）。
            apiSecret = try await Task.detached(priority: .userInitiated) {
                try helper.start(source: source, files: files)
            }.value
            runningViaHelper = true
            forwardingOn = false
        } else {
            guard let executable = CoreBinary.executableURL else { throw CoreRunnerError.missingBinary }
            try runner.start(executable: executable, directory: Self.directory, config: configURL)
            apiSecret = secret
            runningViaHelper = false
        }
        let api = CoreAPI(port: engineConfig.apiPort, secret: apiSecret)
        self.api = api
        var version: String?
        for _ in 0..<50 {
            if !coreProcessRunning { break }
            if let found = try? await api.version() {
                version = found
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let version else {
            let tail = logTail.split(separator: "\n").suffix(3).joined(separator: " ")
            stopProcess()
            self.api = nil
            throw CoreRunnerError.notReady(tail.isEmpty ? L("没有响应") : tail)
        }
        lastConfigText = text
        restartAttempts = 0
        status = .running(version)
        let purpose = engineConfig.wantsCore ? L("代理端口 %@", engineConfig.mixedPort) : (effectiveTun?.gateway == true ? L("只用于网关模式") : L("只用于局域网共享"))
        Log.info("内核已启动，版本 \(version)，" + purpose + (runningViaHelper ? "，经特权助手开着虚拟网卡" : ""))
        await syncForwarding()
        if let selected = engineConfig.selectedNode {
            try? await api.select(group: Self.selectorGroup, node: selected)
        }
        startPolling()
        await refresh()
        await verifyShare()
    }

    func stopCore() {
        stopPolling()
        stopProcess()
        api = nil
        lastConfigText = nil
        status = .off
        shareStatus = shareInputs == nil ? .off : .starting
        nodes = []
        currentSelection = nil
        autoNode = nil
        groupStates = []
        subscriptionStatus = [:]
        connections = []
        sessionTraffic = TrafficTotal()
        accumulator = TrafficAccumulator()
        exitInfo = nil
        exitNode = nil
        exitTask?.cancel()
        speedHistory = []
        lastSpeedSample = nil
        manualNodeCount = nil
        updateTunStatus()
    }

    /// 停掉内核进程（本机的或者助手那边的）。
    private func stopProcess() {
        if runningViaHelper {
            helperRunner.stop()
        } else {
            runner.stop()
        }
        runningViaHelper = false
        forwardingOn = false
    }

    private func coreExited(_ code: Int32) {
        // 启动阶段的退出由 startCore 自己处理（配置错误时反复重启没有意义）。
        guard api != nil, status != .starting else { return }
        api = nil
        lastConfigText = nil
        stopPolling()
        if wantsCore && restartAttempts < 3 {
            restartAttempts += 1
            status = .starting
            if shareInputs != nil {
                shareStatus = .starting
            }
            Log.error("内核意外退出（状态 \(code)），第 \(restartAttempts) 次重新启动")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.reconcile()
            }
        } else {
            status = .failed(L("内核退出了（状态 %@）：%@", code, logTail.split(separator: "\n").suffix(2).joined(separator: " ")))
            if shareInputs != nil, case .failed(let message) = status {
                shareStatus = .failed(message)
            }
        }
    }

    /// 手动节点写进内核目录里的文件（一行一条链接），内容没变就不动它。
    private func writeManualNodes(_ engine: EngineConfig) throws {
        guard !engine.activeManualNodes.isEmpty else { return }
        let url = CoreConfigBuilder.manualNodesPath(directory: Self.directory)
        let text = CoreConfigBuilder.manualNodesText(engine)
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// file:// 订阅复制到内核目录里（内核不读别处的文件）。
    private func copyFileSubscriptions(_ engine: EngineConfig) throws {
        let fm = FileManager.default
        for subscription in engine.activeSubscriptions {
            guard let source = subscription.filePath else { continue }
            let target = CoreConfigBuilder.providerPath(for: subscription, directory: Self.directory)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            try data.write(to: target, options: .atomic)
        }
    }

    private func prepareDirectory() throws {
        let directory = Self.directory
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("providers"), withIntermediateDirectories: true)
        // 0.7 及以前把转换好的规则缓存在 core/rules-<哈希>.txt；现在规则文件都在 rules/ 目录里，旧缓存删掉。
        if let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for item in items where item.hasPrefix("rules-") && item.hasSuffix(".txt") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(item))
            }
        }
        // GeoIP 数据库：从下载目录复制一份（内核按 Country.mmdb 这个名字找）。
        if let bundled = CoreBinary.geoIPURL {
            let target = directory.appendingPathComponent("Country.mmdb")
            let bundledSize = (try? FileManager.default.attributesOfItem(atPath: bundled.path)[.size] as? Int) ?? 0
            let targetSize = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? -1
            if bundledSize != targetSize {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: bundled, to: target)
            }
        }
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func portsChanged(from old: String?, to new: String) -> Bool {
        guard let old else { return true }
        func ports(_ text: String) -> [String] {
            text.split(separator: "\n").filter { $0.hasPrefix("mixed-port:") || $0.hasPrefix("external-controller:") }.map(String.init)
        }
        return ports(old) != ports(new)
    }

    // MARK: - 配置生成

    private func generateConfig(_ engine: EngineConfig) async throws -> String {
        try copyFileSubscriptions(engine)
        try writeManualNodes(engine)
        let composed = composeRules(engine)
        let config = readConfig()
        let tun = effectiveTun
        let input = CoreConfigBuilder.Input(engine: engine, secret: secret, directory: Self.directory, testURL: config.testURL, rules: composed.rules, share: shareInputs, ruleProviders: composed.providers, profiles: config.profiles, probePort: probePort, tun: tun)
        // 经特权助手运行时，内核在 root 的目录里：路径换成那边的，文件由助手按名单复制过去。
        var runInput = input
        if tun != nil {
            // GeoIP 数据库也要复制过去，先确保本机目录里有。
            try? prepareDirectory()
            let home = URL(fileURLWithPath: HelperPaths.coreDirectory)
            runInput.directory = home
            runInput.ruleProviders = composed.providers.map { Self.relocated($0, to: home) }
            helperFiles = Self.helperFiles(engine, providers: composed.providers)
        }
        let built = CoreConfigBuilder.build(input)
        var problem = built.patchProblem
        var text = tun == nil ? built.text : CoreConfigBuilder.build(runInput).text
        if problem == nil, !engine.patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 打过补丁的配置先让内核自己检查一遍，通不过就用没打补丁的，免得内核起不来。
            // 检查时内核要读 GeoIP 数据库，先把目录准备好（不然它会去下载）；检查的总是本机目录的那份（内核只认自己目录下的路径）。
            try? prepareDirectory()
            if let checked = checkedPatch, checked.text == built.text {
                problem = checked.problem
            } else {
                problem = await Self.testConfig(built.text)
                checkedPatch = (built.text, problem)
            }
            if problem != nil {
                text = CoreConfigBuilder.yaml(runInput)
            }
        }
        if problem != patchProblem {
            if let problem {
                Log.error("配置补丁没有用上：\(problem)")
            }
            patchProblem = problem
        }
        if built.patchNotes != patchNotes {
            patchNotes = built.patchNotes
        }
        return text
    }

    /// 用内核检查一份配置（mihomo -t），通过返回 nil，否则返回内核说的问题。
    nonisolated static func testConfig(_ text: String) async -> String? {
        guard let executable = CoreBinary.executableURL else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let directory = Engine.directory
            let file = directory.appendingPathComponent("config-check.yaml")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: file) }
                let result = try Shell.runSync(executable.path, ["-t", "-d", directory.path, "-f", file.path], timeout: 20)
                if result.succeeded { return nil }
                return CoreConfigCheck.problem(from: result.output)
            } catch {
                return error.localizedDescription
            }
        }.value
    }

    // MARK: - 增强模式和网关模式

    /// 虚拟网卡的参数变了（开关增强模式或网关模式、特权助手装好了、本机的代理状态变了）：重新生成配置，需要时换运行方式。
    func setTun(_ inputs: TunInputs?) {
        guard inputs != tunInputs else { return }
        tunInputs = inputs
        // 参数变了就再试一次（上次失败的记录只对同样的参数有效）。
        if inputs != tunFailedFor {
            tunFailedFor = nil
        }
        updateTunStatus()
        scheduleReconcile()
    }

    /// 特权助手重新装好、起来了：上次增强模式没开起来的话再试一次（失败的记录只在参数变了时才清，这里也清掉）。
    func retryTunIfFailed() {
        guard tunFailedFor != nil else { return }
        tunFailedFor = nil
        updateTunStatus()
        scheduleReconcile()
    }

    /// 让助手按名单复制最新的文件（配置改了，接着让内核重新加载）。
    private func syncHelperFiles() async throws {
        let helper = helperRunner
        let source = Self.directory.path
        let files = helperFiles
        try await Task.detached(priority: .userInitiated) {
            try helper.sync(source: source, files: files)
        }.value
    }

    /// 网关模式要的 IP 转发：跟着设置开关（助手停掉内核时会自己恢复）。
    private func syncForwarding() async {
        guard runningViaHelper else {
            forwardingOn = false
            return
        }
        let wanted = effectiveTun?.gateway == true
        guard wanted != forwardingOn else { return }
        let helper = helperRunner
        do {
            try await Task.detached(priority: .userInitiated) {
                try helper.setForwarding(wanted)
            }.value
            forwardingOn = wanted
            Log.info(wanted ? "网关模式：已打开 IP 转发" : "网关模式：已关闭 IP 转发")
        } catch {
            Log.error("网关模式：\(error.localizedDescription)")
            tunStatus = .failed(L("打不开 IP 转发：%@", error.localizedDescription))
        }
    }

    private func updateTunStatus() {
        let next: TunStatus
        if tunInputs == nil {
            next = .off
        } else if effectiveTun == nil, case .failed = tunStatus {
            next = tunStatus
        } else if runningViaHelper, isRunning {
            if effectiveTun?.gateway == true && !forwardingOn, case .failed = tunStatus {
                next = tunStatus
            } else {
                next = .on(forwarding: forwardingOn)
            }
        } else {
            next = .starting
        }
        if next != tunStatus {
            tunStatus = next
        }
    }

    /// 规则集文件在 root 那边的路径。
    nonisolated static func relocated(_ provider: RuleProviderSpec, to home: URL) -> RuleProviderSpec {
        var copy = provider
        if let relative = relativePath(provider.path) {
            copy.path = home.appendingPathComponent(relative).path
        }
        return copy
    }

    /// 内核目录里的文件相对这个目录的路径；不在里面返回 nil。
    nonisolated static func relativePath(_ path: String) -> String? {
        let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count))
    }

    /// 经助手运行时要复制过去的文件：配置、GeoIP 数据库、手动节点、本机文件的订阅和规则集文件。
    /// 网络上的订阅由 root 的内核自己下载，不用复制。
    nonisolated static func helperFiles(_ engine: EngineConfig, providers: [RuleProviderSpec]) -> [String] {
        var files = ["config.yaml"]
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Country.mmdb").path) {
            files.append("Country.mmdb")
        }
        var paths: [String] = []
        if engine.wantsCore {
            if !engine.activeManualNodes.isEmpty {
                paths.append(CoreConfigBuilder.manualNodesPath(directory: directory).path)
            }
            for subscription in engine.activeSubscriptions where subscription.filePath != nil {
                paths.append(CoreConfigBuilder.providerPath(for: subscription, directory: directory).path)
            }
        }
        paths += providers.map(\.path)
        for path in paths {
            if let relative = relativePath(path), !files.contains(relative) {
                files.append(relative)
            }
        }
        return files
    }

    // MARK: - 局域网共享

    /// 本机的代理状态或共享设置变了：重新生成配置，内核热加载，共享的设备立刻跟着变。
    func setShare(_ inputs: ShareInputs?) {
        guard inputs != shareInputs else { return }
        shareInputs = inputs
        if inputs == nil {
            shareStatus = .off
        } else if shareStatus == .off {
            shareStatus = .starting
        }
        scheduleReconcile()
    }

    /// 共享入口是不是真的监听起来了：端口被占用时内核只记一条日志，不会退出，所以自己连一下确认。
    private func verifyShare() async {
        guard let share = shareInputs else {
            shareStatus = .off
            return
        }
        guard isRunning else { return }
        var reachable = false
        for _ in 0..<10 {
            if await ProxyTester.reachable(host: "127.0.0.1", port: share.port, timeout: 1) {
                reachable = true
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if reachable {
            if shareStatus != .listening(share.port) {
                Log.info("局域网共享已开启，端口 \(share.port)，\(share.upstream.summary)")
            }
            shareStatus = .listening(share.port)
        } else {
            var detail = L("可能被别的程序占用了")
            if let line = logTail.split(separator: "\n").last(where: { $0.contains(CoreConfigBuilder.shareListener) && $0.contains("err") }) {
                var text = String(line)
                if let range = text.range(of: "msg=") {
                    text = String(text[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                detail = text
            }
            let message = L("端口 %@ 没有监听起来：%@", share.port, detail)
            shareStatus = .failed(message)
            Log.error("局域网共享出错：\(message)")
        }
    }

    // MARK: - 连接与流量

    private func startPolling() {
        connectionsTask?.cancel()
        connectionsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollConnections()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopPolling() {
        connectionsTask?.cancel()
        connectionsTask = nil
    }

    /// /connections 只列出还开着的连接，短连接一闪就没了，所以每次轮询把没见过的记进「最近的连接」，同时按出口累计流量。
    private func pollConnections() async {
        guard let api, isRunning else { return }
        guard let snapshot = try? await api.connectionsSnapshot() else { return }
        let list = snapshot.connections ?? []
        if list != connections {
            connections = list
        }
        let session = TrafficTotal(upload: snapshot.uploadTotal ?? 0, download: snapshot.downloadTotal ?? 0)
        if session != sessionTraffic {
            sessionTraffic = session
        }
        recordSpeed(session)
        record(list)
        let delta = accumulator.ingestDetailed(list)
        if !delta.isEmpty {
            traffic.add(delta)
            trafficDirty = true
        }
        if trafficDirty, Date().timeIntervalSince(lastTrafficSave) > 30 {
            saveTraffic()
        }
    }

    /// 按两次采样之间总流量的差算网速，留最近两分钟。
    private func recordSpeed(_ total: TrafficTotal) {
        let now = Date()
        defer { lastSpeedSample = (now, total) }
        guard let last = lastSpeedSample else { return }
        let seconds = now.timeIntervalSince(last.date)
        guard seconds > 0.5 else { return }
        let up = max(0, total.upload - last.traffic.upload)
        let down = max(0, total.download - last.traffic.download)
        var history = speedHistory
        history.append(SpeedSample(date: now, upload: Int64(Double(up) / seconds), download: Int64(Double(down) / seconds)))
        if history.count > Self.speedHistoryLimit {
            history.removeFirst(history.count - Self.speedHistoryLimit)
        }
        speedHistory = history
    }

    private func record(_ list: [CoreConnection]) {
        guard !list.isEmpty else { return }
        var updated = history
        var positions: [String: Int] = [:]
        for (position, record) in updated.enumerated() {
            positions[record.id] = position
        }
        var fresh: [ConnectionRecord] = []
        for connection in list {
            let record = ConnectionRecord(connection)
            if let position = positions[connection.id] {
                if updated[position] != record {
                    updated[position] = record
                }
            } else {
                fresh.append(record)
            }
        }
        if !fresh.isEmpty {
            fresh.sort { $0.start > $1.start }
            updated.insert(contentsOf: fresh, at: 0)
        }
        if updated.count > Self.historyLimit {
            updated.removeLast(updated.count - Self.historyLimit)
        }
        if updated != history {
            history = updated
        }
    }

    /// 清空「最近的连接」；shareOnly 时只清设备的。
    func clearHistory(shareOnly: Bool = false) {
        if shareOnly {
            history.removeAll(where: \.isShare)
        } else {
            history = []
        }
    }

    /// 断开一条连接。
    func close(connection id: String) async {
        guard let api else { return }
        do {
            try await api.closeConnection(id)
            connections.removeAll { $0.id == id }
        } catch {
            lastError = L("断开连接失败：%@", error.localizedDescription)
        }
    }

    /// 断开全部连接。
    func closeAllConnections() async {
        guard let api else { return }
        do {
            try await api.closeAllConnections()
            connections = []
            Log.info("已断开全部连接")
        } catch {
            lastError = L("断开连接失败：%@", error.localizedDescription)
        }
    }

    /// 启动时把本机状态里存的流量统计装进来。
    func loadTraffic(_ stats: TrafficStats) {
        traffic = stats
    }

    func resetTraffic() {
        traffic.reset()
        trafficDirty = true
        saveTraffic(force: true)
        Log.info("流量统计已清零")
    }

    private func saveTraffic(force: Bool = false) {
        guard trafficDirty || force else { return }
        trafficDirty = false
        lastTrafficSave = Date()
        persistTraffic?(traffic)
    }

    // MARK: - 出口 IP

    private func scheduleExitCheck() {
        exitTask?.cancel()
        exitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.checkExit()
        }
    }

    /// 查经节点出去的出口 IP。同一个节点查过就用上次的结果，除非 force。
    func checkExit(force: Bool = false) async {
        guard isRunning, engineConfig.wantsCore else {
            exitInfo = nil
            return
        }
        let node = effectiveNode ?? currentSelection ?? ""
        if !force, let cached = exitCache[node] {
            exitInfo = cached
            exitProblem = nil
            exitNode = node
            return
        }
        guard !checkingExit else { return }
        checkingExit = true
        let result = await ExitIPChecker.check(proxyPort: engineConfig.mixedPort)
        checkingExit = false
        exitNode = node
        switch result {
        case .success(let info):
            exitCache[node] = info
            exitInfo = info
            exitProblem = nil
            Log.info("节点出口：\(info.summary)")
        case .failure(let error):
            exitInfo = nil
            exitProblem = error.localizedDescription
        }
        // 查的过程中节点换了：再查一次。
        if isRunning, node != (effectiveNode ?? currentSelection ?? "") {
            scheduleExitCheck()
        }
    }

    /// 查本机直连的出口 IP。
    func checkDirectExit() async {
        guard !checkingDirectExit else { return }
        checkingDirectExit = true
        let result = await ExitIPChecker.check(proxyPort: nil)
        checkingDirectExit = false
        switch result {
        case .success(let info):
            directExit = info
            directExitProblem = nil
        case .failure(let error):
            directExit = nil
            directExitProblem = error.localizedDescription
        }
    }

    // MARK: - 规则

    /// 按规则集顺序拼出内核的规则：内置的直接展开，纯规则列表交给内核的 rule-provider（RULE-SET 引用），
    /// 小火箭 / Surge 完整配置转换后内联。最后一条是 MATCH：按设置，或者跟随规则文件里的 FINAL，都没有就走节点。
    /// 这里不联网：还没下载的规则集先跳过，记下来由后台补下载，免得 GitHub 连不上时内核迟迟起不来。
    private func composeRules(_ engine: EngineConfig) -> (rules: [String], providers: [RuleProviderSpec]) {
        let groups = engine.groupNames
        missingRuleSets = []
        missingReferences = []
        switch engine.mode {
        case .global:
            rulesInfo = L("全局代理：除局域网和自定义规则外全部走节点")
            return (RuleConverter.globalRules, [])
        case .rule:
            var rules: [String] = []
            var providers: [RuleProviderSpec] = []
            var fileFinal: String?
            var pending: [String] = []
            var inlineCount = 0
            let active = engine.activeRuleSets
            for set in active {
                switch set.kind {
                case .builtin:
                    let policy = (set.policy ?? .direct).resolved(groups: groups)
                    if let builtin = RuleConverter.builtinRules(url: set.url, policy: policy) {
                        rules += builtin
                        ruleSetStatus[set.id] = RuleSetStatus(count: builtin.count, updatedAt: nil, problem: nil)
                    }
                case .provider:
                    guard let file = availableRuleFile(set) else {
                        pending.append(set.name)
                        continue
                    }
                    providers.append(RuleProviderSpec(name: set.providerName, path: file.path, behavior: set.effectiveBehavior, format: set.format))
                    rules.append("RULE-SET,\(set.providerName),\((set.policy ?? .proxy).resolved(groups: groups))")
                case .inline:
                    guard let result = inlineRules(for: set, groups: groups) else {
                        pending.append(set.name)
                        continue
                    }
                    rules += result.rules
                    inlineCount += result.rules.count
                    if set.policy == nil, let final = result.final {
                        fileFinal = final
                    }
                }
            }
            let final = engine.finalPolicy?.resolved(groups: groups) ?? fileFinal ?? RuleConverter.proxyGroup
            rules.append("MATCH,\(final)")
            var info = active.isEmpty ? L("没有启用的规则集") : L("%@ 个规则集", active.count)
            if !providers.isEmpty { info += L("，%@ 个由内核加载", providers.count) }
            if inlineCount > 0 { info += L("，%@ 条已转换", inlineCount) }
            info += L("；其余流量%@", RuleTarget.title(forCorePolicy: final))
            if !pending.isEmpty { info += L("。「%@」还没下载下来，先跳过，下好了自动生效", pending.joined(separator: L("」「"))) }
            rulesInfo = info
            return (rules, providers)
        }
    }

    /// 规则集在内核目录里的文件：本机文件每次复制最新的；远程的下载过就用，没下载过返回 nil 并记下来等后台补下载。
    private func availableRuleFile(_ set: RuleSet) -> URL? {
        let file = RuleStore.fileURL(for: set, in: Self.directory)
        if set.filePath != nil {
            return copyLocalRuleFile(set) ?? (RuleStore.exists(file) ? file : nil)
        }
        if RuleStore.exists(file) { return file }
        missingRuleSets.insert(set.id)
        return nil
    }

    /// file:// 规则集复制到内核目录里（内核只读自己目录下的文件），顺便检测类型。
    @discardableResult
    private func copyLocalRuleFile(_ set: RuleSet) -> URL? {
        guard let source = set.filePath else { return nil }
        let file = RuleStore.fileURL(for: set, in: Self.directory)
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            try RuleStore.save(data, to: file)
            recordDetection(for: set, data: data)
            setProblem(nil, for: set.id)
            return file
        } catch {
            setProblem(L("读不了本机文件：%@", error.localizedDescription), for: set.id)
            return nil
        }
    }

    /// 下载一个远程规则集到内核目录，检测类型并写回配置。成功返回 true；失败记下时间和原因，文件原来有的话照旧用。
    private func download(_ set: RuleSet) async -> Bool {
        let file = RuleStore.fileURL(for: set, in: Self.directory)
        downloadingRuleSets.insert(set.id)
        defer { downloadingRuleSets.remove(set.id) }
        do {
            let data = try await RuleStore.download(set.url, routes: downloadRoutes(for: set.url))
            // 下载期间被删掉了：不留文件。
            guard engineConfig.ruleSets.contains(where: { $0.id == set.id }) else { return false }
            try RuleStore.save(data, to: file)
            lastDownloadFailure[set.url] = nil
            setProblem(nil, for: set.id)
            recordDetection(for: set, data: data)
            Log.info("规则「\(set.name)」已下载，\(Self.bytesText(Int64(data.count)))")
            // 完整配置里引用的列表也一起下载（强制刷新时重新下载）。
            if let current = engineConfig.ruleSets.first(where: { $0.id == set.id }), current.kind == .inline {
                for reference in RuleConverter.referencedRuleSets(String(decoding: data, as: UTF8.self)) {
                    _ = await downloadReference(reference)
                }
            }
            return true
        } catch {
            lastDownloadFailure[set.url] = Date()
            setProblem(L("下载失败：%@", error.localizedDescription), for: set.id)
            Log.error("下载规则「\(set.name)」失败：\(error.localizedDescription)")
            return false
        }
    }

    private func downloadReference(_ url: String) async -> Bool {
        do {
            let data = try await RuleStore.download(url, routes: downloadRoutes(for: url))
            try RuleStore.save(data, to: RuleStore.referenceURL(for: url, in: Self.directory))
            lastDownloadFailure[url] = nil
            return true
        } catch {
            lastDownloadFailure[url] = Date()
            Log.error("下载规则集 \(url) 失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 下载下来的内容是什么类型：纯列表是完整规则、域名还是 IP 段；是不是其实是完整配置、要转换。
    /// 按 id 找到现在配置里的那一条，只改这两个字段，下载期间别的改动不会被覆盖。
    private func recordDetection(for set: RuleSet, data: Data) {
        guard set.format != "mrs" else { return }
        let text = String(decoding: data, as: UTF8.self)
        var engine = engineConfig
        guard let index = engine.ruleSets.firstIndex(where: { $0.id == set.id }) else { return }
        var changed = false
        if RuleSet.providerExtensions.contains(set.fileExtension) {
            let convert = RuleConverter.needsConversion(text)
            if engine.ruleSets[index].converted != convert {
                // 第一次发现是完整配置：默认按文件里写的策略走（添加时选的去向是给纯列表用的），行里可以再改。
                if convert, engine.ruleSets[index].converted == nil {
                    engine.ruleSets[index].policy = nil
                }
                engine.ruleSets[index].converted = convert
                changed = true
            }
            if !convert, engine.ruleSets[index].behavior == nil {
                engine.ruleSets[index].behavior = RuleConverter.detectBehavior(text)
                changed = true
            }
        }
        if changed {
            writeEngine?(engine)
        }
    }

    private func setProblem(_ problem: String?, for id: UUID) {
        var entry = ruleSetStatus[id] ?? RuleSetStatus()
        guard entry.problem != problem else { return }
        entry.problem = problem
        ruleSetStatus[id] = entry
    }

    /// 下载规则走的线路：内核在跑就先经它（直连 GitHub 不一定连得上），再系统代理、直连；每条线路都会试 jsDelivr 镜像。
    private func downloadRoutes(for text: String) -> [NetworkRoute] {
        guard let url = URL(string: text) else { return [.direct] }
        let corePort = (isRunning && engineConfig.wantsCore) ? engineConfig.mixedPort : nil
        return NetworkRoute.routes(for: url, corePort: corePort, system: SystemProxy.current())
    }

    /// 小火箭 / Surge 完整配置：转换成内核规则；文件里 RULE-SET 引用的列表也内联进来。还没下载的返回 nil，
    /// 引用的列表还没下载的先略过，都记下来等后台补下载。
    private func inlineRules(for set: RuleSet, groups: [String]) -> InlineRules? {
        guard let file = availableRuleFile(set), let text = RuleStore.loadText(file) else { return nil }
        let policy = set.policy?.resolved(groups: groups)
        let converted = RuleConverter.convert(text, force: policy, groups: groups)
        var stamps = [CloudFile.stamp(of: file) ?? ""]
        for reference in converted.ruleSets {
            stamps.append(CloudFile.stamp(of: RuleStore.referenceURL(for: reference.url, in: Self.directory)) ?? "-")
        }
        let key = "\(set.id)|\(policy ?? "-")|\(groups.joined(separator: ","))|\(stamps.joined(separator: ","))"
        if let cached = inlineCache[key] {
            for reference in converted.ruleSets where !RuleStore.exists(RuleStore.referenceURL(for: reference.url, in: Self.directory)) {
                missingReferences.insert(reference.url)
            }
            return cached
        }
        var warnings: [String] = []
        if converted.skipped > 0 {
            warnings.append(L("跳过了 %@ 条内核不支持的规则", converted.skipped))
        }
        var ruleSetRules: [String: [String]] = [:]
        var pendingReferences = 0
        for reference in converted.ruleSets where ruleSetRules[reference.url] == nil {
            let referenceFile = RuleStore.referenceURL(for: reference.url, in: Self.directory)
            if let listText = RuleStore.loadText(referenceFile) {
                ruleSetRules[reference.url] = RuleConverter.convert(listText, defaultPolicy: reference.policy, force: policy, groups: groups).rules
            } else {
                missingReferences.insert(reference.url)
                pendingReferences += 1
            }
        }
        if pendingReferences > 0 {
            warnings.append(L("%@ 个引用的规则集还没下载下来", pendingReferences))
        }
        let merged = RuleConverter.merge(converted, ruleSetRules: ruleSetRules)
        let final = merged.last(where: { $0.hasPrefix("MATCH,") }).map { String($0.dropFirst("MATCH,".count)) }
        let result = InlineRules(rules: merged.filter { !$0.hasPrefix("MATCH,") }, final: final, warnings: warnings)
        if inlineCache.count > 20 {
            inlineCache = [:]
        }
        inlineCache[key] = result
        var entry = ruleSetStatus[set.id] ?? RuleSetStatus()
        entry.count = result.rules.count
        entry.updatedAt = RuleStore.modificationDate(of: file)
        if entry.problem == nil || entry.problem?.hasPrefix(L("下载失败")) == false {
            entry.problem = warnings.isEmpty ? nil : warnings.joined(separator: L("，"))
        }
        ruleSetStatus[set.id] = entry
        return result
    }

    /// 后台补下载：内核起来以后把这次跳过的规则集和引用的列表下载下来，有下好的就重新生成配置、热加载。
    /// 最近失败过的隔一会儿再试。
    private func scheduleBackfill() {
        guard backfillTask == nil else { return }
        let now = Date()
        let sets = engineConfig.activeRuleSets.filter { set in
            missingRuleSets.contains(set.id) && !downloadingRuleSets.contains(set.id)
                && now.timeIntervalSince(lastDownloadFailure[set.url] ?? .distantPast) > Self.downloadRetryInterval
        }
        let references = missingReferences.filter { now.timeIntervalSince(lastDownloadFailure[$0] ?? .distantPast) > Self.downloadRetryInterval }
        guard !sets.isEmpty || !references.isEmpty else { return }
        backfillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var gotAny = false
            for set in sets {
                if await self.download(set) { gotAny = true }
            }
            for url in references {
                if await self.downloadReference(url) { gotAny = true }
            }
            self.backfillTask = nil
            if gotAny {
                self.scheduleReconcile()
            } else {
                // 下载期间新加的规则集接着下（刚失败的会被跳过，不会反复重试）。
                self.scheduleBackfill()
            }
        }
    }

    /// 重新下载一个规则集并应用：内核加载的让它重读文件，转换内联的重新生成配置。
    func refreshRuleSet(_ id: UUID) async {
        guard let set = engineConfig.ruleSets.first(where: { $0.id == id }), !set.isBuiltin, !downloadingRuleSets.contains(id) else { return }
        if set.filePath != nil {
            guard copyLocalRuleFile(set) != nil else { return }
        } else {
            guard await download(set) else { return }
        }
        let current = engineConfig.ruleSets.first { $0.id == id } ?? set
        if current.kind == .provider, let api, isRunning, lastConfigText?.contains(current.providerName) == true {
            do {
                try await api.updateRuleProvider(current.providerName)
                Log.info("规则「\(current.name)」已重新加载")
            } catch {
                Log.error("重新加载规则「\(current.name)」失败：\(error.localizedDescription)")
            }
        }
        // 之前被跳过的现在有文件了，或者转换内联的内容变了：配置会跟着变，内核热加载。
        await reconcile()
        await refresh()
    }

    /// 重新下载全部规则集。
    func refreshAllRuleSets() async {
        for set in engineConfig.activeRuleSets where !set.isBuiltin {
            await refreshRuleSet(set.id)
        }
    }

    /// 到期的规则集自动更新（本机文件不用）。
    private func autoUpdateRuleSets() async {
        let interval = TimeInterval(max(1, engineConfig.updateIntervalHours)) * 3600
        for set in engineConfig.activeRuleSets where !set.isBuiltin && set.filePath == nil {
            let age = RuleStore.age(of: RuleStore.fileURL(for: set, in: Self.directory)) ?? .infinity
            if age >= interval {
                await refreshRuleSet(set.id)
            }
        }
        scheduleBackfill()
    }

    // MARK: - 节点与策略组

    func refresh() async {
        guard let api else { return }
        do {
            async let proxiesTask = api.proxies()
            async let providersTask = api.providers()
            async let ruleProvidersTask = api.ruleProviders()
            let (proxies, providers) = try await (proxiesTask, providersTask)
            let ruleProviders = (try? await ruleProvidersTask) ?? [:]
            let engine = engineConfig
            currentSelection = proxies[Self.selectorGroup]?.now
            autoNode = proxies[Self.autoGroup]?.now
            var list: [Node] = []
            var statuses: [UUID: SubscriptionStatus] = [:]
            for subscription in engine.activeSubscriptions {
                guard let provider = providers[subscription.providerName] else { continue }
                statuses[subscription.id] = SubscriptionStatus(nodeCount: provider.proxies.count, info: provider.subscriptionInfo, updatedAt: Self.parseDate(provider.updatedAt))
                for proxy in provider.proxies {
                    list.append(Node(name: proxy.name, type: proxy.type, delay: proxy.lastDelay, subscription: subscription.name, source: subscription.id, provider: subscription.providerName))
                }
            }
            if !engine.activeManualNodes.isEmpty {
                let manual = providers[ManualNode.providerName]?.proxies ?? []
                for proxy in manual {
                    list.append(Node(name: proxy.name, type: proxy.type, delay: proxy.lastDelay, subscription: L("手动节点"), source: ManualNode.sourceID, provider: ManualNode.providerName))
                }
                if manualNodeCount != manual.count {
                    manualNodeCount = manual.count
                }
            } else if manualNodeCount != nil {
                manualNodeCount = nil
            }
            if list.map(\.name) != nodes.map(\.name) {
                Log.info("读取到 \(list.count) 个节点")
            }
            nodes = list
            subscriptionStatus = statuses
            var groups: [GroupState] = []
            for group in engine.groups {
                guard let proxy = proxies[group.name] else { continue }
                groups.append(GroupState(name: group.name, kind: group.kind, now: proxy.now, members: proxy.all ?? []))
            }
            if groups != groupStates {
                groupStates = groups
            }
            var statusMap = ruleSetStatus
            for set in engine.ruleSets where set.kind == .provider {
                guard let provider = ruleProviders[set.providerName] else { continue }
                var entry = statusMap[set.id] ?? RuleSetStatus()
                entry.count = provider.ruleCount
                entry.updatedAt = RuleStore.modificationDate(of: RuleStore.fileURL(for: set, in: Self.directory)) ?? Self.parseDate(provider.updatedAt)
                statusMap[set.id] = entry
            }
            if statusMap != ruleSetStatus {
                ruleSetStatus = statusMap
            }
            let node = effectiveNode ?? currentSelection ?? ""
            if node != exitNode, !checkingExit {
                scheduleExitCheck()
            }
        } catch {
            Log.error("读取节点列表失败：\(error.localizedDescription)")
        }
    }

    /// 选节点；nil 是自动选择。
    func select(_ node: String?) async {
        guard let api else { return }
        let target = node ?? Self.autoGroup
        do {
            try await api.select(group: Self.selectorGroup, node: target)
            var engine = engineConfig
            engine.selectedNode = node
            writeEngine?(engine)
            await refresh()
            Log.info("已切换到节点：\(target)")
        } catch {
            lastError = L("切换节点失败：%@", error.localizedDescription)
        }
    }

    /// 给某个自定义策略组选成员。内核记着每个组的选择（store-selected），重启后还在。
    func select(group: String, member: String) async {
        guard let api else { return }
        do {
            try await api.select(group: group, node: member)
            await refresh()
            Log.info("策略组「\(group)」切换到：\(member)")
        } catch {
            lastError = L("切换策略组失败：%@", error.localizedDescription)
        }
    }

    func testAll() async {
        guard let api, !testing else { return }
        testing = true
        let delays = (try? await api.groupDelay(group: Self.selectorGroup, url: readConfig().testURL)) ?? [:]
        nodes = nodes.map { node in
            var node = node
            node.delay = delays[node.name] ?? 0
            return node
        }
        testing = false
        await refresh()
    }

    func test(node name: String) async {
        guard let api else { return }
        let delay = (try? await api.delay(node: name, url: readConfig().testURL)) ?? 0
        if let index = nodes.firstIndex(where: { $0.name == name }) {
            nodes[index].delay = delay
        }
    }

    /// 测一个节点的延迟（毫秒）；连不上或内核没跑是 0。
    func delay(of name: String) async -> Int {
        guard let api else { return 0 }
        let delay = (try? await api.delay(node: name, url: readConfig().testURL)) ?? 0
        if let index = nodes.firstIndex(where: { $0.name == name }) {
            nodes[index].delay = delay
        }
        return delay
    }

    /// 经内核的某个入口访问一次，同时从内核日志里抓这次连接的判定：命中哪条规则、走了哪个出口、有没有出错。
    /// 内核在拨号时就写这行日志；订阅日志流要先于访问开始，最多再等一秒半。
    func traceConnection(url: URL, host: String, port: Int, viaPort: Int) async -> (probe: ProbeResult, trace: RouteTrace?) {
        let proxy = ProbeResult.proxyDictionary(port: viaPort)
        guard let api, isRunning else {
            return (await ProbeResult.probe(url: url, proxy: proxy, timeout: 10), nil)
        }
        let reader = Task { @MainActor () -> RouteTrace? in
            do {
                let bytes = try await api.logBytes(level: "info")
                for try await line in bytes.lines {
                    if Task.isCancelled { return nil }
                    guard let data = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let payload = json["payload"] as? String,
                          let trace = RouteTrace.parse(payload), trace.host == host, trace.port == port else { continue }
                    return trace
                }
            } catch {
                // 被取消或者流断了：没抓到就是没抓到。
            }
            return nil
        }
        try? await Task.sleep(for: .milliseconds(300))
        let probe = await ProbeResult.probe(url: url, proxy: proxy, timeout: 10)
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            reader.cancel()
        }
        let trace = await reader.value
        deadline.cancel()
        return (probe, trace)
    }

    // MARK: - 设置

    func setEnabled(_ enabled: Bool) {
        var engine = engineConfig
        engine.enabled = enabled
        writeEngine?(engine)
    }

    func setMode(_ mode: EngineMode) {
        var engine = engineConfig
        engine.mode = mode
        writeEngine?(engine)
    }

    /// 没被规则命中的流量往哪走；nil 表示跟随规则文件里的 FINAL。
    func setFinalPolicy(_ target: RuleTarget?) {
        var engine = engineConfig
        engine.finalPolicy = target
        writeEngine?(engine)
    }

    func setPorts(mixed: Int, api: Int) {
        var engine = engineConfig
        engine.mixedPort = mixed
        engine.apiPort = api
        writeEngine?(engine)
    }

    // MARK: - 策略组

    /// 新建策略组。返回问题描述，成功返回 nil。
    @discardableResult
    func addGroup(name: String, kind: PolicyGroupKind, filter: String) -> String? {
        addGroup(PolicyGroup(name: name, kind: kind, filter: filter))
    }

    /// 新建策略组（带高级选项）。返回问题描述，成功返回 nil。
    @discardableResult
    func addGroup(_ draft: PolicyGroup) -> String? {
        var engine = engineConfig
        if let problem = PolicyGroup.validate(name: draft.name, filter: draft.filter, others: engine.groups) { return problem }
        let group = Self.cleaned(draft)
        if let problem = PolicyGroup.validateAdvanced(group, all: engine.groups + [group]) { return problem }
        if nodes.contains(where: { $0.name.caseInsensitiveCompare(group.name) == .orderedSame }) {
            return L("有个节点也叫「%@」，换一个名字", group.name)
        }
        engine.groups.append(group)
        writeEngine?(engine)
        Log.info("新建策略组「\(group.name)」（\(group.kind.title)）")
        return nil
    }

    /// 名字、筛选去掉首尾空白，包含的组去重。
    private static func cleaned(_ group: PolicyGroup) -> PolicyGroup {
        var result = PolicyGroup(name: group.name, kind: group.kind, filter: group.filter)
        result.id = group.id
        result.exclude = group.exclude.trimmingCharacters(in: .whitespaces)
        var members: [String] = []
        for member in group.includeGroups where !members.contains(member) {
            members.append(member)
        }
        result.includeGroups = members
        result.sources = group.sources
        result.testURL = group.testURL.trimmingCharacters(in: .whitespaces)
        result.interval = group.interval
        result.tolerance = group.tolerance
        result.strategy = group.strategy
        return result
    }

    /// 改一个策略组；改了名字的话指向它的规则、包含它的组跟着改。返回问题描述，成功返回 nil。
    @discardableResult
    func saveGroup(_ group: PolicyGroup) -> String? {
        var engine = engineConfig
        guard let index = engine.groups.firstIndex(where: { $0.id == group.id }) else { return L("这个策略组已经不存在了") }
        let others = engine.groups.filter { $0.id != group.id }
        if let problem = PolicyGroup.validate(name: group.name, filter: group.filter, others: others) { return problem }
        let old = engine.groups[index]
        let updated = Self.cleaned(group)
        var renamedMembers = engine.groups
        renamedMembers[index] = updated
        if old.name != updated.name {
            for position in renamedMembers.indices {
                renamedMembers[position].renameMember(from: old.name, to: updated.name)
            }
        }
        if let problem = PolicyGroup.validateAdvanced(renamedMembers[index], all: renamedMembers) { return problem }
        if old.name != updated.name, nodes.contains(where: { $0.name.caseInsensitiveCompare(updated.name) == .orderedSame }) {
            return L("有个节点也叫「%@」，换一个名字", updated.name)
        }
        engine.groups[index] = renamedMembers[index]
        if old.name != updated.name {
            engine.retarget(from: old.name, to: .group(updated.name))
        }
        writeEngine?(engine)
        return nil
    }

    /// 删策略组：指向它的规则改成走节点。
    func removeGroup(_ id: UUID) {
        var engine = engineConfig
        guard let group = engine.groups.first(where: { $0.id == id }) else { return }
        engine.groups.removeAll { $0.id == id }
        engine.retarget(from: group.name, to: .proxy)
        writeEngine?(engine)
        Log.info("删除策略组「\(group.name)」")
    }

    func moveGroup(_ id: UUID, up: Bool) {
        var engine = engineConfig
        guard let index = engine.groups.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard engine.groups.indices.contains(target) else { return }
        engine.groups.swapAt(index, target)
        writeEngine?(engine)
    }

    // MARK: - 规则集

    /// 加一个规则集。返回问题描述，成功返回 nil。
    @discardableResult
    func addRuleSet(name: String, url: String, policy: RuleTarget?, behavior: RuleSetBehavior? = nil) -> String? {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = RuleSet.validate(url: trimmedURL) { return problem }
        var engine = engineConfig
        if engine.ruleSets.contains(where: { $0.url == trimmedURL }) { return L("这个规则已经在列表里了") }
        let set: RuleSet
        if trimmedURL == RuleSet.chinaDirectURL {
            set = RuleSet.chinaDirect()
        } else {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            set = RuleSet(name: trimmedName.isEmpty ? RuleSet.defaultName(for: trimmedURL) : trimmedName, url: trimmedURL, policy: policy, behavior: behavior)
        }
        engine.ruleSets.append(set)
        writeEngine?(engine)
        Log.info("添加规则集「\(set.name)」：\(set.url)")
        return nil
    }

    /// 从规则库加一条。
    @discardableResult
    func add(_ entry: RuleLibraryEntry) -> String? {
        addRuleSet(name: entry.name, url: entry.url, policy: entry.policy, behavior: entry.behavior)
    }

    /// 改一个规则集的名字、去向或开关。只取这三项：界面上那份可能是后台下载写回检测结果之前的，别把检测结果冲掉。
    func saveRuleSet(_ set: RuleSet) {
        var engine = engineConfig
        guard let index = engine.ruleSets.firstIndex(where: { $0.id == set.id }) else { return }
        let trimmed = set.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            engine.ruleSets[index].name = trimmed
        }
        engine.ruleSets[index].policy = set.policy
        engine.ruleSets[index].enabled = set.enabled
        writeEngine?(engine)
    }

    func removeRuleSet(_ id: UUID) {
        var engine = engineConfig
        guard let set = engine.ruleSets.first(where: { $0.id == id }) else { return }
        engine.ruleSets.removeAll { $0.id == id }
        writeEngine?(engine)
        ruleSetStatus[id] = nil
        missingRuleSets.remove(id)
        if !set.isBuiltin {
            try? FileManager.default.removeItem(at: RuleStore.fileURL(for: set, in: Self.directory))
        }
        Log.info("删除规则集「\(set.name)」")
    }

    func moveRuleSet(_ id: UUID, up: Bool) {
        var engine = engineConfig
        guard let index = engine.ruleSets.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard engine.ruleSets.indices.contains(target) else { return }
        engine.ruleSets.swapAt(index, target)
        writeEngine?(engine)
    }

    // MARK: - 自定义规则

    /// 加一条自定义规则；已有同样的就改它的去向。返回问题描述，成功返回 nil。
    @discardableResult
    func addCustomRule(pattern: String, policy: RuleTarget, kind: CustomRuleKind = .auto) -> String? {
        if let problem = CustomRule.validate(pattern, kind: kind) { return problem }
        var engine = engineConfig
        let rule = CustomRule(pattern: pattern, policy: policy, kind: kind)
        if let index = engine.customRules.firstIndex(where: { $0.sameMatch(as: rule) }) {
            engine.customRules[index].policy = policy
            engine.customRules[index].enabled = true
        } else {
            engine.customRules.append(rule)
        }
        writeEngine?(engine)
        Log.info("自定义规则：\(kind == .auto ? "" : kind.title + " ")\(rule.displayValue) \(policy.title)")
        return nil
    }

    func moveCustomRule(_ id: UUID, up: Bool) {
        var engine = engineConfig
        guard let index = engine.customRules.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard engine.customRules.indices.contains(target) else { return }
        engine.customRules.swapAt(index, target)
        writeEngine?(engine)
    }

    func updateCustomRule(_ rule: CustomRule) {
        var engine = engineConfig
        guard let index = engine.customRules.firstIndex(where: { $0.id == rule.id }) else { return }
        engine.customRules[index] = rule
        writeEngine?(engine)
    }

    func removeCustomRule(_ id: UUID) {
        var engine = engineConfig
        engine.customRules.removeAll { $0.id == id }
        writeEngine?(engine)
    }

    // MARK: - 订阅

    @discardableResult
    func addSubscription(name: String, url: String) -> String? {
        if let problem = Subscription.validate(url: url) { return problem }
        var engine = engineConfig
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        engine.subscriptions.append(Subscription(name: trimmedName.isEmpty ? L("订阅 %@", engine.subscriptions.count + 1) : trimmedName, url: url.trimmingCharacters(in: .whitespacesAndNewlines)))
        writeEngine?(engine)
        return nil
    }

    func removeSubscription(_ id: UUID) {
        var engine = engineConfig
        engine.subscriptions.removeAll { $0.id == id }
        writeEngine?(engine)
        subscriptionStatus[id] = nil
    }

    func setSubscription(_ id: UUID, enabled: Bool) {
        var engine = engineConfig
        guard let index = engine.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        engine.subscriptions[index].enabled = enabled
        writeEngine?(engine)
    }

    /// 让内核重新下载订阅（file:// 的先重新复制）。
    func updateSubscription(_ id: UUID) async {
        guard let api, let subscription = engineConfig.subscriptions.first(where: { $0.id == id }) else { return }
        updatingSubscription = id
        do {
            if subscription.filePath != nil {
                try copyFileSubscriptions(engineConfig)
            }
            try await api.updateProvider(subscription.providerName)
            await refresh()
            Log.info("订阅「\(subscription.name)」已更新")
        } catch {
            lastError = L("更新订阅「%@」失败：%@", subscription.name, error.localizedDescription)
        }
        updatingSubscription = nil
    }

    func updateAllSubscriptions() async {
        for subscription in engineConfig.activeSubscriptions {
            await updateSubscription(subscription.id)
        }
    }

    // MARK: - 订阅的筛选、前缀和前置代理

    /// 保存订阅的名字、地址、筛选、前缀和前置代理。返回问题描述，成功返回 nil。
    @discardableResult
    func saveSubscription(_ subscription: Subscription) -> String? {
        let url = subscription.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Subscription.validate(url: url) { return problem }
        let filter = subscription.filter.trimmingCharacters(in: .whitespaces)
        let exclude = subscription.exclude.trimmingCharacters(in: .whitespaces)
        if let problem = Subscription.validateOptions(filter: filter, exclude: exclude, prefix: subscription.prefix) { return problem }
        let dialer = subscription.dialer?.trimmingCharacters(in: .whitespaces)
        if let dialer, !dialer.isEmpty, let problem = validateDialer(dialer, provider: subscription.providerName) { return problem }
        var engine = engineConfig
        guard let index = engine.subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return L("这条订阅已经不存在了") }
        var updated = engine.subscriptions[index]
        let name = subscription.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            updated.name = name
        }
        updated.url = url
        updated.filter = filter
        updated.exclude = exclude
        updated.prefix = subscription.prefix
        updated.dialer = (dialer?.isEmpty ?? true) ? nil : dialer
        engine.subscriptions[index] = updated
        writeEngine?(engine)
        Log.info("订阅「\(updated.name)」的设置已保存")
        return nil
    }

    /// 前置代理能不能用：配置列表里的 HTTP / SOCKS5 代理、不含这个来源节点的策略组、别的来源的节点。
    func validateDialer(_ reference: String, provider: String) -> String? {
        let engine = engineConfig
        if let id = DialerReference.profileID(reference) {
            guard let profile = readConfig().profiles.first(where: { $0.id == id }) else { return L("这个代理配置已经不存在了") }
            return DialerReference.usable(profile) ? nil : L("只有 HTTP 或 SOCKS5 代理能当前置")
        }
        if CoreConfigBuilder.dialerLoops(reference, provider: provider, engine: engine) {
            return L("「%@」里有这个来源自己的节点，会绕回自己：选只用别的订阅的自动类策略组、别的订阅里的节点，或者配置列表里的代理", reference)
        }
        if engine.groups.contains(where: { $0.name == reference }) { return nil }
        if let node = nodes.first(where: { $0.name == reference }) {
            return node.provider == provider ? L("不能用这个来源自己的节点当前置") : nil
        }
        return nodes.isEmpty ? nil : L("没有叫「%@」的节点或策略组", reference)
    }

    /// 前置代理的候选：配置列表里的 HTTP / SOCKS5 代理、不会绕回的策略组、别的来源的节点。
    func dialerCandidates(for provider: String) -> [DialerCandidate] {
        let engine = engineConfig
        var result: [DialerCandidate] = []
        for profile in readConfig().profiles where DialerReference.usable(profile) {
            result.append(DialerCandidate(value: DialerReference.profile(profile.id), title: L("代理「%@」 %@", profile.name, profile.summary)))
        }
        for group in engine.groups where !CoreConfigBuilder.dialerLoops(group.name, provider: provider, engine: engine) {
            result.append(DialerCandidate(value: group.name, title: L("策略组「%@」", group.name)))
        }
        for node in nodes where node.provider != provider {
            result.append(DialerCandidate(value: node.name, title: L("节点 %@（%@）", node.name, node.subscription)))
        }
        return result
    }

    // MARK: - 手动节点

    /// 从一段文字里加节点：分享链接一行一条，或者整段 base64。返回加了几个，有问题时带上说明。
    @discardableResult
    func addManualNodes(from text: String) -> (added: Int, problem: String?) {
        let links = NodeLink.extract(text)
        guard !links.isEmpty else {
            return (0, L("没有认出节点链接：支持 ss://、ssr://、vmess://、vless://、trojan://、hysteria2://、tuic://、anytls:// 和带账号的 http:// / socks5://"))
        }
        var engine = engineConfig
        var added = 0
        for link in links where !engine.manualNodes.contains(where: { $0.link == link }) {
            engine.manualNodes.append(ManualNode(link: link))
            added += 1
        }
        guard added > 0 else { return (0, L("这些节点已经加过了")) }
        writeEngine?(engine)
        Log.info("添加了 \(added) 个手动节点")
        return (added, nil)
    }

    func removeManualNode(_ id: UUID) {
        var engine = engineConfig
        engine.manualNodes.removeAll { $0.id == id }
        writeEngine?(engine)
    }

    func setManualNode(_ id: UUID, enabled: Bool) {
        var engine = engineConfig
        guard let index = engine.manualNodes.firstIndex(where: { $0.id == id }) else { return }
        engine.manualNodes[index].enabled = enabled
        writeEngine?(engine)
    }

    /// 手动节点的前置代理；nil 表示不用。返回问题描述，成功返回 nil。
    @discardableResult
    func setManualDialer(_ reference: String?) -> String? {
        let value = reference?.trimmingCharacters(in: .whitespaces)
        if let value, !value.isEmpty, let problem = validateDialer(value, provider: ManualNode.providerName) { return problem }
        var engine = engineConfig
        engine.manualDialer = (value?.isEmpty ?? true) ? nil : value
        writeEngine?(engine)
        return nil
    }

    // MARK: - DNS、Hosts、IPv6、配置补丁

    /// 保存 DNS 设置。返回问题描述，成功返回 nil。
    @discardableResult
    func setDNS(_ dns: DNSSettings) -> String? {
        if let problem = dns.validate() { return problem }
        var engine = engineConfig
        engine.dns = dns
        writeEngine?(engine)
        Log.info(dns.enabled ? "内核 DNS：开启" : "内核 DNS：关闭，用系统的 DNS")
        return nil
    }

    /// 保存 Hosts。返回问题描述，成功返回 nil。
    @discardableResult
    func setHosts(_ hosts: [HostEntry]) -> String? {
        for entry in hosts where entry.enabled {
            if let problem = entry.validate() { return problem }
        }
        var engine = engineConfig
        engine.hosts = hosts
        writeEngine?(engine)
        return nil
    }

    func setIPv6(_ enabled: Bool) {
        var engine = engineConfig
        engine.ipv6 = enabled
        writeEngine?(engine)
    }

    /// 保存配置补丁：先检查能不能解析，内核在的话再让它检查合并后的完整配置。返回问题描述，成功返回 nil。
    func setPatch(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var engine = engineConfig
        engine.patch = trimmed
        if !trimmed.isEmpty {
            let config = readConfig()
            let composed = composeRules(engine)
            let input = CoreConfigBuilder.Input(engine: engine, secret: secret, directory: Self.directory, testURL: config.testURL, rules: composed.rules, share: shareInputs, ruleProviders: composed.providers, profiles: config.profiles, probePort: probePort)
            let built = CoreConfigBuilder.build(input)
            if let problem = built.patchProblem { return L("补丁有问题：%@", problem) }
            try? prepareDirectory()
            if let problem = await Self.testConfig(built.text) { return L("内核不认合并后的配置：%@", problem) }
            checkedPatch = (built.text, nil)
        }
        writeEngine?(engine)
        Log.info(trimmed.isEmpty ? "已清空配置补丁" : "配置补丁已保存")
        return nil
    }

    // MARK: - 收藏与排序

    func toggleFavorite(_ name: String) {
        var engine = engineConfig
        if let index = engine.favoriteNodes.firstIndex(of: name) {
            engine.favoriteNodes.remove(at: index)
        } else {
            engine.favoriteNodes.append(name)
        }
        writeEngine?(engine)
    }

    func isFavorite(_ name: String) -> Bool { engineConfig.favoriteNodes.contains(name) }

    func setNodeSort(_ sort: NodeSort) {
        var engine = engineConfig
        engine.nodeSort = sort
        writeEngine?(engine)
    }

    /// 按设置排好的节点，收藏的在最前面。
    var sortedNodes: [Node] {
        let engine = engineConfig
        return NodeQuery(sort: engine.nodeSort).apply(nodes, favorites: engine.favoriteNodes)
    }

    // MARK: - 网址检测

    /// 经节点访问用户填的网址。node 为 nil 时经当前在用的节点；指定了节点时经检测入口临时切到它，不影响正在用的。
    @discardableResult
    func checkURL(_ address: String, node: String? = nil) async -> ServiceCheckResult? {
        guard isRunning, engineConfig.wantsCore, checkingServices == nil, let url = ServiceClassifier.normalize(address) else { return nil }
        let key = node ?? ""
        checkingServices = key
        defer { checkingServices = nil }
        var port = engineConfig.mixedPort
        if let node {
            guard let api else { return nil }
            do {
                try await api.select(group: CoreConfigBuilder.probeGroup, node: node)
                port = probePort
            } catch {
                lastError = L("切换检测用的节点失败：%@", error.localizedDescription)
                return nil
            }
        }
        guard let result = await ServiceChecker.run([url], proxyPort: port).first else { return nil }
        var list = (serviceResults[key] ?? []).filter { $0.url != url }
        list.insert(result, at: 0)
        serviceResults[key] = Array(list.prefix(10))
        Log.info("网址检测（\(node ?? "当前节点")）：\(url) \(result.isAvailable ? "能打开" : "打不开")")
        return result
    }

    // MARK: - 实时日志

    /// 高级页打开时订阅内核的实时日志，关掉时退订；内核重启后自动接上。
    func subscribeLiveLog() {
        logSubscribers += 1
        guard logTask == nil else { return }
        logTask = Task { @MainActor [weak self] in
            var nextID = 0
            while !Task.isCancelled {
                guard let self else { return }
                guard let api = self.api, self.isRunning else {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                do {
                    let bytes = try await api.logBytes(level: "info")
                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let payload = json["payload"] as? String else { continue }
                        nextID += 1
                        self.appendLog(LogLine(id: nextID, date: Date(), level: (json["type"] as? String) ?? "info", text: payload))
                    }
                } catch {
                    // 内核重启或者停了：稍后重连。
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func unsubscribeLiveLog() {
        logSubscribers = max(0, logSubscribers - 1)
        if logSubscribers == 0 {
            logTask?.cancel()
            logTask = nil
        }
    }

    func clearLiveLog() {
        liveLog = []
    }

    /// 日志一行行来得很快：先攒着，每 0.3 秒刷新一次界面。
    private func appendLog(_ line: LogLine) {
        pendingLog.append(line)
        guard !logFlushScheduled else { return }
        logFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.flushLog()
        }
    }

    private func flushLog() {
        logFlushScheduled = false
        var lines = liveLog + pendingLog
        pendingLog = []
        if lines.count > Self.liveLogLimit {
            lines.removeFirst(lines.count - Self.liveLogLimit)
        }
        liveLog = lines
    }

    // MARK: - 工具

    nonisolated static func pickFreePort() -> Int {
        LocalPort.pickFree()
    }

    nonisolated static func parseDate(_ text: String?) -> Date? {
        CoreDates.parse(text)
    }

    nonisolated static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    nonisolated static func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    /// 连接持续了多久：「12 秒」「3 分钟」。
    nonisolated static func durationText(since date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return L("%@ 秒", max(0, seconds)) }
        if seconds < 3600 { return L("%@ 分钟", seconds / 60) }
        return L("%@ 小时 %@ 分", seconds / 3600, seconds % 3600 / 60)
    }
}
