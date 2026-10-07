import Foundation

/// 从以前的版本（0.12 及以前，代理引擎还在 Proxi 里面）更新过来后，第一次启动时在这里检查和迁移：
/// - 配置和状态里代理引擎的设置（订阅、节点、规则、局域网共享……），以及数据目录里的 core/、imports/、journal.json，
///   一律原样挪到代理引擎的数据目录（engine/），一个都不删；以前的 config.json 和 state.json 另存一份备份；
/// - 以前开着的就是代理引擎那条配置时，先把代理关掉（AppState.finishLegacyMigration 做），不然系统代理指向一个没人监听的本机端口；
///   用户在「设置 → 扩展」里开启扩展、代理引擎运行起来后再把它开回来（那时代理关着才开）；
/// - 不弹扩展的说明：数据留着，扩展的说明只在扩展页里打开开关时显示；
/// - 以前版本装的后台助手：扩展开着时还要用，留着；有代理引擎的数据时以后开启扩展也要用，不弹提示（「设置 → 通用」里能移除）；
///   两样都没有时提示可以移除（要管理员密码，由用户确认）。
enum LegacyCleanup {
    /// 启动时读出来的情况。
    struct Findings: Equatable {
        /// 配置或状态里有以前版本才有的设置（代理引擎的设置）。
        var hadLegacySettings = false
        /// 代理引擎那条配置（以前的版本里自动生成，存的是 "engine": true）。
        var builtInProfiles: [Profile] = []
        /// 上次开着的就是代理引擎那条配置：要先把它设置过的代理清掉。
        var activeBuiltIn: Profile?
        /// 有用户自己的代理引擎数据：订阅、手动节点、代理引擎那条配置，或者开着局域网共享、增强模式、网关模式。
        var hasEngineData = false

        var needsMigration: Bool { hadLegacySettings || !builtInProfiles.isEmpty }
    }

    /// 现在的 config.json 和 state.json 里有的顶层键；别的键都是以前版本才有的设置。
    static let knownConfigKeys = Set(AppConfig.CodingKeys.allCases.map(\.rawValue))
    static let knownStateKeys: Set<String> = ["lastProfileID", "enabledByUs", "original", "systemServices", "syncEnabled", "noticeShown", "extension", "pendingCleanup"]
    /// 数据目录里以前版本用的子目录和文件：挪到代理引擎的数据目录。
    static let legacyDataItems = ["core", "imports", "journal.json"]

