import Foundation

/// 同步到 iCloud 的内容：配置，加上是哪台机器、什么时候写的。
struct SyncedConfig: Codable, Equatable {
    static let currentFormat = AppConfig.currentFormat

    var format: Int = SyncedConfig.currentFormat
    var updatedAt: Date
    var device: String
    var config: AppConfig

    init(updatedAt: Date, device: String, config: AppConfig) {
        self.updatedAt = updatedAt
        self.device = device
        self.config = config
    }

    private enum CodingKeys: String, CodingKey {
        case format, updatedAt, device, config
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? 1
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        device = try container.decodeIfPresent(String.self, forKey: .device) ?? L("未知设备")
        config = try container.decode(AppConfig.self, forKey: .config)
    }
}

enum CloudFileError: LocalizedError {
    case unavailable
    case newerFormat(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: return L("iCloud 云盘没有开启")
        case .newerFormat(let format): return L("iCloud 配置格式 %@ 比这台 Mac 支持的版本更新，请更新 Proxi。", format)
        }
    }
}

/// iCloud 云盘里的同步文件：~/Library/Mobile Documents/com~apple~CloudDocs/Proxi/config.json。
/// 用 iCloud 云盘里的普通文件夹而不是应用自己的 iCloud 容器，是因为没有开发者签名就拿不到 iCloud 的 entitlement。
enum CloudFile {
    /// 测试用：把同步文件夹指到别处。
    static let overrideVariable = "PROXI_SYNC_DIR"
    static let folderName = "Proxi"
    /// 改名前的同步文件夹。
    static let legacyFolderName = "ProxySwitch"
    static let fileName = "config.json"

    /// iCloud 云盘的根目录；没开 iCloud 云盘时是 nil。
    static func driveURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let url = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// 同步文件夹：iCloud 云盘/Proxi。
    static var folderURL: URL? {
        if let override = ProcessInfo.processInfo.environment[overrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return driveURL()?.appendingPathComponent(folderName, isDirectory: true)
    }

    /// 改名后：旧文件夹（iCloud 云盘/ProxySwitch）里的同步文件比新文件夹里的新、或者新文件夹里还没有时，复制一份过来。
    /// 还没更新的 Mac 照旧写旧文件夹，它们的改动这样也能到已经更新的 Mac 上。
    /// drive 是 iCloud 云盘的根目录。复制了返回 true。
    @discardableResult
    static func migrateLegacyFolder(drive: URL? = nil) -> Bool {
        guard ProcessInfo.processInfo.environment[overrideVariable] == nil, let drive = drive ?? driveURL() else { return false }
        let fm = FileManager.default
        let folder = drive.appendingPathComponent(folderName, isDirectory: true)
        let target = folder.appendingPathComponent(fileName)
        // 别的 Mac 已经写过新文件、只是这台还没下载下来（只有占位文件）时不动。
        guard !fm.fileExists(atPath: folder.appendingPathComponent(".\(fileName).icloud").path) else { return false }
        let legacy = drive.appendingPathComponent(legacyFolderName, isDirectory: true).appendingPathComponent(fileName)
        guard let synced = (try? read(at: legacy)) ?? nil else { return false }
        if fm.fileExists(atPath: target.path) {
            guard let current = (try? read(at: target)) ?? nil, synced.updatedAt > current.updatedAt else { return false }
        }
        do {
            try write(synced, to: target)
            return true
        } catch {
            return false
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private struct FormatHeader: Decodable { var format: Int? }
    private struct ConfigHeader: Decodable { var config: FormatHeader? }

    /// 先读版本头，不解释更新版本的内容；写入协调区内也再次检查，防止并发覆盖。
    static func requireSupportedFormat(_ data: Data) throws {
        let format = try JSONDecoder().decode(FormatHeader.self, from: data).format ?? 1
        guard format <= SyncedConfig.currentFormat else { throw CloudFileError.newerFormat(format) }
        let configFormat = try JSONDecoder().decode(ConfigHeader.self, from: data).config?.format ?? 1
        guard configFormat <= AppConfig.currentFormat else { throw CloudFileError.newerFormat(configFormat) }
    }

    /// 读同步文件；不存在返回 nil。还没从 iCloud 下载下来的文件会先下载。
    static func read(at url: URL) throws -> SyncedConfig? {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var coordinationError: NSError?
        var result: Result<SyncedConfig?, Error> = .success(nil)
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result {
                guard FileManager.default.fileExists(atPath: readURL.path) else { return nil }
                let data = try Data(contentsOf: readURL)
                try requireSupportedFormat(data)
                return try decoder.decode(SyncedConfig.self, from: data)
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        return try result.get()
    }

    static func write(_ synced: SyncedConfig, to url: URL) throws {
        guard synced.format <= SyncedConfig.currentFormat, synced.config.format <= AppConfig.currentFormat else {
            throw CloudFileError.newerFormat(max(synced.format, synced.config.format))
        }
        let data = try encoder.encode(synced)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            do {
                if FileManager.default.fileExists(atPath: writeURL.path) {
                    try requireSupportedFormat(Data(contentsOf: writeURL))
                }
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let writeError {
            throw writeError
        }
    }

    /// 两台机器同时改过时 iCloud 会留下冲突版本：所有版本里 updatedAt 最新的胜出，写回去并清掉其他版本。
    /// 返回胜出的内容；没有冲突返回 nil。
    static func resolveConflicts(at url: URL) throws -> SyncedConfig? {
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !conflicts.isEmpty else { return nil }
        var candidates: [SyncedConfig] = []
        if let current = try read(at: url) {
            candidates.append(current)
        }
        for version in conflicts {
            let data = try Data(contentsOf: version.url)
            try requireSupportedFormat(data)
            candidates.append(try decoder.decode(SyncedConfig.self, from: data))
        }
        let winner = newest(candidates)
        if let winner { try write(winner, to: url) }
        for version in conflicts {
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        Log.info("iCloud 同步：解决了 \(conflicts.count) 个冲突版本，采用来自 \(winner?.device ?? "?") 的改动")
        return winner
    }

    static func newest(_ candidates: [SyncedConfig]) -> SyncedConfig? {
        candidates.max { $0.updatedAt < $1.updatedAt }
    }

    /// 文件的修改时间和大小，用来判断有没有变化。
    static func stamp(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? Int) ?? 0
        return "\(date):\(size)"
    }
}

extension AppConfig {
    /// 合并：以 iCloud 的配置列表为准，本机独有的追加在后面（按 id，或者同名且地址相同视为同一个）；其他设置保留本机的。
    func merging(cloud: AppConfig) -> AppConfig {
        var merged = self
        var profiles = cloud.profiles
        for profile in self.profiles {
            let duplicate = profiles.contains { existing in
                existing.id == profile.id || (existing.name == profile.name && existing.kind == profile.kind && existing.summary == profile.summary)
            }
            if !duplicate {
                profiles.append(profile)
            }
        }
        merged.profiles = profiles
        merged.retainUnknownFields(from: cloud)
        return merged
    }
}
