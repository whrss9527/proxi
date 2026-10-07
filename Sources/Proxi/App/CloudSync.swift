import AppKit
import Combine

/// iCloud 同步：开关、首次开启时的取舍、监听云端文件、把本机改动写上去。只在主线程上用。
@MainActor
final class CloudSync: ObservableObject {
    enum Status: Equatable {
        case off
        /// iCloud 云盘没开。
        case unavailable
        case syncing
        /// 上次同步的时间和来源设备（可能是本机）。
        case synced(Date, String)
        case error(String)
    }

    enum Choice {
        case useCloud
        case useLocal
        case merge
    }

    @Published private(set) var enabled = false
    @Published private(set) var status: Status = .off
    /// 首次开启时 iCloud 里已经有不一样的配置，等用户选择怎么办。
    @Published var pending: SyncedConfig?

    /// 本机当前的配置。
    var currentConfig: () -> AppConfig = { AppConfig() }
    /// 把来自 iCloud 的配置应用到本机。
    var applyRemote: ((AppConfig) -> Void)?
    /// 开关变化了，需要记下来。
    var onEnabledChanged: ((Bool) -> Void)?

    private let folderOverride: URL?
    private var lastSynced: AppConfig?
    private var lastStamp: String?
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var pushTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?

    init(folder: URL? = nil) {
        folderOverride = folder
    }

    var folderURL: URL? { folderOverride ?? CloudFile.folderURL }
    var fileURL: URL? { folderURL?.appendingPathComponent(CloudFile.fileName) }
    var available: Bool { folderURL != nil }

    // MARK: - 开关

    /// 启动时按记录的开关恢复。
    func start(enabled: Bool) {
        guard enabled else { return }
        guard available else {
            self.enabled = true
            status = .unavailable
            return
        }
        self.enabled = true
        status = .syncing
        startWatching()
        pullTask = Task { @MainActor [weak self] in
            await self?.migrateLegacyFolder()
            await self?.pull()
        }
    }

    /// 改名前的同步文件夹里的配置更新（或者新文件夹里还没有）时复制过来（测试时指定了文件夹就不动）。
    /// 读 iCloud 里的文件可能要等下载，不在主线程上做。
    private func migrateLegacyFolder() async {
        guard folderOverride == nil else { return }
        let copied = await Task.detached(priority: .utility) { CloudFile.migrateLegacyFolder() }.value
        if copied {
            Log.info("iCloud 同步：把 iCloud 云盘/\(CloudFile.legacyFolderName) 里的配置复制到了 \(CloudFile.folderName)")
        }
    }

    /// 用户打开开关：iCloud 里已有不同的配置时先问用户，否则直接开始。
    func enable() async {
        guard !enabled else { return }
        guard available else {
            status = .unavailable
            return
        }
        status = .syncing
        await migrateLegacyFolder()
        do {
            let local = currentConfig()
            if let remote = try await readCloud(), remote.config != local, !remote.config.profiles.isEmpty {
                pending = remote
                status = .off
                return
            }
            // 云端没有文件、内容一样或者是空的：直接把本机的写上去。
            await finishEnable(config: local, push: true)
        } catch {
            status = .error(L("读取 iCloud 失败：%@", error.localizedDescription))
            Log.error("iCloud 同步：读取失败：\(error.localizedDescription)")
        }
    }

    /// 首次开启时用户的选择。同步地取走 pending，剩下的异步做。
    func resolve(_ choice: Choice) {
        guard let remote = pending else { return }
        pending = nil
        Task { @MainActor [weak self] in
            await self?.apply(choice, remote: remote)
        }
    }

    private func apply(_ choice: Choice, remote: SyncedConfig) async {
        switch choice {
        case .useCloud:
            lastSynced = remote.config
            applyRemote?(remote.config)
            Log.info("iCloud 同步：用 iCloud 里的配置替换了本机的")
            enabled = true
            onEnabledChanged?(true)
            status = .synced(remote.updatedAt, remote.device)
            lastStamp = fileURL.flatMap(CloudFile.stamp(of:))
            startWatching()
        case .useLocal:
            await finishEnable(config: currentConfig(), push: true)
        case .merge:
            let merged = currentConfig().merging(cloud: remote.config)
            lastSynced = merged
            applyRemote?(merged)
            Log.info("iCloud 同步：合并了本机和 iCloud 的配置")
            await finishEnable(config: merged, push: true)
        }
    }

