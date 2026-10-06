import AppKit
import Combine

/// 更新：检查 GitHub 上的新版本，下载、校验、替换程序并重新启动。状态只在主线程上改，界面直接观察它。
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        /// 有新版本，但用户选择过跳过它。
        case skipped(ReleaseInfo)
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, Double?)
        case verifying(ReleaseInfo)
        case installing(ReleaseInfo)
        case relaunching(ReleaseInfo)
        /// 安装失败。
        case failed(ReleaseInfo, String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?
    /// 最近一次检查失败的原因（手动检查时显示）。
    @Published private(set) var checkError: String?
    /// 正在下载用的线路（系统代理、直连）。
    @Published private(set) var route: NetworkRoute?
    /// 最近一次安装失败的原因，界面据此给出对应的按钮。
    @Published private(set) var lastFailure: UpdateError?
    /// 从当前版本到发现的新版本之间每一版的更新记录，新的在前；取不到时是空的，界面上显示新版本的发布说明。
    @Published private(set) var changes: [Changelog.Release] = []

    /// 自动检查发现新版本时通知（标题、正文）。
    var notify: (@MainActor (String, String) -> Void)?
    /// 新程序已经换好、该退出了。
    var onRelaunch: (@MainActor () -> Void)?
    /// 访问某个地址时依次尝试的线路；没设置时只用系统代理设置。
    var routesProvider: (@MainActor (URL) -> [NetworkRoute])?

    static let checkInterval: TimeInterval = 6 * 3600
    private static let skippedKey = "update.skippedVersion"
    private static let notifiedKey = "update.notifiedVersion"

    private var timer: Timer?
    private var installTask: Task<Void, Never>?
    /// changes 是哪个标签的（每个新版本只取一次）。
    private var changesByTag: [String: [Changelog.Release]] = [:]

    /// 发现的新版本（含正在安装和安装失败的），跳过的不算。
    var release: ReleaseInfo? {
        switch phase {
        case .available(let release), .downloading(let release, _), .verifying(let release),
             .installing(let release), .relaunching(let release), .failed(let release, _):
            return release
        case .idle, .checking, .upToDate, .skipped:
            return nil
        }
    }

    var isInstalling: Bool {
        switch phase {
        case .downloading, .verifying, .installing, .relaunching: return true
        default: return false
        }
    }

    /// 更新装到哪里（启动后不会变，算一次就够）。
    private(set) lazy var plan: InstallPlan? = InstallLocation.current()

    /// 没法在程序里更新的原因：只有不是从 .app 运行（开发时 swift run）才会这样。
    var installProblem: String? {
        plan == nil ? L("不是从 Proxi.app 运行的，没法在程序里更新") : nil
    }

    /// 从下载文件夹这类临时位置运行时，更新会装进「应用程序」。
    var relocationNote: String? {
        guard let plan, plan.relocating else { return nil }
        let folder = InstallLocation.displayName(of: plan.target.deletingLastPathComponent())
        return L("现在是从下载文件夹这类临时位置运行的，这次会装进%@", folder) + (plan.trashAfter == nil ? "" : L("，旧的那份移到废纸篓"))
    }

    private func routes(for url: URL) -> [NetworkRoute] {
        routesProvider?(url) ?? [.system]
    }

    var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Self.skippedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.skippedKey) }
    }

    // MARK: - 检查

    /// 启动几秒后检查一次，之后每 6 小时一次；enabled 返回 false 时不检查。
    func startAutomaticChecks(enabled: @escaping @MainActor () -> Bool) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if enabled() { await self?.check(manual: false) }
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if enabled() { await self?.check(manual: false) }
        }
    }

    /// 检查一次。manual：用户点的，失败要显示，跳过的版本也显示。返回可以安装的新版本。
    @discardableResult
    func check(manual: Bool) async -> ReleaseInfo? {
        if isInstalling { return release }
        if case .checking = phase { return nil }
        let previous = phase
        phase = .checking
        checkError = nil
        do {
            let latest = try await UpdateChecker.latest(routes: routes(for: UpdateChecker.apiURL))
            lastChecked = Date()
            let current = UpdateChecker.currentVersion
            guard UpdateChecker.isNewer(latest.version, than: current) else {
                Log.info("检查更新：当前 \(current) 已是最新（最新发布 \(latest.version)）")
                phase = .upToDate
                return nil
            }
            // 跳过的版本也取：之后点「仍然查看」还要看。
            await loadChanges(since: current, upTo: latest)
            if !manual, latest.version == skippedVersion {
                Log.info("检查更新：有新版本 \(latest.version)，之前选择过跳过")
                phase = .skipped(latest)
                return nil
            }
            Log.info("检查更新：有新版本 \(latest.version)（当前 \(current)）")
            phase = .available(latest)
            if !manual, UserDefaults.standard.string(forKey: Self.notifiedKey) != latest.version {
                UserDefaults.standard.set(latest.version, forKey: Self.notifiedKey)
                notify?(L("Proxi 有新版本 %@", latest.version), L("点「立即更新」自动下载安装并重新启动，点通知本身查看更新内容"))
            }
            return latest
        } catch {
            Log.error("检查更新失败：\(error.localizedDescription)")
            phase = previous
            if manual {
                checkError = L("检查更新失败：%@", error.localizedDescription)
            }
            return nil
        }
    }

    private func loadChanges(since current: String, upTo release: ReleaseInfo) async {
        if let cached = changesByTag[release.tag] {
            changes = cached
            return
        }
        // 失败也记一次，避免每次自动检查都重复下载；界面仍显示发布说明。
        changesByTag[release.tag] = []
        changes = []
        do {
            changes = try await UpdateChecker.changes(since: current, upTo: release, routes: routes(for: UpdateChecker.changelogURL(tag: release.tag)))
            changesByTag[release.tag] = changes
            Log.info("检查更新：\(current) 到 \(release.version) 之间有 \(changes.count) 个版本的更新记录")
        } catch {
            Log.info("取 \(release.tag) 的更新记录失败，显示这一版的发布说明：\(error.localizedDescription)")
            changes = []
        }
    }

    func skipAvailableVersion() {
        guard case .available(let release) = phase else { return }
        skippedVersion = release.version
        phase = .skipped(release)
    }

    /// 跳过的版本重新拿出来看。
    func showSkippedVersion() {
        guard case .skipped(let release) = phase else { return }
        phase = .available(release)
    }

    // MARK: - 安装

    /// 下载并安装 release（当前发现的新版本），完成后重新启动。
    func install() {
        guard let release, !isInstalling, installTask == nil else { return }
        lastFailure = nil
        if let problem = installProblem {
            phase = .failed(release, problem)
            return
        }
        guard release.canInstall else {
            lastFailure = .noArchive
            phase = .failed(release, UpdateError.noArchive.localizedDescription)
            return
        }
        installTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.perform(release)
            } catch is CancellationError {
                Log.info("更新已取消")
                self.phase = .available(release)
            } catch {
                Log.error("更新到 \(release.version) 失败：\(error.localizedDescription)")
                self.lastFailure = error as? UpdateError
                self.phase = .failed(release, error.localizedDescription)
            }
            self.route = nil
            self.installTask = nil
        }
    }

    func cancel() {
        installTask?.cancel()
    }

    /// 检查并直接安装（proxi://update、通知里的「立即更新」）。已经知道有新版本时不再重复检查。
    func checkAndInstall() async {
        if case .skipped = phase {
            showSkippedVersion()
        }
        if release == nil {
            await check(manual: true)
        }
        install()
    }

    private func perform(_ release: ReleaseInfo) async throws {
        guard let plan = InstallLocation.current() else {
            throw UpdateError.notInstallable(installProblem ?? "")
        }
        guard let archiveURL = release.archiveURL, let checksumsURL = release.checksumsURL else {
            throw UpdateError.noArchive
        }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("Proxi-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let archive = workDir.appendingPathComponent(release.archiveName ?? UpdateChecker.archiveName)
        try await download(release, from: archiveURL, to: archive)
        try Task.checkCancellation()
        phase = .verifying(release)
        try await UpdateInstaller.verify(archive: archive, checksumsURL: checksumsURL, routes: routes(for: checksumsURL))
        let app = try await UpdateInstaller.extract(archive: archive, to: workDir.appendingPathComponent("extracted", isDirectory: true))
        try await UpdateInstaller.validate(app: app, expectedVersion: release.version)
        try Task.checkCancellation()
        phase = .installing(release)
        try await UpdateInstaller.install(newApp: app, replacing: plan.target)
        try? fm.removeItem(at: workDir)
        if let old = plan.trashAfter {
            do {
                try fm.trashItem(at: old, resultingItemURL: nil)
                Log.info("已把旧版本 \(old.path) 移到废纸篓")
            } catch {
                Log.error("旧版本 \(old.path) 没能移到废纸篓：\(error.localizedDescription)")
            }
        }
        Log.info("已更新到 \(release.version)（\(plan.target.path)），重新启动")
        phase = .relaunching(release)
        UpdateInstaller.relaunch(plan.target)
        try? await Task.sleep(for: .milliseconds(600))
        onRelaunch?()
    }

    /// 依次经各条线路下载，一条失败就换下一条。
    private func download(_ release: ReleaseInfo, from url: URL, to archive: URL) async throws {
        var lastError: Error = UpdateError.badResponse
        for route in routes(for: url) {
            self.route = route
            phase = .downloading(release, nil)
            Log.info("开始更新到 \(release.version)：经\(route.title)下载 \(url.absoluteString)")
            do {
                try await UpdateInstaller.download(url, expectedSize: release.archiveSize, to: archive, route: route) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.phase else { return }
                        self.phase = .downloading(release, fraction)
                    }
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.error("经\(route.title)下载失败：\(error.localizedDescription)")
                lastError = error
                try? FileManager.default.removeItem(at: archive)
            }
        }
        throw lastError
    }
}
