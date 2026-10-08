import Foundation

/// 内核（mihomo）和 GeoIP 数据库：不打包在程序里，代理引擎第一次运行时从上游的正式发布下载。
/// 版本和 SHA-256 都写死在这里：下载完先校验压缩包，解压后再校验程序本身，对不上就删掉、不用。
/// 装特权助手时，助手把内核复制到只有 root 能写的目录后再按这里的校验和查一遍，启动前也查（见 PrivilegedHelper.swift）。
enum CorePin {
    /// 上游发布的版本（https://github.com/MetaCubeX/mihomo/releases）。
    static let version = "v1.19.31"

    struct Asset: Equatable {
        /// 发布里的文件名（gzip 压缩的单个程序）。
        var file: String
        /// 压缩包的 SHA-256。
        var archiveSHA256: String
        /// 解压出来的程序的 SHA-256。
        var binarySHA256: String

        var url: URL { URL(string: "https://github.com/MetaCubeX/mihomo/releases/download/\(CorePin.version)/\(file)")! }
    }

    /// 按芯片架构：Apple 芯片用 arm64；Intel 用 amd64-compatible（不要求新的指令集，老机器也能跑）。
    static let assets: [String: Asset] = [
        "arm64": Asset(
            file: "mihomo-darwin-arm64-v1.19.31.gz",
            archiveSHA256: "d131f44b3deb2a8356f7ac75048ad67a10d53243323951c4f3cda7b672922963",
            binarySHA256: "fae1f37e28ee53fcf5be7a8bb121099db1fe442e44205734ed49c62579364090"
        ),
        "x86_64": Asset(
            file: "mihomo-darwin-amd64-compatible-v1.19.31.gz",
            archiveSHA256: "fb6fca0e105b4310a21eaacd3a8d3853d3d8b87fa4c69737bea52a30a435aac7",
            binarySHA256: "d1361fdb7f93ac500d8c936cfd61516b2445c6acfaabe982244fdd765872e077"
        ),
    ]

    /// 认可的内核程序的 SHA-256（各个架构的）。特权助手只运行其中之一。
    static var binarySHA256s: Set<String> { Set(assets.values.map(\.binarySHA256)) }

    /// GeoIP 数据库（MaxMind 格式，按 IP 归属地分流的规则要用）：固定在某一次发布，不跟着「最新」走。
    static let geoIPURL = URL(string: "https://github.com/Loyalsoldier/geoip/releases/download/202609240030/Country.mmdb")!
    static let geoIPSHA256 = "f35228dd74b70ae0ac72dcd2b86d03e0510264e20a0ec21ebb6aa32fa4f85c38"

    static func asset(for architecture: String = UpdateChecker.machineArchitecture) -> Asset? {
        assets[architecture]
    }
}

/// 下载、校验、安装内核和 GeoIP 数据库，放在数据目录的 bin/ 里。只在主线程上用。
@MainActor
final class CoreDownload: ObservableObject {
    enum Phase: Equatable {
        case unknown
        case missing
        /// 下载中，附带 0…1 的进度（不知道总大小时是 nil）和正在下载的东西。
        case downloading(String, Double?)
        case verifying
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .unknown
    /// 装好（或者校验通过）时调用：内核可以启动了。
    var onInstalled: (() -> Void)?
    private var task: Task<Void, Never>?

    nonisolated static var directory: URL { Store.directory.appendingPathComponent("bin", isDirectory: true) }
    nonisolated static var coreURL: URL { directory.appendingPathComponent(CoreBinary.name) }
    nonisolated static var geoIPURL: URL { directory.appendingPathComponent("Country.mmdb") }