    func cancelEnable() {
        pending = nil
        status = .off
    }

    func disable() {
        pushTask?.cancel()
        pullTask?.cancel()
        stopWatching()
        enabled = false
        lastSynced = nil
        lastStamp = nil
        status = .off
        onEnabledChanged?(false)
        Log.info("iCloud 同步：已关闭")
    }

    /// 立即拉一次、再把本机的推上去（如果不一样）。
    func syncNow() async {
        guard enabled else { return }
        await pull()
        let config = currentConfig()
        if config != lastSynced {
            await push(config)
        }
    }

    private func finishEnable(config: AppConfig, push: Bool) async {
        enabled = true
        onEnabledChanged?(true)
        startWatching()
        if push {
            await self.push(config)
        } else {
            lastSynced = config
        }
        Log.info("iCloud 同步：已开启（\(folderURL?.path ?? "")）")
    }

    // MARK: - 本机改动

    /// 本机配置变了：稍等一下（连续改动合并成一次）再写到 iCloud。
    func localChanged(_ config: AppConfig) {
        guard enabled, config != lastSynced else { return }
        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.push(config)
        }
    }

    private func push(_ config: AppConfig) async {
        guard let url = fileURL else {
            status = .unavailable
            return
        }
        let synced = SyncedConfig(updatedAt: Date(), device: CloudFile.deviceName, config: config)
        do {
            try await Task.detached(priority: .utility) {
                try CloudFile.write(synced, to: url)
            }.value
            lastSynced = config
            lastStamp = CloudFile.stamp(of: url)
            status = .synced(synced.updatedAt, synced.device)
            Log.info("iCloud 同步：已写入本机的配置")
        } catch {
            status = .error(L("写入 iCloud 失败：%@", error.localizedDescription))
            Log.error("iCloud 同步：写入失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 云端改动

    private func readCloud() async throws -> SyncedConfig? {
        guard let url = fileURL else { throw CloudFileError.unavailable }
        return try await Task.detached(priority: .utility) { () throws -> SyncedConfig? in
            if let winner = try CloudFile.resolveConflicts(at: url) {
                return winner
            }
            return try CloudFile.read(at: url)
        }.value
    }

    /// 文件变了才真正去读。
    private func pullIfChanged() {
        guard enabled, let url = fileURL else { return }
        let stamp = CloudFile.stamp(of: url)
        guard stamp != lastStamp else { return }
        pullTask?.cancel()
        pullTask = Task { @MainActor [weak self] in
            // 等一下：iCloud 写文件常常是几次连续的改动。
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.pull()
        }
    }

    private func pull() async {
        guard enabled else { return }
        do {
            guard let remote = try await readCloud() else {
                // 云端还没有文件（第一次，或者被删了）：把本机的放上去。
                await push(currentConfig())
                return
            }
            lastStamp = fileURL.flatMap(CloudFile.stamp(of:))
            let current = currentConfig()
            if remote.config != current, remote.config != lastSynced {
                lastSynced = remote.config
                applyRemote?(remote.config)
                Log.info("iCloud 同步：应用了来自 \(remote.device) 的配置")
            } else {
                lastSynced = remote.config
            }
            status = .synced(remote.updatedAt, remote.device)
        } catch {
            status = .error(L("读取 iCloud 失败：%@", error.localizedDescription))
            Log.error("iCloud 同步：读取失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 监听

    private func startWatching() {
        stopWatching()
        guard let folder = folderURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.pullIfChanged() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        } else {
            Log.error("iCloud 同步：无法监听文件夹，改为定时检查")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pullIfChanged() }
        }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        timer?.invalidate()
        timer = nil
    }
}
