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
    private let io: CloudSyncIO
    private var lastSynced: AppConfig?
    private var lastStamp: String?
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var session: CloudSyncSession?
    private var pendingStamp: String?
    private var enableTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?

    init(folder: URL? = nil, io: CloudSyncIO = CloudSyncIO()) {
        folderOverride = folder
        self.io = io
    }

    var folderURL: URL? { folderOverride ?? CloudFile.folderURL }
    var fileURL: URL? { folderURL?.appendingPathComponent(CloudFile.fileName) }
    var available: Bool { folderURL != nil }

    // MARK: - 开关

    /// 启动时按记录的开关恢复。
    func start(enabled: Bool) {
        guard enabled else { return }
        let session = beginSession()
        guard available else {
            self.enabled = true
            status = .unavailable
            return
        }
        self.enabled = true
        status = .syncing
        startWatching(session: session)
        pullTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.migrateLegacyFolder(session: session)
            await self.pull(session: session)
        }
    }

    /// 改名前的同步文件夹里的配置更新（或者新文件夹里还没有）时复制过来（测试时指定了文件夹就不动）。
    /// 读 iCloud 里的文件可能要等下载，不在主线程上做。
    private func migrateLegacyFolder(session: CloudSyncSession) async throws {
        guard folderOverride == nil else { return }
        let copied = try await io.migrate(session: session)
        guard accepts(session) else { return }
        if copied {
            Log.info("iCloud 同步：把 iCloud 云盘/\(CloudFile.legacyFolderName) 里的配置复制到了 \(CloudFile.folderName)")
        }
    }

    /// 用户打开开关：iCloud 里已有不同的配置时先问用户，否则直接开始。
    func enable() async {
        guard !enabled, pending == nil, resolveTask == nil else { return }
        if let enableTask {
            await enableTask.value
            return
        }
        guard !Task.isCancelled else { return }
        let session = beginSession()
        guard available else {
            status = .unavailable
            return
        }
        status = .syncing
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareEnable(session: session)
        }
        enableTask = task
        await task.value
        if self.session === session { enableTask = nil }
    }

    private func prepareEnable(session: CloudSyncSession) async {
        do {
            guard accepts(session) else { return }
            try await migrateLegacyFolder(session: session)
            guard accepts(session) else { return }
            let snapshot = try await readCloud(session: session)
            guard accepts(session) else { return }
            let local = currentConfig()
            if let remote = snapshot.synced, remote.config != local, !remote.config.profiles.isEmpty {
                pendingStamp = snapshot.stamp
                pending = remote
                status = .off
                return
            }
            // 云端没有文件、内容一样或者是空的：直接把本机的写上去。
            await finishEnable(config: local, session: session)
        } catch {
            guard accepts(session) else { return }
            status = .error(L("读取 iCloud 失败：%@", error.localizedDescription))
            Log.error("iCloud 同步：读取失败：\(error.localizedDescription)")
        }
    }

    /// 首次开启时用户的选择。同步地取走 pending，剩下的异步做。
    func resolve(_ choice: Choice) {
        guard let session, accepts(session), let remote = pending else { return }
        let stamp = pendingStamp
        pending = nil
        pendingStamp = nil
        resolveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.apply(choice, remote: remote, stamp: stamp, session: session)
            if self.session === session { self.resolveTask = nil }
        }
    }

    private func apply(_ choice: Choice, remote: SyncedConfig, stamp: String?, session: CloudSyncSession) async {
        guard accepts(session) else { return }
        switch choice {
        case .useCloud:
            lastSynced = remote.config
            applyRemote?(remote.config)
            guard accepts(session) else { return }
            Log.info("iCloud 同步：用 iCloud 里的配置替换了本机的")
            enabled = true
            onEnabledChanged?(true)
            guard accepts(session) else { return }
            status = .synced(remote.updatedAt, remote.device)
            lastStamp = stamp
            startWatching(session: session)
        case .useLocal:
            await finishEnable(config: currentConfig(), session: session)
        case .merge:
            let merged = currentConfig().merging(cloud: remote.config)
            lastSynced = merged
            applyRemote?(merged)
            guard accepts(session) else { return }
            Log.info("iCloud 同步：合并了本机和 iCloud 的配置")
            await finishEnable(config: merged, session: session)
        }
    }

    func cancelEnable() {
        guard !enabled else { return }
        invalidateSession()
        status = .off
    }

    func disable() {
        invalidateSession()
        enabled = false
        status = .off
        onEnabledChanged?(false)
        Log.info("iCloud 同步：已关闭")
    }

    /// 立即拉一次、再把本机的推上去（如果不一样）。
    func syncNow() async {
        guard enabled, let session, accepts(session) else { return }
        await pull(session: session)
        guard enabled, accepts(session) else { return }
        let config = currentConfig()
        if config != lastSynced {
            await push(config, session: session)
        }
    }

    private func finishEnable(config: AppConfig, session: CloudSyncSession) async {
        guard accepts(session) else { return }
        enabled = true
        onEnabledChanged?(true)
        guard accepts(session) else { return }
        startWatching(session: session)
        await push(config, session: session)
        guard accepts(session) else { return }
        Log.info("iCloud 同步：已开启（\(folderURL?.path ?? "")）")
    }

    private func beginSession() -> CloudSyncSession {
        invalidateSession()
        let session = CloudSyncSession()
        self.session = session
        return session
    }

    private func accepts(_ session: CloudSyncSession) -> Bool {
        self.session === session && !Task.isCancelled
    }

    private func invalidateSession() {
        session?.invalidate()
        session = nil
        enableTask?.cancel()
        resolveTask?.cancel()
        pushTask?.cancel()
        pullTask?.cancel()
        enableTask = nil
        resolveTask = nil
        pushTask = nil
        pullTask = nil
        pending = nil
        pendingStamp = nil
        lastSynced = nil
        lastStamp = nil
        stopWatching()
    }

    // MARK: - 本机改动

    /// 本机配置变了：稍等一下（连续改动合并成一次）再写到 iCloud。
    func localChanged(_ config: AppConfig) {
        guard enabled, let session, accepts(session), config != lastSynced else { return }
        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.push(config, session: session)
        }
    }

    private func push(_ config: AppConfig, session: CloudSyncSession) async {
        guard enabled, accepts(session) else { return }
        guard let url = fileURL else {
            status = .unavailable
            return
        }
        let synced = SyncedConfig(updatedAt: Date(), device: CloudFile.deviceName, config: config)
        do {
            let stamp = try await io.write(synced, to: url, session: session)
            guard enabled, accepts(session) else { return }
            lastSynced = config
            lastStamp = stamp
            status = .synced(synced.updatedAt, synced.device)
            Log.info("iCloud 同步：已写入本机的配置")
        } catch {
            guard enabled, accepts(session) else { return }
            status = .error(L("写入 iCloud 失败：%@", error.localizedDescription))
            Log.error("iCloud 同步：写入失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 云端改动

    private func readCloud(session: CloudSyncSession) async throws -> CloudSyncIO.Snapshot {
        guard let url = fileURL else { throw CloudFileError.unavailable }
        return try await io.read(at: url, session: session)
    }

    /// 文件变了才真正去读。
    private func pullIfChanged(session: CloudSyncSession) {
        guard enabled, accepts(session), let url = fileURL else { return }
        let stamp = CloudFile.stamp(of: url)
        guard stamp != lastStamp else { return }
        pullTask?.cancel()
        pullTask = Task { @MainActor [weak self] in
            // 等一下：iCloud 写文件常常是几次连续的改动。
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.pull(session: session)
        }
    }

    private func pull(session: CloudSyncSession) async {
        guard enabled, accepts(session) else { return }
        do {
            let snapshot = try await readCloud(session: session)
            guard enabled, accepts(session) else { return }
            guard let remote = snapshot.synced else {
                // 云端还没有文件（第一次，或者被删了）：把本机的放上去。
                await push(currentConfig(), session: session)
                return
            }
            lastStamp = snapshot.stamp
            let current = currentConfig()
            if remote.config != current, remote.config != lastSynced {
                lastSynced = remote.config
                applyRemote?(remote.config)
                guard accepts(session) else { return }
                Log.info("iCloud 同步：应用了来自 \(remote.device) 的配置")
            } else {
                lastSynced = remote.config
            }
            status = .synced(remote.updatedAt, remote.device)
        } catch {
            guard enabled, accepts(session) else { return }
            status = .error(L("读取 iCloud 失败：%@", error.localizedDescription))
            Log.error("iCloud 同步：读取失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 监听

    private func startWatching(session: CloudSyncSession) {
        guard enabled, accepts(session) else { return }
        stopWatching()
        guard let folder = folderURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.pullIfChanged(session: session) }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        } else {
            Log.error("iCloud 同步：无法监听文件夹，改为定时检查")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pullIfChanged(session: session) }
        }
        timer?.tolerance = 6
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        timer?.invalidate()
        timer = nil
    }
}
