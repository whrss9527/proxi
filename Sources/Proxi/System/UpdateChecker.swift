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
        let data = try await fetch(apiURL, accept: "application/vnd.github+json", via: route)
        guard let release = parse(data) else { throw UpdateError.badResponse }
        return release
    }

    /// 新版本标签上的 CHANGELOG.md。走 api.github.com 的接口，不用 raw.githubusercontent.com：有些网络连不上后者。
    static func changelogURL(tag: String) -> URL {
        var components = URLComponents(string: "https://api.github.com/repos/\(AppInfo.repository)/contents/CHANGELOG.md")!
        components.queryItems = [URLQueryItem(name: "ref", value: tag)]
        return components.url!
    }

    /// 比 current 新、不比 release 新的每一版的更新记录，新的在前；依次经各条线路取，第一个成功的为准。
    /// 测试时（设了 PROXI_UPDATE_URL）不联网，返回空，界面上显示新版本的发布说明。
    static func changes(since current: String, upTo release: ReleaseInfo, routes: [NetworkRoute] = [.system]) async throws -> [Changelog.Release] {
        guard ProcessInfo.processInfo.environment[overrideVariable] == nil else { return [] }
        let url = changelogURL(tag: release.tag)
        var lastError: Error = UpdateError.badResponse
        for route in routes {
            do {
                let data = try await fetch(url, accept: "application/vnd.github.raw", via: route)
                return Changelog.releases(Changelog.parse(String(decoding: data, as: UTF8.self)), after: current, upTo: release.version)
            } catch {
                Log.info("经\(route.title)取 \(release.tag) 的更新记录失败：\(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    private static func fetch(_ url: URL, accept: String, via route: NetworkRoute) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        route.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.server(http.statusCode)
        }
        return data
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

    /// 比较版本号：first 比 second 新返回 true。数字逐段比较；带 -beta 之类后缀的预发布版本比同号的正式版本旧。
    static func isNewer(_ first: String, than second: String) -> Bool {
        let a = components(first)
        let b = components(second)
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x > y }
        }
        return !a.prerelease && b.prerelease
    }

    private static func components(_ version: String) -> (numbers: [Int], prerelease: Bool) {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        let parts = text.split(separator: "-", maxSplits: 1)
        let numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        return (numbers, parts.count > 1)
    }
}
