import Foundation

/// 左键点击菜单栏图标的动作。
enum ClickAction: String, Codable, CaseIterable, Identifiable {
    case panel
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .panel: return L("打开面板")
        case .toggle: return L("直接开关代理")
        }
    }
}

/// 关闭代理时系统代理怎么处理。
enum OffMode: String, Codable, CaseIterable, Identifiable {
    case direct
    case restore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return L("直接连接")
        case .restore: return L("恢复开启前的设置")
        }
    }
}

enum NotifyLevel: String, Codable, CaseIterable, Identifiable {
    case all
    case problems
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L("全部显示")
        case .problems: return L("只显示问题")
        case .none: return L("不显示")
        }
    }
}

/// 全局快捷键：Carbon 的键码和修饰键位，display 是显示用的文字（⌃⌥P）。
struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    /// 默认 ⌃⌥P（P 的 Carbon 键码 0x23）。
    static let defaultToggle = HotkeyBinding(keyCode: 0x23, modifiers: KeyNames.controlKey | KeyNames.optionKey, display: "⌃⌥P")
}

/// 菜单栏图标旁边的实时网速。
enum SpeedDisplay: String, Codable, CaseIterable, Identifiable {
    case none
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return L("不显示")
        case .system: return L("系统网络总速度")
        }
    }
}

/// 网速显示在菜单栏图标的哪一边。
enum SpeedSide: String, Codable, CaseIterable, Identifiable {
    case left
    case right
    /// 代理关着时只显示网速；开启后开关出现在网速左边。
    case speedOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return L("图标左边")
        case .right: return L("图标右边")
        case .speedOnly: return L("关代理时只显示网速")
        }
    }
}

struct AppConfig: Codable, Equatable {
    static let currentFormat = 2
    private(set) var format = currentFormat
    private var preserved = ConfigPreservation()
    /// 测速默认访问的地址：苹果用来检测网络连通的页面，返回很小，哪里都能访问。
    static let defaultTestURL = "https://www.apple.com/library/test/success.html"
    /// 以前版本的默认测速地址；还是它时换成新的默认值。
    static let legacyTestURLs = ["https://cp.cloudflare.com/generate_204", "http://cp.cloudflare.com/generate_204"]

    var profiles: [Profile] = []
    var clickAction: ClickAction = .panel
    var toggleHotkey: HotkeyBinding? = HotkeyBinding.defaultToggle
    var offMode: OffMode = .direct
    var notifyLevel: NotifyLevel = .all
    var healthCheck: Bool = true
    var disableOnExit: Bool = false
    var testURL: String = AppConfig.defaultTestURL
    var autoCheckUpdates: Bool = true
    var speedDisplay: SpeedDisplay = .system
    /// 网速在图标的左边还是右边；默认在左边，开关在右边。
    var speedSide: SpeedSide = .left
    /// 网速文字跟着代理状态变色：开着时用开关的颜色，关着时是普通的菜单栏文字颜色。
    var speedColorFollowsStatus: Bool = true
    /// 自动化：本机控制接口的权限、按网络自动切换。
    var automation = AutomationConfig()

    init() {}

    enum CodingKeys: String, CodingKey, CaseIterable {
        case format, profiles, clickAction, toggleHotkey, offMode, notifyLevel, healthCheck, disableOnExit, testURL, autoCheckUpdates, speedDisplay, speedSide, speedColorFollowsStatus, automation
    }

