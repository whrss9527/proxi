import AppKit
import Combine
import CoreLocation
import CoreWLAN
import SystemConfiguration

/// 按网络自动切换：网络一变就看现在连的是哪个 Wi‑Fi、哪个路由器，按「自动化」里的规则开关代理或者切换配置。
/// 同一个网络只切一次，之后手动改了不会被改回去；换了网络才会再按规则切。只在主线程上用。
@MainActor
final class NetworkAutomation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var identity = NetworkIdentity()
    /// 最近一次按规则切换。
    @Published private(set) var lastSwitch: (summary: String, date: Date)?
    @Published private(set) var locationStatus: CLAuthorizationStatus = .notDetermined

    private weak var state: AppState?
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private var locationManager: CLLocationManager?
    private var pending: Task<Void, Never>?
    /// 上次按哪条规则在哪个网络上切换过：同一个网络不重复切。
    private var lastKey: String?
    private var cancellables = Set<AnyCancellable>()

    private let identityResolver: NetworkIdentityResolver

    init(identityResolver: NetworkIdentityResolver? = nil) {
        self.identityResolver = identityResolver ?? NetworkIdentityResolver(
            read: { await NetworkAutomation.readIdentity() },
            probe: { ip in
                // macOS ping 的 -W 单位是毫秒；只唤起 ARP，不要求网关回答 ICMP。
                _ = try? await Shell.run("/sbin/ping", ["-c", "1", "-W", "1000", ip], timeout: 2)
            }
        )
        super.init()
    }

    func start(state: AppState) {
        self.state = state
        let manager = CLLocationManager()
        manager.delegate = self
        locationManager = manager
        locationStatus = manager.authorizationStatus
        watchNetwork()
        // 规则改了马上按现在的网络再看一次（只看规则和总开关：改控制接口的权限不该把手动关掉的代理又开起来）。
        state.$config
            .map { RuleInputs(switching: $0.automation.networkSwitching, rules: $0.automation.networkRules) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.lastKey = nil
                    self?.schedule(delay: 0.3)
                }
            }
            .store(in: &cancellables)
        // 一键更新、换界面语言后重新启动的：接着用上一个实例的记录，同一个网络不再按规则切一次（手动改过的不会被改回去）。
        lastKey = Self.takeRelaunchKey()
        schedule(delay: 3)
    }

    // MARK: - 重新启动时交接

    private static let relaunchDefaultsKey = "networkAutomation.relaunchKey"

    /// 重新启动（一键更新、换界面语言）前调用：记下在这个网络上已经按规则切过了，交给新的实例。
    func saveForRelaunch() {
        guard let lastKey else { return }
        let handoff: [String: Any] = ["key": lastKey, "at": Date().timeIntervalSince1970]
        UserDefaults.standard.set(handoff, forKey: Self.relaunchDefaultsKey)
    }

    /// 新的实例启动时取一次：两分钟内存的才算，取了就删（正常退出再打开的不受影响）。
    private static func takeRelaunchKey() -> String? {
        let defaults = UserDefaults.standard
        guard let saved = defaults.dictionary(forKey: relaunchDefaultsKey) else { return nil }
        defaults.removeObject(forKey: relaunchDefaultsKey)
        guard let at = saved["at"] as? Double, Date().timeIntervalSince1970 - at < 120 else { return nil }
        return saved["key"] as? String
    }

    /// 读 Wi‑Fi 名字要定位权限（macOS 14 起）。
    var canReadWiFiName: Bool {
        switch locationStatus {
        case .notDetermined, .restricted, .denied: return false
        default: return true
        }
    }

    func requestLocation() {
        guard let locationManager else { return }
        if locationStatus == .denied || locationStatus == .restricted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
            return
        }
        locationManager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationStatus = status
            self.schedule(delay: 0.5)
        }
    }

    // MARK: - 监听网络

    private func watchNetwork() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let automation = Unmanaged<NetworkAutomation>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in automation.schedule(delay: 2) }
        }
        guard let store = SCDynamicStoreCreate(nil, "Proxi.network" as CFString, callback, &context) else { return }
        let keys = ["State:/Network/Global/IPv4"] as CFArray
        // Wi‑Fi 换了网络（SSID）时各个网卡的 AirPort 状态会变。
        let patterns = ["State:/Network/Interface/.*/AirPort", "State:/Network/Interface/.*/Link"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, patterns)
        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.store = store
        self.source = source
    }

    /// 网络变化常常一连串地来：等它稳定一会儿再看。
    func schedule(delay: TimeInterval) {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard !Task.isCancelled else { return }
            await self?.evaluate()
        }
    }

    /// 现在连着的网络。
    func currentIdentity() async -> NetworkIdentity {
        await identityResolver.resolve()
    }

    private static func readIdentity() async -> NetworkIdentity {
        var identity = NetworkIdentity()
        if let value = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            identity.routerIP = value["Router"] as? String
            identity.interface = value["PrimaryInterface"] as? String
        }
        if let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty {
            identity.ssid = ssid
        }
        if let router = identity.routerIP {
            identity.routerMAC = await Self.macAddress(of: router)
        }
        return identity
    }

    /// 路由器的 MAC 地址（从 ARP 表里查）。
    nonisolated static func macAddress(of ip: String) async -> String? {
        guard Self.isIPv4Address(ip), let result = try? await Shell.run("/usr/sbin/arp", ["-n", ip], timeout: 3) else { return nil }
        return parseARP(result.output)
    }

    /// arp -n 的输出：? (192.168.1.1) at a0:b1:c2:d3:e4:f5 on en0 ifscope [ethernet]
    nonisolated static func parseARP(_ output: String) -> String? {
        guard let range = output.range(of: " at ") else { return nil }
        let rest = output[range.upperBound...]
        let mac = rest.prefix { !$0.isWhitespace }
        guard mac.contains(":"), mac != "(incomplete)" else { return nil }
        return NetworkRule.normalizeMAC(String(mac))
    }

    // MARK: - 按规则切换

    func evaluate() async {
        guard let state else { return }
        let identity = await currentIdentity()
        guard !Task.isCancelled else { return }
        if identity != self.identity {
            self.identity = identity
        }
        let automation = state.config.automation
        guard automation.networkSwitching, let rule = NetworkRule.firstMatch(automation.networkRules, identity: identity) else {
            lastKey = nil
            return
        }
        let key = "\(rule.id)|\(identity.ssid ?? "")|\(identity.routerIP ?? "")|\(identity.routerMAC ?? "")"
        guard identity.awaitingRouterMAC || key != lastKey else { return }
        // 正在开关代理（比如等代理引擎的内核起来、管理员密码的对话框开着）时先不切，过一会儿再看：
        // 这时开关会被忽略，记下「切过了」的话这个网络就再也不切了。
        if state.busy {
            schedule(delay: 3)
            return
        }
        lastKey = identity.awaitingRouterMAC ? nil : key
        apply(rule, identity: identity, state: state)
    }

    private func apply(_ rule: NetworkRule, identity: NetworkIdentity, state: AppState) {
        var done: String?
        switch rule.action {
        case .profile(let id):
            guard let profile = state.config.profile(id: id) else {
                Log.error("按网络切换：规则要开的配置已经不存在了")
                return
            }
            if case .on(let current) = state.status, current.id == profile.id { break }
            state.turnOn(profile)
            // 没有开始（比如钥匙串里没有密码、用户取消了输入）就不说切换了。
            guard state.busy else { return }
            done = L("开启「%@」", profile.name)
        case .off:
            if case .on = state.status {
                state.turnOff()
                done = L("关闭代理")
            }
        }
        guard let done else { return }
        let summary = "\(rule.match.title) → \(done)"
        lastSwitch = (summary, Date())
        Log.info("按网络自动切换：\(identity.summary)，\(summary)")
        state.notify(title: L("已按网络自动切换"), body: summary, problem: false)
    }

    /// 用现在的网络做一条规则的条件：有 Wi‑Fi 名字就用它，否则用路由器的 MAC（没有就用 IP）。
    var currentMatch: NetworkRule.Match? {
        if let ssid = identity.ssid { return .ssid(ssid) }
        if let mac = identity.routerMAC { return .router(mac) }
        if let ip = identity.routerIP { return .router(ip) }
        return nil
    }

    /// 影响按网络切换的设置。
    private struct RuleInputs: Equatable {
        var switching: Bool
        var rules: [NetworkRule]
    }

    /// 是不是一个 IPv4 地址（只有这种才去查路由器的 MAC）。
    nonisolated static func isIPv4Address(_ text: String) -> Bool {
        var address = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }
}
