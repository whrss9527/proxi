import Foundation
import SystemConfiguration

enum SystemProxyError: LocalizedError {
    case noServices
    case command(String)
    case needsAdmin(String)

    var errorDescription: String? {
        switch self {
        case .noServices: return L("没有找到可用的网络服务")
        case .command(let message): return message
        case .needsAdmin(let message): return L("修改系统代理需要管理员权限：%@", message)
        }
    }
}

/// macOS 系统代理（系统设置 → 网络 → 详细信息 → 代理）的读写。
/// 读取用 SystemConfiguration 的接口，不启动进程；写入用 networksetup 并行设置各服务、服务内按序执行，
/// 只写正在使用的服务（接口有地址的），都没有时写全部启用的服务。
/// networksetup 修改设置需要管理员账户；标准账户时用系统的授权对话框提权后再执行一次。
enum SystemProxy {
    static let networksetupPath = "/usr/sbin/networksetup"
    static let osascriptPath = "/usr/bin/osascript"

    /// 当前生效的系统代理。
    static func current() -> ProxySnapshot {
        guard let dictionary = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return ProxySnapshot()
        }
        return ProxySnapshot(dictionary: dictionary)
    }

    /// 写入代理设置，返回写了哪些网络服务。also：除了正在使用的服务，还要写的服务（关闭代理时传开启时写过的那些，
    /// 免得开启时在用、现在没在用的服务（比如拔掉的网线）一直留着代理，下次用它上网时还指向原来的代理）；已经不存在的服务跳过。
    @discardableResult
    static func apply(_ desired: DesiredProxy, also extra: [String] = []) async throws -> [String] {
        var services = NetworkServices.targetServiceNames()
        if !extra.isEmpty {
            let existing = Set(NetworkServices.all().map(\.name))
            for name in extra where existing.contains(name) && !services.contains(name) {
                services.append(name)
            }
        }
        guard !services.isEmpty else { throw SystemProxyError.noServices }
        let all = NetworkServices.all()
        let result = await SystemServiceProxy.apply(services.map { name in
            .init(id: all.first { $0.name == name }?.id ?? name, name: name, desired: desired)
        })
        if let error = result.error { throw SystemProxyError.command(error) }
        return services
    }

    static func isAdminError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("admin") || lowered.contains("privilege") || lowered.contains("not permitted")
    }
}

/// 网络服务列表（Wi-Fi、以太网……），来自 SystemConfiguration，不需要管理员权限。
enum NetworkServices {
    struct Service: Equatable {
        var name: String
        var bsdName: String?
        var enabled: Bool
        var id: String = ""
    }

    /// 当前网络位置里的服务，按系统的服务顺序。
    static func all() -> [Service] {
        guard let preferences = SCPreferencesCreate(nil, "Proxi" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            return []
        }
        let order = (SCNetworkSetGetServiceOrder(set) as? [String]) ?? []
        var byID: [String: Service] = [:]
        var unordered: [Service] = []
        for service in services {
            let name = (SCNetworkServiceGetName(service) as String?) ?? ""
            var bsdName: String?
            if let interface = SCNetworkServiceGetInterface(service) {
                bsdName = SCNetworkInterfaceGetBSDName(interface) as String?
            }
            let item = Service(name: name, bsdName: bsdName, enabled: SCNetworkServiceGetEnabled(service), id: (SCNetworkServiceGetServiceID(service) as String?) ?? "")
            if let id = SCNetworkServiceGetServiceID(service) as String? {
                byID[id] = item
            } else {
                unordered.append(item)
            }
        }
        var result: [Service] = []
        for id in order {
            if let item = byID.removeValue(forKey: id) {
                result.append(item)
            }
        }
        result += byID.values.sorted { $0.name < $1.name }
        result += unordered
        return result
    }

    /// 接口是否有 IPv4 或 IPv6 地址（正在使用）。
    static func isActive(bsdName: String) -> Bool {
        SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(bsdName)/IPv4" as CFString) != nil ||
        SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(bsdName)/IPv6" as CFString) != nil
    }

    /// 要写入代理设置的服务名：接口有地址的服务；一个都没有时（离线）写全部启用的服务，这样联网后设置也是生效的。
    static func targetServiceNames() -> [String] {
        select(services: all(), isActive: isActive(bsdName:))
    }

    static func select(services: [Service], isActive: (String) -> Bool) -> [String] {
        selectServices(services: services, isActive: isActive).map(\.name)
    }

    static func selectServices(services: [Service], isActive: (String) -> Bool) -> [Service] {
        let enabled = services.filter { $0.enabled && !$0.name.isEmpty }
        let active = enabled.filter { service in
            guard let bsdName = service.bsdName, !bsdName.isEmpty else { return false }
            return isActive(bsdName)
        }
        return active.isEmpty ? enabled : active
    }
}

/// 监听系统代理和网络的变化（别的程序改了代理、换了网络），变化时在主线程回调。
final class SystemWatcher {
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private let onChange: @MainActor () -> Void
    private let onNetworkChange: (@MainActor () -> Void)?

    init(onNetworkChange: (@MainActor () -> Void)? = nil, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        self.onNetworkChange = onNetworkChange
    }

    func start() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, keys, info in
            guard let info else { return }
            let watcher = Unmanaged<SystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let networkChanged = (keys as? [String] ?? []).contains { $0.hasSuffix("/IPv4") || $0.hasSuffix("/IPv6") || $0.hasPrefix("Setup:/Network/") }
            Task { @MainActor in
                watcher.onChange()
                if networkChanged { watcher.onNetworkChange?() }
            }
        }
        guard let store = SCDynamicStoreCreate(nil, "Proxi" as CFString, callback, &context) else {
            Log.error("无法创建 SCDynamicStore，改为定时轮询")
            return
        }
        let keys = ["State:/Network/Global/Proxies", "State:/Network/Global/IPv4", "State:/Network/Global/IPv6", "State:/Network/Global/DNS"] as CFArray
        let patterns = ["State:/Network/Interface/.*/IPv[46]", "Setup:/Network/Service/[^/]+$"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, patterns)
        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.store = store
        self.source = source
    }

    deinit {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}