    /// 每一项单独容错：哪一项读不出来（新版本加的取值、手改坏了）就用默认值，不让整个配置读失败、所有配置都没了。
    /// 配置列表一条条读，读不出来的那条跳过。以前版本里的其他设置（已经去掉的功能）直接忽略。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = max(Self.currentFormat, (try? container.decodeIfPresent(Int.self, forKey: .format)) ?? 1)
        // 代理引擎那条配置不从文件里读（以前的版本写进去过）：扩展开着时由 ExtensionManager 加回来。
        profiles = ((try? container.decodeIfPresent(LossyArray<Profile>.self, forKey: .profiles))?.elements ?? []).filter { !$0.engine }
        clickAction = (try? container.decodeIfPresent(ClickAction.self, forKey: .clickAction)) ?? .panel
        if container.contains(.toggleHotkey) {
            toggleHotkey = try? container.decodeIfPresent(HotkeyBinding.self, forKey: .toggleHotkey)
        } else {
            toggleHotkey = HotkeyBinding.defaultToggle
        }
        offMode = (try? container.decodeIfPresent(OffMode.self, forKey: .offMode)) ?? .direct
        notifyLevel = (try? container.decodeIfPresent(NotifyLevel.self, forKey: .notifyLevel)) ?? .all
        healthCheck = (try? container.decodeIfPresent(Bool.self, forKey: .healthCheck)) ?? true
        disableOnExit = (try? container.decodeIfPresent(Bool.self, forKey: .disableOnExit)) ?? false
        testURL = (try? container.decodeIfPresent(String.self, forKey: .testURL)) ?? AppConfig.defaultTestURL
        if AppConfig.legacyTestURLs.contains(testURL) {
            testURL = AppConfig.defaultTestURL
        }
        autoCheckUpdates = (try? container.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates)) ?? true
        speedDisplay = (try? container.decodeIfPresent(SpeedDisplay.self, forKey: .speedDisplay)) ?? .system
        speedSide = (try? container.decodeIfPresent(SpeedSide.self, forKey: .speedSide)) ?? .left
        speedColorFollowsStatus = (try? container.decodeIfPresent(Bool.self, forKey: .speedColorFollowsStatus)) ?? true
        automation = (try? container.decodeIfPresent(AutomationConfig.self, forKey: .automation)) ?? AutomationConfig()
        if let original = try? ConfigJSON(from: decoder),
           let knownData = try? JSONEncoder().encode(Known(config: self)),
           let known = try? JSONDecoder().decode(ConfigJSON.self, from: knownData) {
            preserved = ConfigPreservation(original: original.removingLegacySettings(profiles: profiles), known: known)
        }
    }

    /// 合并时其他设置以本机为准，配置列表以云端为准；两边未知字段均保留。
    mutating func retainUnknownFields(from cloud: AppConfig) {
        let profiles = cloud.preserved.children["profiles"]?.combining(with: preserved.children["profiles"] ?? ConfigPreservation())
            ?? preserved.children["profiles"]
        preserved = preserved.combining(with: cloud.preserved)
        preserved.children["profiles"] = profiles
        format = max(format, cloud.format)
    }

    private struct Known: Encodable {
        var config: AppConfig
        func encode(to encoder: Encoder) throws { try config.encodeKnown(to: encoder) }
    }

    func encode(to encoder: Encoder) throws {
        if preserved.isEmpty { try encodeKnown(to: encoder); return }
        let known = try JSONDecoder().decode(ConfigJSON.self, from: JSONEncoder().encode(Known(config: self)))
        try preserved.merging(into: known).encode(to: encoder)
    }

    private func encodeKnown(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        // 代理引擎那条配置只在运行时存在，不写进文件，也就不会经 iCloud 同步到别的 Mac。
        try container.encode(profiles.filter { !$0.engine }, forKey: .profiles)
        try container.encode(clickAction, forKey: .clickAction)
        // 明确写出 null，表示用户关掉了快捷键（缺少这个键时用默认值）。
        try container.encode(toggleHotkey, forKey: .toggleHotkey)
        try container.encode(offMode, forKey: .offMode)
        try container.encode(notifyLevel, forKey: .notifyLevel)
        try container.encode(healthCheck, forKey: .healthCheck)
        try container.encode(disableOnExit, forKey: .disableOnExit)
        try container.encode(testURL, forKey: .testURL)
        try container.encode(autoCheckUpdates, forKey: .autoCheckUpdates)
        try container.encode(speedDisplay, forKey: .speedDisplay)
        try container.encode(speedSide, forKey: .speedSide)
        try container.encode(speedColorFollowsStatus, forKey: .speedColorFollowsStatus)
        try container.encode(automation, forKey: .automation)
    }

    func profile(id: UUID?) -> Profile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }
}