    /// 读 config.json 和 state.json 的原始内容，看有没有以前版本留下的东西。不改任何文件。
    static func inspect(configData: Data?, stateData: Data?) -> Findings {
        var findings = Findings()
        if let configData, let object = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            findings.hadLegacySettings = object["engine"] != nil
                || ((object["format"] as? Int ?? 1) < AppConfig.currentFormat && !Set(object.keys).isSubset(of: knownConfigKeys))
            if let profiles = object["profiles"] as? [Any] {
                for item in profiles where Profile.isLegacyBuiltIn(item) {
                    guard let data = try? JSONSerialization.data(withJSONObject: item),
                          let profile = try? JSONDecoder().decode(Profile.self, from: data) else { continue }
                    findings.builtInProfiles.append(profile)
                }
            }
            if let engine = object["engine"] as? [String: Any] {
                let subscriptions = (engine["subscriptions"] as? [Any]) ?? []
                let manualNodes = (engine["manualNodes"] as? [Any]) ?? []
                if !subscriptions.isEmpty || !manualNodes.isEmpty {
                    findings.hasEngineData = true
                }
            }
        }
        if !findings.builtInProfiles.isEmpty {
            findings.hasEngineData = true
        }
        if let stateData, let object = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any] {
            if !Set(object.keys).isSubset(of: knownStateKeys) {
                findings.hadLegacySettings = true
            }
            let share = ((object["share"] as? [String: Any])?["enabled"] as? Bool) ?? false
            let tun = object["tun"] as? [String: Any]
            if share || ((tun?["enabled"] as? Bool) ?? false) || ((tun?["gateway"] as? Bool) ?? false) {
                findings.hasEngineData = true
            }
            let enabled = (object["enabledByUs"] as? Bool) ?? false
            if enabled, let text = object["lastProfileID"] as? String, let id = UUID(uuidString: text) {
                findings.activeBuiltIn = findings.builtInProfiles.first { $0.id == id }
            }
        }
        return findings
    }

    /// 读本机的文件。
    static func inspect() -> Findings {
        inspect(configData: try? Data(contentsOf: Store.configURL), stateData: try? Data(contentsOf: Store.stateURL))
    }

    // MARK: - 迁移数据

    /// 把以前版本的代理引擎数据挪到代理引擎的数据目录（directory/engine/），返回做了哪些事（给日志看）。
    /// 什么都不删：config.json、state.json 原样复制一份过去（代理引擎直接读它们），另外各存一份 -0.12-backup 备份；
    /// core/、imports/、journal.json 整个挪过去，配置和操作记录里指向它们的路径跟着改。目标已经有的不覆盖。
    @discardableResult
    static func migrateEngineData(in directory: URL = Store.directory) -> [String] {
        let fm = FileManager.default
        let target = directory.appendingPathComponent("engine", isDirectory: true)
        var done: [String] = []
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            Log.error("建不了代理引擎的数据目录：\(error.localizedDescription)")
            return done
        }
        for name in legacyDataItems {
            let source = directory.appendingPathComponent(name)
            let destination = target.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.moveItem(at: source, to: destination)
                done.append(name)
            } catch {
                Log.error("挪 \(name) 失败（留在原处）：\(error.localizedDescription)")
            }
        }
        for name in ["config.json", "state.json"] {
            let source = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: source) else { continue }
            let backup = target.appendingPathComponent(name.replacingOccurrences(of: ".json", with: "-0.12-backup.json"))
            if !fm.fileExists(atPath: backup.path) {
                try? data.write(to: backup, options: .atomic)
            }
            let destination = target.appendingPathComponent(name)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            let text = relocate(String(decoding: data, as: UTF8.self), from: directory, to: target)
            do {
                try Data(text.utf8).write(to: destination, options: .atomic)
                done.append(name)
            } catch {
                Log.error("复制 \(name) 失败：\(error.localizedDescription)")
            }
        }
        let journal = target.appendingPathComponent("journal.json")
        if done.contains("journal.json"), let text = try? String(contentsOf: journal, encoding: .utf8) {
            let relocated = relocate(text, from: directory, to: target)
            if relocated != text {
                try? relocated.write(to: journal, atomically: true, encoding: .utf8)
            }
        }
        return done
    }

    /// 文字里指向 directory/imports/、directory/core/ 的路径（普通路径和 file:// 网址，JSON 里的 / 可能写成 \/）换到 target 下面。
    static func relocate(_ text: String, from directory: URL, to target: URL) -> String {
        var result = text
        for item in ["imports", "core"] {
            let oldPath = directory.appendingPathComponent(item).path + "/"
            let newPath = target.appendingPathComponent(item).path + "/"
            let oldURL = URL(fileURLWithPath: oldPath, isDirectory: true).absoluteString
            let newURL = URL(fileURLWithPath: newPath, isDirectory: true).absoluteString
            for (old, new) in [(oldURL, newURL), (oldPath, newPath)] {
                result = result.replacingOccurrences(of: old, with: new)
                result = result.replacingOccurrences(of: old.replacingOccurrences(of: "/", with: "\\/"), with: new.replacingOccurrences(of: "/", with: "\\/"))
            }
        }
        return result
    }

    // MARK: - 以前版本的后台助手

    /// 这些名字是以前版本定下的（代理引擎现在装的也是这个）。
    enum Helper {
        static let label = "com.whrss9527.proxyswitch.helper"
        static let toolsDirectory = "/Library/PrivilegedHelperTools"
        static var executable: String { "\(toolsDirectory)/\(label)" }
        /// 助手目录里以前版本放的文件都以这个开头。
        static var filePrefix: String { "\(toolsDirectory)/com.whrss9527.proxyswitch." }
        static var plist: String { "/Library/LaunchDaemons/\(label).plist" }
        static var socket: String { "/var/run/\(label).sock" }
        static let dataDirectory = "/Library/Application Support/ProxySwitch"
        static let log = "/Library/Logs/ProxySwitch-helper.log"
    }

    /// 以前版本装的后台助手还在不在。
    static var helperInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Helper.plist) || fm.fileExists(atPath: Helper.executable)
    }

    /// 以 root 运行、删掉后台助手的命令：先让 launchd 停掉它（它停下时会自己收尾），再删文件。
    static var helperRemovalScript: String {
        let quote = Shell.shellQuote
        let firewall = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        return [
            "/bin/launchctl bootout system/\(Helper.label) >/dev/null 2>&1",
            "for f in \(quote(Helper.filePrefix))*; do [ -e \"$f\" ] && \(firewall) --remove \"$f\" >/dev/null 2>&1; rm -f \"$f\"; done",
            "rm -f \(quote(Helper.plist)) \(quote(Helper.socket)) \(quote(Helper.log))",
            "rm -rf \(quote(Helper.dataDirectory))",
            "true",
        ].joined(separator: "; ")
    }

    /// 删掉后台助手：系统会请用户输入一次管理员密码。
    static func removeHelper() async throws {
        try await CommandLineInstaller.runAsAdmin(helperRemovalScript, failure: L("后台助手没有移除"))
        Log.info("以前版本的后台助手已移除")
    }
}
