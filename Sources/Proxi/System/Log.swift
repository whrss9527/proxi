import Foundation
import os

/// 日志写到系统的统一日志（Console.app 里按 subsystem 过滤），同时追加到 Application Support 里的 proxi.log。
enum Log {
    private static let logger = Logger(subsystem: "com.whrss9527.proxyswitch", category: "app")
    private static let queue = DispatchQueue(label: "com.whrss9527.proxyswitch.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static let fileName = "proxi.log"
    static var fileURL: URL { Store.directory.appendingPathComponent(fileName) }

    static func info(_ message: String) {
        logger.info("\(Redact.secrets(message), privacy: .public)")
        append("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(Redact.secrets(message), privacy: .public)")
        append("ERROR", message)
    }

    private static func append(_ level: String, _ message: String) {
        let message = Redact.secrets(message)
        let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attributes[.size] as? Int, size > 1 << 20 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 等排队的日志都写进文件（马上要退出时用）。
    static func flush() {
        queue.sync {}
    }

    /// 日志文件最后几行，诊断页显示用。
    static func tail(lines maxLines: Int = 200) -> String {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
        let lines = content.split(separator: "\n").suffix(maxLines)
        return lines.joined(separator: "\n")
    }
}

/// 配置和状态文件：~/Library/Application Support/Proxi/。
enum Store {
    static let folderName = "Proxi"
    /// 改名前的数据目录。
    static let legacyFolderName = "ProxySwitch"
    static let legacyLogName = "proxyswitch.log"

    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    static var directory: URL { base.appendingPathComponent(folderName, isDirectory: true) }
    static var legacyDirectory: URL { base.appendingPathComponent(legacyFolderName, isDirectory: true) }

    static var configURL: URL { directory.appendingPathComponent("config.json") }
    static var stateURL: URL { directory.appendingPathComponent("state.json") }

    static func loadConfig() -> AppConfig? {
        load(AppConfig.self, from: configURL)
    }

    static func loadState() -> PersistedState {
        load(PersistedState.self, from: stateURL) ?? PersistedState()
    }

    static func save(_ config: AppConfig) {
        save(config, to: configURL)
    }

    static func save(_ state: PersistedState) {
        save(state, to: stateURL)
    }

    /// 写外部代理设置之前，必须确认恢复记录已经落盘；失败交给调用方，不能继续覆盖原设置。
    static func saveRestorationState(_ state: PersistedState) throws {
        try write(state, to: stateURL)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // 读不了的文件（不是 JSON、被截断了）先另存一份，不然下次保存时就被默认设置盖掉了。
            let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            Log.error("读取 \(url.lastPathComponent) 失败，原来的文件另存为 \(backup.lastPathComponent)：\(error)")
            return nil
        }
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try write(value, to: url)
        } catch {
            Log.error("保存 \(url.lastPathComponent) 失败：\(error)")
        }
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

// MARK: - 改名前的数据目录

extension Store {
    /// 改名后第一次启动：把旧的数据目录（ProxySwitch）整个挪成新的，启动时最先做（在写任何日志之前）。
    /// 新目录已经有了就不动（比如新旧两个版本都运行过）。返回有没有挪。
    @discardableResult
    static func migrateLegacyDirectory() -> Bool {
        migrate(from: legacyDirectory, to: directory)
    }

    /// 挪目录，日志改名。
    static func migrate(from legacy: URL, to current: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return false }
        do {
            try fm.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: legacy, to: current)
        } catch {
            return false
        }
        let oldLog = current.appendingPathComponent(legacyLogName)
        let newLog = current.appendingPathComponent(Log.fileName)
        if fm.fileExists(atPath: oldLog.path) && !fm.fileExists(atPath: newLog.path) {
            try? fm.moveItem(at: oldLog, to: newLog)
        }
        return true
    }

    /// 目录的 file:// 网址，以 / 结尾。
    static func directoryURLString(_ directory: URL) -> String {
        let text = URL(fileURLWithPath: directory.path, isDirectory: true).absoluteString
        return text.hasSuffix("/") ? text : text + "/"
    }

    /// 文字里指向旧目录的路径（普通路径和 file:// 网址，JSON 里的 / 可能写成 \/）换成新目录。
    static func relocatePaths(in text: String, from legacy: URL, to current: URL) -> String {
        var result = text
        let pairs = [(legacy.path + "/", current.path + "/"), (directoryURLString(legacy), directoryURLString(current))]
        for (old, new) in pairs {
            result = result.replacingOccurrences(of: old, with: new)
            result = result.replacingOccurrences(of: old.replacingOccurrences(of: "/", with: "\\/"), with: new.replacingOccurrences(of: "/", with: "\\/"))
        }
        return result
    }
}