/// 一个个元素地读的数组：读不出来的元素跳过，不让整个数组（和外面的整个配置）读失败。
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []

    /// 什么都接受的占位：读失败的元素要用它跳过去，不然解码器停在原地。
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
    }
}

/// 运行状态：上次使用的配置、是否由本程序开启、开启前的系统代理快照（关闭时恢复用）。
struct PersistedState: Codable, Equatable {
    var lastProfileID: UUID?
    var enabledByUs: Bool = false
    /// 本次开启实际写成功的范围；nil 表示旧版记录，按上次配置迁移。
    var appliedTargets: [ProxyTarget]?
    var original: ProxySnapshot?
    /// Git、npm 和 launchd 的开启前设置；含密码的内容只在本机钥匙串里。
    var originalScopes = OriginalProxySettings()
    /// 开启时写过系统代理的网络服务：关闭时这些也一起写，哪怕那时候没在用（比如开启时插着网线、关闭时拔掉了）。
    var systemServices: [String] = []
    /// iCloud 同步的开关是本机的，不跟着配置同步。
    var syncEnabled: Bool = false
    /// 已经显示过从以前版本更新过来的提示（后台助手）。
    var noticeShown: Bool = false
    /// 可选扩展「代理引擎」：开没开、同意说明的版本和时间（本机的，不同步）。
    var extensionState = ExtensionState()
    /// 退出时没清理完的代理设置（管理员密码没输完、命令出错或者超时）：下次启动时接着清理。
    var pendingCleanup: PendingCleanup?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case lastProfileID, enabledByUs, original, systemServices, syncEnabled, noticeShown
        case extensionState = "extension"
        case pendingCleanup, appliedTargets, originalScopes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 每一项单独容错：哪一项读不出来都不影响别的。
        lastProfileID = try? container.decodeIfPresent(UUID.self, forKey: .lastProfileID)
        enabledByUs = (try? container.decodeIfPresent(Bool.self, forKey: .enabledByUs)) ?? false
        if let names = try? container.decodeIfPresent([String].self, forKey: .appliedTargets) {
            appliedTargets = names.compactMap(ProxyTarget.init(rawValue:))
        }
        original = try? container.decodeIfPresent(ProxySnapshot.self, forKey: .original)
        do {
            originalScopes = try container.decodeIfPresent(OriginalProxySettings.self, forKey: .originalScopes) ?? OriginalProxySettings()
        } catch {
            // 损坏的恢复记录不能按“没有原值”处理，否则关闭时会直接删除用户设置。
            for target in [ProxyTarget.environment, .git, .npm] {
                originalScopes[target] = ProxyScopeSnapshot(values: [:], unreadable: true)
            }
        }
        systemServices = (try? container.decodeIfPresent([String].self, forKey: .systemServices)) ?? []
        syncEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .syncEnabled)) ?? false
        noticeShown = (try? container.decodeIfPresent(Bool.self, forKey: .noticeShown)) ?? false
        extensionState = (try? container.decodeIfPresent(ExtensionState.self, forKey: .extensionState)) ?? ExtensionState()
        pendingCleanup = try? container.decodeIfPresent(PendingCleanup.self, forKey: .pendingCleanup)
    }
}

/// 退出时没清理完的代理设置，下次启动时接着清理（见 AppState.handleExit、resumePendingCleanup）。
struct PendingCleanup: Codable, Equatable {
    /// 是哪个配置设的，告诉用户时用。
    var profileName: String
    var targets: [ProxyTarget]

    init(profileName: String, targets: [ProxyTarget]) {
        self.profileName = profileName
        self.targets = targets
    }

    private enum CodingKeys: String, CodingKey {
        case profileName, targets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileName = (try? container.decodeIfPresent(String.self, forKey: .profileName)) ?? ""
        // 认不出的项（以后的版本加的）跳过。
        let names = (try? container.decodeIfPresent([String].self, forKey: .targets)) ?? []
        targets = names.compactMap(ProxyTarget.init(rawValue:))
    }
}
