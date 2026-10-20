import Darwin
import Foundation

/// GitHub 上的一个发布版本，以及一键更新需要的附件。
struct ReleaseInfo: Equatable {
    var version: String
    var tag: String
    var pageURL: URL
    var notes: String
    var publishedAt: Date?
    /// 一键更新下载的压缩包：优先本机架构的精简包，没有时用通用包。
    var archiveURL: URL?
    var archiveName: String?
    var archiveSize: Int?
    var checksumsURL: URL?

    /// 有压缩包和校验文件才能在程序里直接安装。
    var canInstall: Bool { archiveURL != nil && checksumsURL != nil }
}

enum UpdateError: LocalizedError, Equatable {
    case server(Int)
    case badResponse
    case noArchive
    case checksumsMissing
    case checksumMismatch
    case extract(String)
    case appNotFound
    case wrongApp(String)
    case notInstallable(String)
    case install(String)
    case cancelledByUser
    /// macOS 不让替换（「App 管理」权限或者别的系统保护）。
    case appManagement
    /// 新版本不是当前版本的开发者（这个 Team ID）签名的。
    case wrongSigner(String)

    var errorDescription: String? {
        switch self {
        case .server(let code): return L("服务器返回了 %@", code)
        case .badResponse: return L("读不懂服务器返回的内容")
        case .noArchive: return L("这个版本没有可以直接安装的附件")
        case .checksumsMissing: return L("校验文件里没有这个附件的校验和")
        case .checksumMismatch: return L("下载的文件校验和不对，可能没下载完整或被篡改")
        case .extract(let text): return L("解压失败：%@", text)
        case .appNotFound: return L("压缩包里没有 Proxi.app")
        case .wrongApp(let text): return L("下载的程序不对：%@", text)
        case .notInstallable(let text): return text
        case .install(let text): return L("替换程序失败：%@", text)
        case .cancelledByUser: return L("已取消授权，程序没有改动")
        case .appManagement: return L("macOS 不允许 Proxi 替换自己。到「系统设置 → 隐私与安全性 → App 管理」里打开 Proxi，再点重试")
        case .wrongSigner(let team): return L("新版本不是同一个开发者签名的（应该是 %@），为了安全没有安装。可以到发布页确认后手动下载", team)
        }
    }
}

/// 检查 GitHub 上的最新发布。
enum UpdateChecker {
    /// 通用包（两种芯片都能用），手动下载和旧版本的一键更新用它。
    /// 发布里还有一份 ProxySwitch-macos.zip 这样的旧名字副本，是给改名前的版本更新用的。
    static let archiveName = "Proxi-macos.zip"
    static let checksumsName = "SHA256SUMS.txt"
    /// 测试用：把这个环境变量指向别的地址，就能从本地服务器「发布」新版本。
    static let overrideVariable = "PROXI_UPDATE_URL"

    static var releasesURL: URL { URL(string: "https://github.com/\(AppInfo.repository)/releases")! }

    static var apiURL: URL {
        if let text = ProcessInfo.processInfo.environment[overrideVariable], let url = URL(string: text) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest")!
    }

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    static var userAgent: String { "Proxi/\(currentVersion) (macOS)" }

    /// 本机的芯片架构，Rosetta 下也按硬件算：arm64 或 x86_64。
    static var machineArchitecture: String {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 {
            return "arm64"
        }
        return "x86_64"
    }

    /// 只含一种芯片的精简包，只有通用包的一半大。
    static func thinArchiveName(for architecture: String) -> String {
        "Proxi-macos-\(architecture).zip"
    }

    /// 依次经各条线路查询，第一个成功的为准。
    static func latest(routes: [NetworkRoute] = [.system]) async throws -> ReleaseInfo {
        var lastError: Error = UpdateError.badResponse
        for route in routes {
            do {
                return try await latest(via: route)
            } catch {
                Log.info("经\(route.title)检查更新失败：\(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    private static func latest(via route: NetworkRoute) async throws -> ReleaseInfo {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        route.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.server(http.statusCode)
        }
        guard let release = parse(data) else { throw UpdateError.badResponse }
        return release
    }

    /// 解析 GitHub releases 接口返回的 JSON；压缩包优先选本机架构的精简包。
    static func parse(_ data: Data, architecture: String = machineArchitecture) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty else {
            return nil
        }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        func asset(named name: String) -> [String: Any]? {
            assets.first { ($0["name"] as? String) == name }
        }
        let archive = [thinArchiveName(for: architecture), archiveName].compactMap { asset(named: $0) }.first
        let publishedAt = (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return ReleaseInfo(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            tag: tag,
            pageURL: (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesURL,
            notes: (json["body"] as? String) ?? "",
            publishedAt: publishedAt,
            archiveURL: (archive?["browser_download_url"] as? String).flatMap(URL.init(string:)),
            archiveName: archive?["name"] as? String,
            archiveSize: archive?["size"] as? Int,
            checksumsURL: (asset(named: checksumsName)?["browser_download_url"] as? String).flatMap(URL.init(string:))
        )
    }
}