    var isReady: Bool { phase == .ready }
    var isBusy: Bool {
        switch phase {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    /// 启动时：已经下好的校验一遍，对得上就直接用；没有或者不对就下载。
    func prepare() async {
        if ProcessInfo.processInfo.environment["PROXI_CORE"]?.isEmpty == false {
            phase = .ready
            onInstalled?()
            return
        }
        phase = .verifying
        let valid = await Task.detached(priority: .userInitiated) { Self.installedFilesValid() }.value
        if valid {
            phase = .ready
            Log.info("内核 \(CorePin.version) 已就绪：\(Self.coreURL.path)")
            onInstalled?()
            return
        }
        phase = .missing
        install()
    }

    /// 下载并安装（已经在下载时不重复开始）。
    func install() {
        guard !isBusy else { return }
        task = Task { @MainActor [weak self] in
            await self?.runInstall()
        }
    }

    /// 删掉下载的内核和 GeoIP 数据库（内核先停掉）。
    func remove() {
        task?.cancel()
        try? FileManager.default.removeItem(at: Self.directory)
        phase = .missing
        Log.info("已删除下载的内核")
    }

    private func runInstall() async {
        guard let asset = CorePin.asset() else {
            phase = .failed(L("不支持这种芯片：%@", UpdateChecker.machineArchitecture))
            return
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("proxi-engine-core-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            // 内核
            let archive = staging.appendingPathComponent("mihomo.gz")
            try await download(asset.url, title: L("内核 %@", CorePin.version), to: archive)
            phase = .verifying
            guard try Checksums.sha256(of: archive) == asset.archiveSHA256 else { throw CoreDownloadError.checksum(asset.file) }
            let result = try await Shell.run("/usr/bin/gunzip", ["-f", archive.path], timeout: 120)
            let binary = staging.appendingPathComponent("mihomo")
            guard result.succeeded, fm.fileExists(atPath: binary.path) else { throw CoreDownloadError.extract(result.trimmedOutput) }
            guard try Checksums.sha256(of: binary) == asset.binarySHA256 else { throw CoreDownloadError.checksum(CoreBinary.name) }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            // GeoIP 数据库
            let geoIP = staging.appendingPathComponent("Country.mmdb")
            try await download(CorePin.geoIPURL, title: L("GeoIP 数据库"), to: geoIP)
            phase = .verifying
            guard try Checksums.sha256(of: geoIP) == CorePin.geoIPSHA256 else { throw CoreDownloadError.checksum("Country.mmdb") }
            // 都对了才放进去。
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            for (source, target) in [(binary, Self.coreURL), (geoIP, Self.geoIPURL)] {
                try? fm.removeItem(at: target)
                try fm.moveItem(at: source, to: target)
            }
            phase = .ready
            Log.info("内核 \(CorePin.version) 和 GeoIP 数据库已下载并校验：\(Self.directory.path)")
            onInstalled?()
        } catch is CancellationError {
            phase = .missing
        } catch {
            let message = error.localizedDescription
            phase = .failed(message)
            Log.error("下载内核失败：\(message)")
        }
    }

    private func download(_ url: URL, title: String, to destination: URL) async throws {
        Log.info("event=core.download url=\(url.absoluteString)")
        phase = .downloading(title, nil)
        let routes = NetworkRoute.routes(for: url, corePort: nil, system: SystemProxy.current())
        var lastError: Error = CoreDownloadError.network
        for route in routes {
            do {
                try await UpdateInstaller.download(url, expectedSize: nil, to: destination, route: route) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.phase else { return }
                        self.phase = .downloading(title, fraction)
                    }
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.info("经\(route.title)下载 \(url.lastPathComponent) 失败：\(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    /// 已经下好的内核和 GeoIP 数据库都在、校验和都对得上。
    nonisolated static func installedFilesValid() -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: coreURL.path), fm.fileExists(atPath: geoIPURL.path),
              let core = try? Checksums.sha256(of: coreURL), CorePin.binarySHA256s.contains(core),
              let geo = try? Checksums.sha256(of: geoIPURL), geo == CorePin.geoIPSHA256 else {
            return false
        }
        return true
    }
}

enum CoreDownloadError: LocalizedError {
    case checksum(String)
    case extract(String)
    case network

    var errorDescription: String? {
        switch self {
        case .checksum(let name): return L("%@ 的校验和不对，可能没下载完整或被篡改，没有使用", name)
        case .extract(let text): return L("解压失败：%@", text)
        case .network: return L("下载失败")
        }
    }
}
