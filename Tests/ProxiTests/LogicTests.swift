import XCTest
@testable import Proxi

final class DesiredProxyTests: XCTestCase {
    func testHttpProfileCommands() {
        var profile = Profile(name: "本机", color: "#16a34a", kind: .http, host: "127.0.0.1", port: 8888)
        profile.bypass = "localhost, 10.*, <local>"
        let commands = DesiredProxy(profile: profile).commands(service: "Wi-Fi").map { $0.joined(separator: " ") }
        XCTAssertEqual(commands, [
            "-setwebproxy Wi-Fi 127.0.0.1 8888",
            "-setwebproxystate Wi-Fi on",
            "-setsecurewebproxy Wi-Fi 127.0.0.1 8888",
            "-setsecurewebproxystate Wi-Fi on",
            "-setsocksfirewallproxystate Wi-Fi off",
            "-setautoproxystate Wi-Fi off",
            "-setproxyautodiscovery Wi-Fi off",
            "-setproxybypassdomains Wi-Fi localhost 10.0.0.0/8",
        ])
    }

    func testOffKeepsAddressesAndRestoresDiscovery() {
        let commands = DesiredProxy(offWithAutoDiscovery: true, bypassDomains: []).commands(service: "以太网").map { $0.joined(separator: " ") }
        XCTAssertFalse(commands.contains { $0.hasPrefix("-setwebproxy ") || $0.hasPrefix("-setsecurewebproxy ") || $0.hasPrefix("-setautoproxyurl") })
        XCTAssertTrue(commands.contains("-setproxyautodiscovery 以太网 on"))
        XCTAssertEqual(commands.last, "-setproxybypassdomains 以太网 Empty")
    }

    func testPacAndSocks() {
        let pac = Profile(name: "PAC", color: "#000000", kind: .pac, pacURL: "http://127.0.0.1:8888/proxy.pac")
        let pacCommands = DesiredProxy(profile: pac).commands(service: "Wi-Fi").map { $0.joined(separator: " ") }
        XCTAssertTrue(pacCommands.contains("-setautoproxyurl Wi-Fi http://127.0.0.1:8888/proxy.pac"))
        XCTAssertTrue(pacCommands.contains("-setautoproxystate Wi-Fi on"))
        XCTAssertTrue(pacCommands.contains("-setwebproxystate Wi-Fi off"))

        let socks = Profile(name: "SOCKS", color: "#000000", kind: .socks5, host: "127.0.0.1", port: 1080)
        let socksCommands = DesiredProxy(profile: socks).commands(service: "Wi-Fi").map { $0.joined(separator: " ") }
        XCTAssertTrue(socksCommands.contains("-setsocksfirewallproxy Wi-Fi 127.0.0.1 1080"))
        XCTAssertTrue(socksCommands.contains("-setsocksfirewallproxystate Wi-Fi on"))
        XCTAssertTrue(socksCommands.contains("-setwebproxystate Wi-Fi off"))
    }

    func testRestoreSnapshot() {
        var snapshot = ProxySnapshot()
        snapshot.httpEnabled = true
        snapshot.httpHost = "proxy.corp"
        snapshot.httpPort = 3128
        snapshot.autoDiscovery = true
        snapshot.exceptions = ["*.corp"]
        let desired = DesiredProxy(restoring: snapshot)
        XCTAssertEqual(desired.http, DesiredProxy.Endpoint(host: "proxy.corp", port: 3128))
        XCTAssertNil(desired.https)
        XCTAssertTrue(desired.autoDiscovery)
        XCTAssertEqual(desired.bypassDomains, ["*.corp"])
    }

    /// 开启前 HTTP 和 HTTPS 是不同的地址（或者只开了 HTTPS）：恢复时各按各的，不把一个的地址套到另一个上。
    func testRestoreKeepsHttpsSeparate() {
        var snapshot = ProxySnapshot()
        snapshot.httpEnabled = true
        snapshot.httpHost = "a.corp"
        snapshot.httpPort = 3128
        snapshot.httpsEnabled = true
        snapshot.httpsHost = "b.corp"
        snapshot.httpsPort = 3129
        let commands = DesiredProxy(restoring: snapshot).commands(service: "Wi-Fi").map { $0.joined(separator: " ") }
        XCTAssertTrue(commands.contains("-setwebproxy Wi-Fi a.corp 3128"))
        XCTAssertTrue(commands.contains("-setsecurewebproxy Wi-Fi b.corp 3129"))

        var httpsOnly = ProxySnapshot()
        httpsOnly.httpsEnabled = true
        httpsOnly.httpsHost = "secure.corp"
        httpsOnly.httpsPort = 8443
        let httpsCommands = DesiredProxy(restoring: httpsOnly).commands(service: "Wi-Fi").map { $0.joined(separator: " ") }
        XCTAssertTrue(httpsCommands.contains("-setwebproxystate Wi-Fi off"))
        XCTAssertTrue(httpsCommands.contains("-setsecurewebproxy Wi-Fi secure.corp 8443"))
        XCTAssertTrue(httpsCommands.contains("-setsecurewebproxystate Wi-Fi on"))
    }
}

final class BypassListTests: XCTestCase {
    func testConversion() {
        XCTAssertEqual(BypassList.domains(from: "localhost;127.*;10.*;172.16.*;192.168.1.*;<local>;*.local, 169.254/16"),
                       ["localhost", "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/16", "192.168.1.0/24", "*.local", "169.254/16"])
        XCTAssertEqual(BypassList.domains(from: ""), [])
        XCTAssertEqual(BypassList.domains(from: "a.com, a.com"), ["a.com"])
    }
}

final class ProxySnapshotTests: XCTestCase {
    func testParseAndMatch() {
        let snapshot = ProxySnapshot(dictionary: [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 8888,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 8888,
            "SOCKSEnable": 0, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7891,
            "ProxyAutoConfigEnable": 0, "ProxyAutoConfigURLString": "http://x/proxy.pac",
            "ProxyAutoDiscoveryEnable": 1, "ExceptionsList": ["*.local", "169.254/16"],
        ])
        XCTAssertTrue(snapshot.isActive)
        XCTAssertTrue(snapshot.httpActive)
        XCTAssertFalse(snapshot.socksActive)
        XCTAssertFalse(snapshot.pacActive)
        XCTAssertTrue(snapshot.autoDiscovery)
        XCTAssertEqual(snapshot.summary, "127.0.0.1:8888")
        let profile = Profile(name: "本机", color: "#16a34a", kind: .http, host: "127.0.0.1", port: 8888)
        XCTAssertTrue(snapshot.matches(profile))
        let other = Profile(name: "其他", color: "#16a34a", kind: .http, host: "127.0.0.1", port: 8080)
        XCTAssertFalse(snapshot.matches(other))
        let socks = Profile(name: "SOCKS", color: "#16a34a", kind: .socks5, host: "127.0.0.1", port: 7891)
        XCTAssertFalse(snapshot.matches(socks))
        XCTAssertEqual(snapshot.asProfile(name: "系统代理")?.serverAddress, "127.0.0.1:8888")
        XCTAssertFalse(ProxySnapshot(dictionary: [:]).isActive)
        XCTAssertEqual(ProxySnapshot(dictionary: [:]).summary, "未开启")
    }

    func testPacMatchIgnoresCase() {
        let snapshot = ProxySnapshot(dictionary: ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://127.0.0.1:8888/Proxy.pac"])
        let profile = Profile(name: "PAC", color: "#000", kind: .pac, pacURL: "http://127.0.0.1:8888/proxy.pac")
        XCTAssertTrue(snapshot.matches(profile))
        XCTAssertEqual(snapshot.summary, "PAC http://127.0.0.1:8888/Proxy.pac")
    }
}

final class NpmProxyTests: XCTestCase {
    func testUpdate() {
        let content = "registry=https://registry.npmmirror.com\nproxy=http://old:1\nhttps-proxy=http://old:1\n"
        let updated = NpmProxy.update(content, proxyURL: "http://127.0.0.1:8888", noProxy: "localhost")
        XCTAssertEqual(updated, "registry=https://registry.npmmirror.com\nproxy=http://127.0.0.1:8888\nhttps-proxy=http://127.0.0.1:8888\nnoproxy=localhost\n")
        XCTAssertEqual(NpmProxy.update(updated, proxyURL: "", noProxy: ""), "registry=https://registry.npmmirror.com\n")
        XCTAssertEqual(NpmProxy.update("", proxyURL: "", noProxy: ""), "")
    }
}

final class TerminalCommandsTests: XCTestCase {
    func testExportAndFish() {
        let export = TerminalCommands.export(proxyURL: "http://127.0.0.1:8888", noProxy: "it's")
        XCTAssertTrue(export.hasPrefix("export http_proxy='http://127.0.0.1:8888' https_proxy='http://127.0.0.1:8888' all_proxy='http://127.0.0.1:8888' no_proxy='it'\\''s' HTTP_PROXY="))
        let fish = TerminalCommands.fish(proxyURL: "socks5://127.0.0.1:1080", noProxy: "")
        XCTAssertTrue(fish.hasPrefix("set -gx http_proxy 'socks5://127.0.0.1:1080'; set -gx HTTP_PROXY 'socks5://127.0.0.1:1080'; "))
        XCTAssertTrue(fish.contains("set -gx no_proxy '\(Profile.defaultNoProxy)'"))
    }

    func testCopyWithPasswordIsConcealed() {
        // 带密码的命令加上剪贴板历史工具认的标记，不带的不加。
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("proxi-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        TerminalCommands.copy("export http_proxy='http://a:secret@h:1'", concealed: true, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "export http_proxy='http://a:secret@h:1'")
        XCTAssertTrue(pasteboard.types?.contains(TerminalCommands.concealedType) == true)
        TerminalCommands.copy("export http_proxy='http://h:1'", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "export http_proxy='http://h:1'")
        XCTAssertFalse(pasteboard.types?.contains(TerminalCommands.concealedType) == true)
    }
}

final class ParsingTests: XCTestCase {
    func testLsof() {
        let output = "p512\ncCharles\nf23\nn*:8888\nf24\nn127.0.0.1:8889\np9000\ncnode\nf18\nn[::1]:3000\n"
        let listeners = LocalProxyDetector.parseLsof(output)
        XCTAssertEqual(listeners, [
            LocalProxyDetector.Listener(port: 8888, process: "Charles"),
            LocalProxyDetector.Listener(port: 8889, process: "Charles"),
            LocalProxyDetector.Listener(port: 3000, process: "node"),
        ])
    }

    func testURLCommands() {
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://toggle")!), .toggle)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://on")!), .turnOn)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://off")!), .turnOff)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://settings")!), .settings(nil))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://settings?page=about")!), .settings(.about))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://settings?page=nope")!), .settings(nil))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://panel")!), .panel)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://update")!), .update)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://use?name=%E5%85%AC%E5%8F%B8")!), .use("公司"))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://use/home")!), .use("home"))
        XCTAssertNil(URLCommand.parse(URL(string: "proxi://nope")!))
        XCTAssertNil(URLCommand.parse(URL(string: "https://example.com/toggle")!))
    }

    func testServiceSelection() {
        let services = [
            NetworkServices.Service(name: "Wi-Fi", bsdName: "en0", enabled: true),
            NetworkServices.Service(name: "Thunderbolt Bridge", bsdName: "bridge0", enabled: true),
            NetworkServices.Service(name: "Bluetooth PAN", bsdName: "en3", enabled: false),
            NetworkServices.Service(name: "Remote Access", bsdName: nil, enabled: true),
        ]
        XCTAssertEqual(NetworkServices.select(services: services) { $0 == "en0" || $0 == "en3" }, ["Wi-Fi"])
        XCTAssertEqual(NetworkServices.select(services: services) { _ in false }, ["Wi-Fi", "Thunderbolt Bridge", "Remote Access"])
    }

    func testVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.2", than: "1.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1.9", than: "1.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9", than: "1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v0.2.0", than: "0.1.9"))
        // 预发布版本比同号的正式版本旧，但比更早的正式版本新。
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0-beta.1", than: "0.1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0-beta.1", than: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.2.0-beta.1"))
    }

    func testReleaseParse() throws {
        let json = """
        {"tag_name":"v0.2.0","html_url":"https://github.com/whrss9527/proxi/releases/tag/v0.2.0",
         "body":"- 一键更新\\n- 修复","published_at":"2026-09-24T08:56:44Z","draft":false,"prerelease":false,
         "assets":[{"name":"Proxi-macos.zip","size":1186132,"browser_download_url":"https://github.com/whrss9527/proxi/releases/download/v0.2.0/Proxi-macos.zip"},
                   {"name":"SHA256SUMS.txt","size":89,"browser_download_url":"https://github.com/whrss9527/proxi/releases/download/v0.2.0/SHA256SUMS.txt"}]}
        """
        let release = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8)))
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(release.tag, "v0.2.0")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/whrss9527/proxi/releases/tag/v0.2.0")
        XCTAssertEqual(release.notes, "- 一键更新\n- 修复")
        XCTAssertNotNil(release.publishedAt)
        XCTAssertEqual(release.archiveSize, 1186132)
        XCTAssertEqual(release.archiveURL?.lastPathComponent, "Proxi-macos.zip")
        XCTAssertEqual(release.checksumsURL?.lastPathComponent, "SHA256SUMS.txt")
        XCTAssertTrue(release.canInstall)

        let bare = try XCTUnwrap(UpdateChecker.parse(Data(#"{"tag_name":"0.3.0","assets":[]}"#.utf8)))
        XCTAssertEqual(bare.version, "0.3.0")
        XCTAssertFalse(bare.canInstall)
        XCTAssertEqual(bare.pageURL, UpdateChecker.releasesURL)
        XCTAssertNil(UpdateChecker.parse(Data("{}".utf8)))
        XCTAssertNil(UpdateChecker.parse(Data("not json".utf8)))
    }

    func testChangelogParse() {
        let text = """
        # 更新日志

        ## 0.14.4（2026-10-02）

        - 检查到新版本时列出中间每一版的改动。

        ## 0.14.3 (2026-10-01)

        0.14.2 没有发布。

        - 扩展里的部分文字调整。

        ## 0.14.1

        - 代理配置可以填用户名和密码。
        ## 说明
        不是版本号的标题，下面的内容不算进上一版。
        """
        let releases = Changelog.parse(text)
        XCTAssertEqual(releases.map(\.version), ["0.14.4", "0.14.3", "0.14.1"])
        XCTAssertEqual(releases.map(\.date), ["2026-10-02", "2026-10-01", nil])
        XCTAssertEqual(releases[0].notes, "- 检查到新版本时列出中间每一版的改动。")
        XCTAssertEqual(releases[1].notes, "0.14.2 没有发布。\n\n- 扩展里的部分文字调整。")
        XCTAssertEqual(releases[2].notes, "- 代理配置可以填用户名和密码。")
        XCTAssertTrue(Changelog.parse("没有版本").isEmpty)
        XCTAssertNil(Changelog.heading("## 1. future notes"))
        XCTAssertNil(Changelog.heading("## 0.15.bad"))
        XCTAssertEqual(Changelog.heading("## 0.16.0-beta.1")?.version, "0.16.0-beta.1")
    }

    func testChangelogBetweenVersions() {
        // 文件里的顺序乱了也是新的在前。
        let all = Changelog.parse("## 0.14.3（2026-10-01）\n- c\n## 0.15.0（2026-10-03）\n- e\n## 0.14.4（2026-10-02）\n- d\n## 0.14.1（2026-10-01）\n- b\n## 0.12.0（2026-09-30）\n- a")
        XCTAssertEqual(Changelog.releases(all, after: "0.14.1", upTo: "0.14.4").map(\.version), ["0.14.4", "0.14.3"])
        XCTAssertEqual(Changelog.releases(all, after: "0.12.0", upTo: "0.15.0").map(\.version), ["0.15.0", "0.14.4", "0.14.3", "0.14.1"])
        // 当前版本没有自己的一节（标签打了但没有发布）也照样算。
        XCTAssertEqual(Changelog.releases(all, after: "0.14.2", upTo: "0.14.4").map(\.version), ["0.14.4", "0.14.3"])
        XCTAssertEqual(Changelog.releases(all, after: "0.15.0", upTo: "0.15.0"), [])
    }

    func testChangelogURL() {
        XCTAssertEqual(UpdateChecker.changelogURL(tag: "v0.14.4").absoluteString,
                       "https://api.github.com/repos/whrss9527/proxi/contents/CHANGELOG.md?ref=v0.14.4")
    }

    /// 仓库里的 CHANGELOG.md 每一节都认得出版本号和日期：检查到新版本时按它列出中间每一版的改动。
    func testRepositoryChangelogParses() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let releases = Changelog.parse(text)
        XCTAssertFalse(releases.isEmpty)
        XCTAssertEqual(releases.count, text.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.count)
        for release in releases {
            XCTAssertNotNil(release.date, release.version)
            XCTAssertFalse(release.notes.isEmpty, release.version)
        }
        XCTAssertEqual(releases.map(\.version), releases.sorted { UpdateChecker.isNewer($0.version, than: $1.version) }.map(\.version))
    }

    func testChecksums() throws {
        let text = """
        说明行
        0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0  Proxi-macos.zip
        DEADBEEF  太短的
        5891B5B522D5DF086D0FF0B110FBD9D21BB4FC7163AF34D08286A2E846F6BE03 *hello.txt
        """
        XCTAssertEqual(Checksums.parse(text), [
            "Proxi-macos.zip": "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
            "hello.txt": "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03",
        ])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("checksum-\(UUID().uuidString).bin")
        try Data("hello\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Checksums.sha256(of: file), "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    }

    func testInstallPlan() {
        let apps = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let home = URL(fileURLWithPath: "/Users/me/Applications", isDirectory: true)
        let folders = [apps, home]
        let everything: (URL) -> Bool = { _ in true }
        let onlyHome: (URL) -> Bool = { $0 == home }
        let installed = URL(fileURLWithPath: "/Applications/Proxi.app")
        let downloads = URL(fileURLWithPath: "/Users/me/Downloads/Proxi.app")
        let translocated = URL(fileURLWithPath: "/private/var/folders/ab/T/AppTranslocation/1234/d/Proxi.app")

        // 平时：原地替换。
        XCTAssertEqual(InstallLocation.plan(bundle: installed, translocated: false, original: nil, readOnly: false, folders: folders, canWrite: everything),
                       InstallPlan(target: installed, trashAfter: nil, relocating: false))
        // 在下载文件夹里直接打开（被系统搬到临时位置）：装进「应用程序」，旧的移到废纸篓。
        XCTAssertEqual(InstallLocation.plan(bundle: translocated, translocated: true, original: downloads, readOnly: true, folders: folders, canWrite: everything),
                       InstallPlan(target: installed, trashAfter: downloads, relocating: true))
        // 标准账户写不了 /Applications：装进 ~/Applications，不用输密码。
        XCTAssertEqual(InstallLocation.plan(bundle: translocated, translocated: true, original: downloads, readOnly: true, folders: folders, canWrite: onlyHome),
                       InstallPlan(target: home.appendingPathComponent("Proxi.app"), trashAfter: downloads, relocating: true))
        // 本来就在「应用程序」里、只是带着隔离标记被搬走运行：原地替换。
        XCTAssertEqual(InstallLocation.plan(bundle: translocated, translocated: true, original: installed, readOnly: true, folders: folders, canWrite: everything),
                       InstallPlan(target: installed, trashAfter: nil, relocating: false))
        // 找不到原来的位置：装进「应用程序」，不删别的。
        XCTAssertEqual(InstallLocation.plan(bundle: translocated, translocated: true, original: nil, readOnly: true, folders: folders, canWrite: everything),
                       InstallPlan(target: installed, trashAfter: nil, relocating: true))
        // 浏览器给重名文件加了后缀：装回标准名字。
        let renamed = URL(fileURLWithPath: "/Users/me/Downloads/Proxi (1).app")
        XCTAssertEqual(InstallLocation.plan(bundle: translocated, translocated: true, original: renamed, readOnly: true, folders: folders, canWrite: everything)?.target.path, installed.path)
        // 只读的磁盘（比如挂载的映像）：也搬。
        XCTAssertEqual(InstallLocation.plan(bundle: URL(fileURLWithPath: "/Volumes/Proxi/Proxi.app"), translocated: false, original: nil, readOnly: true, folders: folders, canWrite: everything)?.relocating, true)
        // 不是 .app（开发时 swift run）：没法更新。
        XCTAssertNil(InstallLocation.plan(bundle: URL(fileURLWithPath: "/Users/me/.build/debug"), translocated: false, original: nil, readOnly: false, folders: folders, canWrite: everything))
        XCTAssertEqual(InstallLocation.displayName(of: apps), "「应用程序」")
    }

    func testTranslocationLookup() {
        // Security 框架里的函数要能找到，普通位置不算被搬走。
        XCTAssertTrue(Translocation.available)
        XCTAssertFalse(Translocation.isTranslocated(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        XCTAssertTrue(Translocation.isTranslocated(URL(fileURLWithPath: "/private/var/folders/ab/T/AppTranslocation/1234/d/Proxi.app")))
    }

    func testCodeSignatureTeam() throws {
        XCTAssertEqual(CodeSignature.requirementText(teamIdentifier: "ABCDE12345"),
                       #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#)
        // 苹果自带的程序没有 Team ID，不存在的路径也没有。
        XCTAssertNil(CodeSignature.teamIdentifier(of: URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        XCTAssertNil(CodeSignature.teamIdentifier(of: URL(fileURLWithPath: "/nonexistent/Proxi.app")))
        XCTAssertFalse(CodeSignature.isSigned(URL(fileURLWithPath: "/nonexistent/Proxi.app"), byTeam: "ABCDE12345"))
        // 拿 runner 上别家用 Developer ID 签名的程序验证读取和比对：同一个 Team ID 通过，换一个就不通过。
        let candidates = ["/Applications/Firefox.app", "/Applications/Google Chrome.app", "/Applications/Microsoft Edge.app"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            // CI 里必须测到（PROXI_REQUIRE_SIGNED_SAMPLE=1），本机开发时可以跳过。
            if ProcessInfo.processInfo.environment["PROXI_REQUIRE_SIGNED_SAMPLE"] == "1" {
                XCTFail("没有找到 Developer ID 签名的程序：\(candidates)")
                return
            }
            throw XCTSkip("本机没有 Developer ID 签名的程序可以对照")
        }
        let app = URL(fileURLWithPath: path)
        let team = try XCTUnwrap(CodeSignature.teamIdentifier(of: app), path)
        XCTAssertEqual(team.count, 10)
        XCTAssertTrue(CodeSignature.isSigned(app, byTeam: team), path)
        XCTAssertFalse(CodeSignature.isSigned(app, byTeam: team == "ABCDE12345" ? "ZYXWV98765" : "ABCDE12345"), path)
    }

    func testNetworkRoutes() {
        let github = URL(string: "https://github.com/whrss9527/proxi/releases/download/v1/Proxi-macos.zip")!
        var off = ProxySnapshot()
        off.httpEnabled = false
        var other = ProxySnapshot()
        other.httpsEnabled = true; other.httpsHost = "proxy.corp"; other.httpsPort = 3128

        XCTAssertEqual(NetworkRoute.routes(for: github, system: other), [.system, .direct])
        XCTAssertEqual(NetworkRoute.routes(for: github, system: off), [.direct])
        // 本机地址（测试用的发布源）不经代理。
        XCTAssertEqual(NetworkRoute.routes(for: URL(string: "http://127.0.0.1:8765/latest.json")!, system: other), [.direct])

        let configuration = URLSessionConfiguration.ephemeral
        NetworkRoute.direct.apply(to: configuration)
        XCTAssertEqual(configuration.connectionProxyDictionary?.count, 0)
        NetworkRoute.system.apply(to: configuration)
        XCTAssertNil(configuration.connectionProxyDictionary)
    }

    func testThinArchiveSelection() throws {
        let json = """
        {"tag_name":"v0.5.0","assets":[
          {"name":"Proxi-macos.zip","size":49000000,"browser_download_url":"https://x/Proxi-macos.zip"},
          {"name":"Proxi-macos-arm64.zip","size":25000000,"browser_download_url":"https://x/Proxi-macos-arm64.zip"},
          {"name":"SHA256SUMS.txt","size":300,"browser_download_url":"https://x/SHA256SUMS.txt"}]}
        """
        let arm = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8), architecture: "arm64"))
        XCTAssertEqual(arm.archiveName, "Proxi-macos-arm64.zip")
        XCTAssertEqual(arm.archiveSize, 25000000)
        // 没有这个架构的精简包时用通用包。
        let intel = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8), architecture: "x86_64"))
        XCTAssertEqual(intel.archiveName, "Proxi-macos.zip")
        XCTAssertTrue(["arm64", "x86_64"].contains(UpdateChecker.machineArchitecture))
    }

    func testPermissionErrorMapping() {
        func cocoa(_ posix: Int32) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(posix))])
        }
        XCTAssertTrue(UpdateInstaller.needsAdmin(cocoa(EACCES)))
        XCTAssertFalse(UpdateInstaller.isBlockedBySystem(cocoa(EACCES)))
        XCTAssertTrue(UpdateInstaller.isBlockedBySystem(cocoa(EPERM)))
        XCTAssertFalse(UpdateInstaller.needsAdmin(cocoa(EPERM)))
        XCTAssertTrue(UpdateInstaller.needsAdmin(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        XCTAssertFalse(UpdateInstaller.needsAdmin(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }

    func testInstallReplacesAndCreates() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        func makeApp(_ url: URL, marker: String) throws {
            try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: url.appendingPathComponent("Contents/\(marker)"))
        }
        // 替换已有的。
        let target = root.appendingPathComponent("Applications/Proxi.app")
        try makeApp(target, marker: "old")
        let newApp = root.appendingPathComponent("download/Proxi.app")
        try makeApp(newApp, marker: "new")
        try await UpdateInstaller.install(newApp: newApp, replacing: target)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("Contents/new").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("Contents/old").path))
        XCTAssertFalse(fm.fileExists(atPath: newApp.path))
        let leftovers = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Applications").path)
        XCTAssertEqual(leftovers, ["Proxi.app"])
        // 目标文件夹还不存在（比如 ~/Applications）：建出来再放进去。
        let fresh = root.appendingPathComponent("Home/Applications/Proxi.app")
        let another = root.appendingPathComponent("download2/Proxi.app")
        try makeApp(another, marker: "v2")
        try await UpdateInstaller.install(newApp: another, replacing: fresh)
        XCTAssertTrue(fm.fileExists(atPath: fresh.appendingPathComponent("Contents/v2").path))
    }

    func testSyncedConfigRoundTripAndMerge() throws {
        var config = AppConfig()
        config.profiles = [Profile(name: "a", color: "#111111", kind: .socks5, host: "h", port: 1)]
        let synced = SyncedConfig(updatedAt: Date(timeIntervalSince1970: 1_800_000_000), device: "MacBook", config: config)
        let data = try CloudFile.encoder.encode(synced)
        let decoded = try CloudFile.decoder.decode(SyncedConfig.self, from: data)
        XCTAssertEqual(decoded, synced)
        // 只有 config 的老文件也能读。
        let minimal = try CloudFile.decoder.decode(SyncedConfig.self, from: Data(#"{"config":{"profiles":[]}}"#.utf8))
        XCTAssertEqual(minimal.device, "未知设备")
        XCTAssertEqual(minimal.updatedAt, .distantPast)

        let shared = Profile(name: "共有", color: "#111111", host: "1.1.1.1", port: 1)
        var local = AppConfig()
        local.profiles = [shared, Profile(name: "本机独有", color: "#222222", host: "2.2.2.2", port: 2), Profile(name: "同名同地址", color: "#333333", host: "3.3.3.3", port: 3)]
        local.offMode = .restore
        var cloud = AppConfig()
        cloud.profiles = [Profile(name: "云端独有", color: "#444444", host: "4.4.4.4", port: 4), shared, Profile(name: "同名同地址", color: "#555555", host: "3.3.3.3", port: 3)]
        cloud.offMode = .direct
        let merged = local.merging(cloud: cloud)
        XCTAssertEqual(merged.profiles.map(\.name), ["云端独有", "共有", "同名同地址", "本机独有"])
        XCTAssertEqual(merged.offMode, .restore)

        let older = SyncedConfig(updatedAt: Date(timeIntervalSince1970: 1), device: "old", config: AppConfig())
        let newer = SyncedConfig(updatedAt: Date(timeIntervalSince1970: 2), device: "new", config: AppConfig())
        XCTAssertEqual(CloudFile.newest([older, newer, older])?.device, "new")
        XCTAssertNil(CloudFile.newest([]))
    }

    func testDriveDetection() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(CloudFile.driveURL(home: home))
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        XCTAssertEqual(CloudFile.driveURL(home: home)?.lastPathComponent, "com~apple~CloudDocs")
    }

    func testSpeedFormatter() {
        // 数字固定 3 位：整数部分不满 3 位时用小数补足，其余四舍五入；到 999.5 进位到下一个单位。
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 0), "0.00B")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 5), "5.00B")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 12), "12.0B")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 999), "999B")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 1000), "0.98K")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 1024), "1.00K")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 6_144), "6.00K")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 9_900), "9.67K")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 12_595), "12.3K")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 512_000), "500K")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 1_023_500), "0.98M")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 1_258_291), "1.20M")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 125_829_120), "120M")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 2_147_483_648), "2.00G")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 5_000_000_000_000), "999G")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: -5), "0.00B")
        // 任何数值都是 3 位数字加 B / K / M / G。
        for value in Array(stride(from: 0, to: 5_000_000_000, by: 7_777_777)) + [9, 99, 100, 999, 1000, 1023, 1024, 10_234, 102_400, 1_023_999, 1_048_575, 1_048_576] {
            let text = SpeedFormatter.compact(bytesPerSecond: value)
            XCTAssertEqual(text.filter(\.isNumber).count, 3, "\(value) → \(text)")
            XCTAssertTrue(["B", "K", "M", "G"].contains(String(text.last ?? " ")), "\(value) → \(text)")
        }
        XCTAssertTrue(SpeedFormatter.full(bytesPerSecond: 2048).hasSuffix("/s"))
        // 32 位计数回绕后的差值也对。
        let old = ["en0": InterfaceCounters.Sample(received: UInt32.max - 10, sent: 100)]
        let new = ["en0": InterfaceCounters.Sample(received: 20, sent: 150), "en1": InterfaceCounters.Sample(received: 5, sent: 5)]
        let delta = InterfaceCounters.delta(from: old, to: new)
        XCTAssertEqual(delta.received, 31)
        XCTAssertEqual(delta.sent, 50)
        XCTAssertNotNil(InterfaceCounters.read())
    }

    /// 菜单栏图标带网速时，两行小字的墨迹中线要和开关的中线重合，两个箭头要左右对齐（按像素检查真实渲染的结果）。
    func testStatusIconSpeedAlignment() throws {
        // 8.0K 对 45K：位数、小数点都不一样，以前右对齐整行会让箭头错位。
        let pairs: [(Int, Int)] = [(8_192, 46_080), (14_000_000, 15_000_000), (999, 1_258_291)]
        for (up, down) in pairs {
            let upload = SpeedFormatter.compact(bytesPerSecond: up)
            let download = SpeedFormatter.compact(bytesPerSecond: down)
            for state in [StatusIconState.off, .on(NSColor.systemGreen), .external] {
                for side in [SpeedLayout.speedLeft, .speedRight] {
                    let image = StatusIcon.image(for: state, upload: upload, download: download, textColor: NSColor.black.cgColor, layout: side)
                    XCTAssertEqual(image.size.height, StatusIcon.speedHeight)
                    XCTAssertEqual(image.isTemplate, state == .off)
                    let scale: CGFloat = 2
                    let bitmap = try XCTUnwrap(StatusIcon.bitmap(of: image, scale: scale))
                    let iconWidth = Int(StatusIcon.iconSize.width * scale)
                    let gapHalf = Int(StatusIcon.speedGap * scale) / 2
                    // 网速在左边时开关在最右边，反之开关在最左边。
                    let iconRange = side == .speedLeft ? (bitmap.pixelsWide - iconWidth)..<bitmap.pixelsWide : 0..<iconWidth
                    let textRange = side == .speedLeft ? 0..<(bitmap.pixelsWide - iconWidth - gapHalf) : (iconWidth + gapHalf)..<bitmap.pixelsWide
                    let icon = try XCTUnwrap(inkRows(bitmap, xRange: iconRange))
                    let text = try XCTUnwrap(inkRows(bitmap, xRange: textRange))
                    let iconCenter = Double(icon.min + icon.max) / 2
                    let textCenter = Double(text.min + text.max) / 2
                    XCTAssertLessThanOrEqual(abs(iconCenter - textCenter), 1.5, "\(upload)/\(download) \(state) \(side)：开关中线 \(iconCenter)，网速中线 \(textCenter)（像素，2x）")
                    // 两行都画出来了，而且没有贴到边上被裁掉。
                    XCTAssertGreaterThan(text.max - text.min, Int(StatusIcon.speedLinePitch * scale))
                    XCTAssertGreaterThan(text.min, 0)
                    XCTAssertLessThan(text.max, bitmap.pixelsHigh - 1)
                    // 箭头单独占一列：上下两行网速最左边的墨迹（就是箭头）在同一列。
                    let half = bitmap.pixelsHigh / 2
                    let top = try XCTUnwrap(inkColumns(bitmap, xRange: textRange, yRange: 0..<half))
                    let bottom = try XCTUnwrap(inkColumns(bitmap, xRange: textRange, yRange: half..<bitmap.pixelsHigh))
                    XCTAssertLessThanOrEqual(abs(top.min - bottom.min), 1, "\(upload)/\(download) \(side)：上行箭头 x=\(top.min)，下行箭头 x=\(bottom.min)")
                    // 数字紧跟箭头：每行里相邻墨迹之间最大的空隙（箭头和数字之间）不超过几个像素，不会空出一截补位的空格。
                    XCTAssertLessThanOrEqual(largestGap(bitmap, xRange: textRange, yRange: 0..<half), 8, "\(upload) \(side)：箭头和数字之间空得太大")
                    XCTAssertLessThanOrEqual(largestGap(bitmap, xRange: textRange, yRange: half..<bitmap.pixelsHigh), 8, "\(download) \(side)：箭头和数字之间空得太大")
                    // 开关和网速之间留着间距，没有画到一起；但也挨得很近，不超过 6 个点。
                    let iconColumns = try XCTUnwrap(inkColumns(bitmap, xRange: iconRange, yRange: 0..<bitmap.pixelsHigh))
                    if side == .speedLeft {
                        let textEnd = max(top.max, bottom.max)
                        XCTAssertGreaterThan(iconColumns.min, textEnd)
                        XCTAssertLessThanOrEqual(iconColumns.min - textEnd, Int(6 * scale), "\(upload)/\(download)：网速和开关之间空得太大")
                    } else {
                        let textStart = min(top.min, bottom.min)
                        XCTAssertLessThan(iconColumns.max, textStart)
                        XCTAssertLessThanOrEqual(textStart - iconColumns.max, Int(6 * scale), "\(upload)/\(download)：开关和网速之间空得太大")
                    }
                }
            }
        }
        // 数值变了图标宽度不变（图标不会跟着跳）。
        XCTAssertEqual(StatusIcon.image(for: .off, upload: SpeedFormatter.compact(bytesPerSecond: 0), download: SpeedFormatter.compact(bytesPerSecond: 0), textColor: NSColor.black.cgColor).size.width,
                       StatusIcon.image(for: .off, upload: SpeedFormatter.compact(bytesPerSecond: 1_000_000_000), download: SpeedFormatter.compact(bytesPerSecond: 999_000), textColor: NSColor.black.cgColor).size.width)
        // 没有网速时还是原来的小开关。
        XCTAssertEqual(StatusIcon.image(for: .off).size, StatusIcon.iconSize)
    }

    /// 「关代理时只显示网速」：关着只有网速，开着开关出现在网速左边（网速的位置不动，只是左边多了开关）。
    func testSpeedOnlyLayout() throws {
        XCTAssertEqual(SpeedLayout.resolve(side: .speedOnly, state: .off), .speedOnly)
        XCTAssertEqual(SpeedLayout.resolve(side: .speedOnly, state: .on(.systemGreen)), .speedRight)
        XCTAssertEqual(SpeedLayout.resolve(side: .speedOnly, state: .external), .speedRight)
        XCTAssertEqual(SpeedLayout.resolve(side: .speedOnly, state: .warning(.systemGreen)), .speedRight)
        XCTAssertEqual(SpeedLayout.resolve(side: .left, state: .off), .speedLeft)
        XCTAssertEqual(SpeedLayout.resolve(side: .right, state: .on(.systemBlue)), .speedRight)

        let upload = SpeedFormatter.compact(bytesPerSecond: 12_595)
        let download = SpeedFormatter.compact(bytesPerSecond: 1_258_291)
        let only = StatusIcon.image(for: .off, upload: upload, download: download, textColor: NSColor.black.cgColor, layout: .speedOnly)
        let withSwitch = StatusIcon.image(for: .on(.systemGreen), upload: upload, download: download, textColor: NSColor.black.cgColor, layout: .speedRight)
        XCTAssertTrue(only.isTemplate)
        XCTAssertEqual(only.size.height, StatusIcon.speedHeight)
        // 开关加在左边：只多了开关和间距那么宽。
        XCTAssertEqual(withSwitch.size.width - only.size.width, StatusIcon.iconSize.width + StatusIcon.speedGap, accuracy: 0.01)
        // 只有网速时整张图都是文字：两个箭头对齐，墨迹从最左边附近开始。
        let scale: CGFloat = 2
        let bitmap = try XCTUnwrap(StatusIcon.bitmap(of: only, scale: scale))
        let half = bitmap.pixelsHigh / 2
        let top = try XCTUnwrap(inkColumns(bitmap, xRange: 0..<bitmap.pixelsWide, yRange: 0..<half))
        let bottom = try XCTUnwrap(inkColumns(bitmap, xRange: 0..<bitmap.pixelsWide, yRange: half..<bitmap.pixelsHigh))
        XCTAssertLessThanOrEqual(abs(top.min - bottom.min), 1)
        XCTAssertLessThanOrEqual(top.min, 4)
    }

    /// 网速文字跟着代理状态变色：颜色和开关同色相，和菜单栏底色的对比度至少 4.5:1；关着时不变色。
    func testSpeedTextColors() {
        XCTAssertNil(StatusIcon.speedTextColor(for: .off, darkMenuBar: false))
        let palette: [StatusIconState] = ProfilePalette.colors.map { StatusIconState.on(NSColor(hex: $0)) }
        let states: [StatusIconState] = palette + [.external, .warning(NSColor(hex: "#16a34a")), .error]
        for state in states {
            for dark in [false, true] {
                let color = StatusIcon.speedTextColor(for: state, darkMenuBar: dark)!
                let background: NSColor = dark ? .darkMenuBarBackground : .lightMenuBarBackground
                XCTAssertGreaterThanOrEqual(NSColor.contrast(color, background), 4.5, "\(state) \(dark ? "深色" : "浅色")")
            }
        }
        // 连不上时是红色（红色分量最大）。
        let warning = StatusIcon.speedTextColor(for: .warning(NSColor(hex: "#2563eb")), darkMenuBar: false)!.usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(warning.redComponent, warning.blueComponent)
        XCTAssertEqual(NSColor.contrast(.black, .white), 21, accuracy: 0.01)
    }

    /// 把各种状态、三种摆法、深浅两种菜单栏画成一张对照图（设置了 PROXI_ICON_PREVIEW_DIR 时才画，CI 里用来看效果）。
    func testRenderIconPreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["PROXI_ICON_PREVIEW_DIR"] else { return }
        let states: [(String, StatusIconState)] = [("关", .off), ("开·绿", .on(NSColor(hex: "#16a34a"))), ("开·蓝", .on(NSColor(hex: "#2563eb"))), ("别的程序", .external), ("连不上", .warning(NSColor(hex: "#16a34a")))]
        let sides: [SpeedSide] = [.left, .right, .speedOnly]
        let upload = SpeedFormatter.compact(bytesPerSecond: 12_595)
        let download = SpeedFormatter.compact(bytesPerSecond: 1_258_291)
        let cell = NSSize(width: 110, height: 28)
        let labelWidth: CGFloat = 60
        let canvas = NSSize(width: labelWidth + cell.width * CGFloat(sides.count), height: cell.height * CGFloat(states.count * 2) + 18)
        let scale: CGFloat = 3
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: canvas).fill()
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.darkGray]
        for (column, side) in sides.enumerated() {
            (side.title as NSString).draw(at: NSPoint(x: labelWidth + CGFloat(column) * cell.width + 4, y: canvas.height - 14), withAttributes: labelAttributes)
        }
        for dark in [false, true] {
            for (row, entry) in states.enumerated() {
                let index = (dark ? states.count : 0) + row
                let y = canvas.height - 18 - cell.height * CGFloat(index + 1)
                let background: NSColor = dark ? .darkMenuBarBackground : .lightMenuBarBackground
                background.setFill()
                NSRect(x: labelWidth, y: y, width: cell.width * CGFloat(sides.count), height: cell.height).fill()
                ("\(entry.0)\(dark ? "·深" : "·浅")" as NSString).draw(at: NSPoint(x: 4, y: y + 9), withAttributes: labelAttributes)
                let label: NSColor = dark ? .white : .black
                for (column, side) in sides.enumerated() {
                    let color = StatusIcon.speedTextColor(for: entry.1, darkMenuBar: dark) ?? label
                    var image = StatusIcon.image(for: entry.1, upload: upload, download: download, textColor: color.cgColor, layout: SpeedLayout.resolve(side: side, state: entry.1))
                    if image.isTemplate {
                        // 模板图由系统上色，这里按菜单栏深浅手动上色。
                        let template = image
                        image = NSImage(size: template.size, flipped: false) { rect in
                            template.draw(in: rect)
                            label.set()
                            rect.fill(using: .sourceAtop)
                            return true
                        }
                    }
                    let x = labelWidth + CGFloat(column) * cell.width + (cell.width - image.size.width) / 2
                    image.draw(in: NSRect(x: x, y: y + (cell.height - image.size.height) / 2, width: image.size.width, height: image.size.height))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("icon-preview.png"))
    }

    /// 某个区域里相邻两列墨迹之间最大的空白宽度（像素）。
    private func largestGap(_ bitmap: NSBitmapImageRep, xRange: Range<Int>, yRange: Range<Int>) -> Int {
        var previous: Int?
        var largest = 0
        for x in xRange where x >= 0 && x < bitmap.pixelsWide {
            var inked = false
            for y in yRange where y >= 0 && y < bitmap.pixelsHigh {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.25 {
                    inked = true
                    break
                }
            }
            guard inked else { continue }
            if let previous {
                largest = max(largest, x - previous - 1)
            }
            previous = x
        }
        return largest
    }

    /// 位图里某个区域内有墨迹（不透明）的最左和最右一列。
    private func inkColumns(_ bitmap: NSBitmapImageRep, xRange: Range<Int>, yRange: Range<Int>) -> (min: Int, max: Int)? {
        var minX = Int.max
        var maxX = Int.min
        for y in yRange where y >= 0 && y < bitmap.pixelsHigh {
            for x in xRange where x >= 0 && x < bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.25 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        return minX == Int.max ? nil : (minX, maxX)
    }

    /// 位图里某个横向范围内有墨迹（不透明）的最上和最下一行。
    private func inkRows(_ bitmap: NSBitmapImageRep, xRange: Range<Int>) -> (min: Int, max: Int)? {
        var minY = Int.max
        var maxY = Int.min
        for y in 0..<bitmap.pixelsHigh {
            for x in xRange where x >= 0 && x < bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.25 {
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        return minY == Int.max ? nil : (minY, maxY)
    }

    func testReleaseNotesCleaning() {
        let notes = "## 0.2.0\r\n\r\n- 一键更新\r\n  * 子项\r\n普通一行"
        XCTAssertEqual(ReleaseNotes.cleaned(notes), "0.2.0\n\n• 一键更新\n• 子项\n普通一行")
    }

    func testProxyAddressParse() {
        XCTAssertEqual(ProxyAddress.parse("127.0.0.1:7890"), ProxyAddress(kind: nil, host: "127.0.0.1", port: 7890))
        XCTAssertEqual(ProxyAddress.parse(" http://127.0.0.1:7890/ "), ProxyAddress(kind: .http, host: "127.0.0.1", port: 7890))
        XCTAssertEqual(ProxyAddress.parse("socks5://user:pass@proxy.corp:1080"), ProxyAddress(kind: .socks5, host: "proxy.corp", port: 1080, username: "user", password: "pass"))
        // 粘贴带用户名和密码的地址：按网址的规则解码，填到登录那一栏。
        XCTAssertEqual(ProxyAddress.parse("http://alice%40corp:p%40ss%3Aword@proxy.corp:3128"), ProxyAddress(kind: .http, host: "proxy.corp", port: 3128, username: "alice@corp", password: "p@ss:word"))
        XCTAssertEqual(ProxyAddress.parse("bob@proxy.corp:3128"), ProxyAddress(kind: nil, host: "proxy.corp", port: 3128, username: "bob", password: nil))
        XCTAssertEqual(ProxyAddress.parse("[::1]:1080"), ProxyAddress(kind: nil, host: "::1", port: 1080))
        XCTAssertEqual(ProxyAddress.parse("https://proxy.corp"), ProxyAddress(kind: .http, host: "proxy.corp", port: nil))
        XCTAssertEqual(ProxyAddress.parse("proxy.corp"), ProxyAddress(kind: nil, host: "proxy.corp", port: nil))
        XCTAssertFalse(ProxyAddress.parse("proxy.corp")!.splitsFields)
        XCTAssertTrue(ProxyAddress.parse("proxy.corp:3128")!.splitsFields)
        XCTAssertNil(ProxyAddress.parse(""))
        XCTAssertNil(ProxyAddress.parse("ftp://x:1"))
        XCTAssertNil(ProxyAddress.parse("host:abc"))
        XCTAssertNil(ProxyAddress.parse("host:70000"))
    }

    func testProfileValidation() {
        var profile = Profile(name: "x", color: "#000", kind: .http, host: "127.0.0.1", port: 7890)
        XCTAssertNil(profile.validate())
        profile.port = 70000
        XCTAssertNotNil(profile.validate())
        profile.port = 80
        profile.host = "a b"
        XCTAssertNotNil(profile.validate())
        var pac = Profile(name: "p", color: "#000", kind: .pac, pacURL: "ftp://x")
        XCTAssertNotNil(pac.validate())
        pac.pacURL = "http://127.0.0.1/proxy.pac"
        XCTAssertNil(pac.validate())
        var empty = Profile(name: "e", color: "#000")
        empty.targets = []
        XCTAssertNotNil(empty.validate())
    }

    @MainActor
    func testCloudSyncPullAndPush() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        var remoteConfig = AppConfig()
        remoteConfig.profiles = [Profile(name: "云端", color: "#111111", host: "10.0.0.1", port: 8080)]
        try CloudFile.write(SyncedConfig(updatedAt: Date(), device: "另一台 Mac", config: remoteConfig), to: file)

        let sync = CloudSync(folder: folder)
        var current = AppConfig()
        var applied: AppConfig?
        var enabledFlags: [Bool] = []
        sync.currentConfig = { current }
        sync.applyRemote = { applied = $0; current = $0 }
        sync.onEnabledChanged = { enabledFlags.append($0) }

        // 启动时按记录的开关恢复：读到云端的配置就应用。
        sync.start(enabled: true)
        await sync.syncNow()
        XCTAssertEqual(applied, remoteConfig)
        guard case .synced(_, let device) = sync.status else { return XCTFail("状态不对：\(sync.status)") }
        XCTAssertEqual(device, "另一台 Mac")

        // 本机改动稍后写到云端。
        current.profiles.append(Profile(name: "本机", color: "#222222", host: "10.0.0.2", port: 9090))
        sync.localChanged(current)
        try await Task.sleep(for: .seconds(2))
        let written = try XCTUnwrap(try CloudFile.read(at: file))
        XCTAssertEqual(written.config, current)
        XCTAssertEqual(written.device, CloudFile.deviceName)

        // 关掉后不再写。
        sync.disable()
        XCTAssertEqual(enabledFlags, [false])
        XCTAssertEqual(sync.status, .off)
        current.profiles.removeAll()
        sync.localChanged(current)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(try CloudFile.read(at: file)?.config.profiles.count, 2)
    }

    @MainActor
    func testCloudSyncEnableAsksWhenCloudDiffers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        var remoteConfig = AppConfig()
        remoteConfig.profiles = [Profile(name: "云端", color: "#111111", host: "10.0.0.1", port: 8080)]
        try CloudFile.write(SyncedConfig(updatedAt: Date(), device: "另一台 Mac", config: remoteConfig), to: file)

        let sync = CloudSync(folder: folder)
        var current = AppConfig()
        current.profiles = [Profile(name: "本机", color: "#222222", host: "10.0.0.2", port: 9090)]
        sync.currentConfig = { current }
        sync.applyRemote = { current = $0 }
        await sync.enable()
        XCTAssertFalse(sync.enabled)
        XCTAssertEqual(sync.pending?.device, "另一台 Mac")

        sync.resolve(.merge)
        XCTAssertNil(sync.pending)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(sync.enabled)
        XCTAssertEqual(current.profiles.map(\.name), ["云端", "本机"])
        let written = try XCTUnwrap(try CloudFile.read(at: file))
        XCTAssertEqual(written.config.profiles.map(\.name), ["云端", "本机"])

        // 云端没有文件时直接开启并把本机的写上去。
        let empty = CloudSync(folder: folder.appendingPathComponent("empty", isDirectory: true))
        empty.currentConfig = { current }
        await empty.enable()
        XCTAssertTrue(empty.enabled)
        XCTAssertEqual(try CloudFile.read(at: folder.appendingPathComponent("empty/config.json"))?.config, current)
    }

    func testConfigRoundTrip() throws {
        var config = AppConfig()
        config.profiles = [Profile(name: "a", color: "#111111", kind: .socks5, host: "h", port: 1)]
        config.toggleHotkey = nil
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertNil(decoded.toggleHotkey)
        XCTAssertTrue(decoded.autoCheckUpdates)
        // 缺少 toggleHotkey 键时用默认快捷键。
        let minimal = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(minimal.toggleHotkey, HotkeyBinding.defaultToggle)
        XCTAssertEqual(minimal.speedSide, .left)
        config.speedSide = .right
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: try JSONEncoder().encode(config)).speedSide, .right)
    }

    /// 新版本加的取值（或者手改坏了的一项）不让整个配置读失败：那一项用默认值，读不出来的那条配置跳过，其余照样读出来。
    func testConfigToleratesUnknownValues() throws {
        let json = #"""
        {"profiles":[
          {"name":"公司代理","kind":"http","host":"proxy.corp.example","port":3128,"targets":["system","git","future"]},
          {"name":"新类型","kind":"quic","host":"127.0.0.1","port":443,"targets":["future"]},
          "坏掉的一条",
          {"name":"调试","kind":"socks5","host":"127.0.0.1","port":1080}
        ],
        "offMode":"something-new","clickAction":42,"notifyLevel":"problems","speedSide":"middle"}
        """#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.profiles.map(\.name), ["公司代理", "新类型", "调试"])
        XCTAssertEqual(config.profiles[0].targets, [.system, .git])
        XCTAssertEqual(config.profiles[1].kind, .http)
        XCTAssertEqual(config.profiles[1].targets, [.system])
        XCTAssertEqual(config.profiles[2].kind, .socks5)
        XCTAssertEqual(config.offMode, .direct)
        XCTAssertEqual(config.clickAction, .panel)
        XCTAssertEqual(config.notifyLevel, .problems)
        XCTAssertEqual(config.speedSide, .left)
    }

    /// 只改了名字或颜色的配置不用重新应用（重新写系统代理可能要输管理员密码）。
    func testAppliesSameIgnoresNameAndColor() {
        let profile = Profile(name: "公司代理", color: "#16a34a", kind: .http, host: "proxy.corp.example", port: 3128)
        var renamed = profile
        renamed.name = "办公室"
        renamed.color = "#2563eb"
        XCTAssertTrue(renamed.appliesSame(as: profile))
        var moved = profile
        moved.port = 8080
        XCTAssertFalse(moved.appliesSame(as: profile))
        var narrowed = profile
        narrowed.targets = [.system, .git]
        XCTAssertFalse(narrowed.appliesSame(as: profile))
    }
}

/// 要登录的代理：密码只在钥匙串里，配置里只有标记；环境变量、git、npm 的地址带上转义过的用户名和密码，系统代理交给 networksetup。
final class CredentialsTests: XCTestCase {
    func testProxyURLWithCredentials() {
        var profile = Profile(name: "公司", color: "#000", kind: .http, host: "proxy.corp", port: 3128)
        XCTAssertEqual(profile.proxyURL, "http://proxy.corp:3128")
        XCTAssertFalse(profile.hasCredentials)
        XCTAssertFalse(profile.needsPassword)
        profile.username = "me@corp"
        profile.hasPassword = true
        XCTAssertTrue(profile.needsPassword)
        XCTAssertEqual(profile.proxyURL(password: "p@ss:w/rd"), "http://me%40corp:p%40ss%3Aw%2Frd@proxy.corp:3128")
        // 不给密码时只带用户名；列表里显示的不带密码。
        XCTAssertEqual(profile.proxyURL, "http://me%40corp@proxy.corp:3128")
        XCTAssertEqual(profile.summary, "me@corp@proxy.corp:3128")
        profile.kind = .socks5
        XCTAssertEqual(profile.proxyURL(password: "x"), "socks5://me%40corp:x@proxy.corp:3128")
        profile.kind = .pac
        XCTAssertFalse(profile.needsPassword)
        var ipv6 = Profile(name: "v6", color: "#000", kind: .http, host: "::1", port: 8080)
        XCTAssertEqual(ipv6.proxyURL, "http://[::1]:8080")
        ipv6.host = "[::1]"
        XCTAssertEqual(ipv6.serverAddress, "[::1]:8080")
    }

    func testNetworksetupWithCredentials() {
        var profile = Profile(name: "公司", color: "#000", kind: .http, host: "proxy.corp", port: 3128)
        profile.username = "me"
        profile.hasPassword = true
        let commands = DesiredProxy(profile: profile, password: "secret").commands(service: "Wi-Fi")
        XCTAssertEqual(commands.first, ["-setwebproxy", "Wi-Fi", "proxy.corp", "3128", "on", "me", "secret"])
        XCTAssertTrue(commands.contains(["-setsecurewebproxy", "Wi-Fi", "proxy.corp", "3128", "on", "me", "secret"]))
        let dictionary = ProxyTester.proxyDictionary(for: profile, password: "secret")
        XCTAssertEqual(dictionary[kCFProxyUsernameKey as String] as? String, "me")
        XCTAssertEqual(dictionary[kCFProxyPasswordKey as String] as? String, "secret")
    }

    /// 配置文件（以及 iCloud 同步的内容）里只有「有没有密码」，没有密码本身。
    func testPasswordNeverEncoded() throws {
        var profile = Profile(name: "公司", color: "#000", kind: .http, host: "proxy.corp", port: 3128)
        profile.username = "me"
        profile.hasPassword = true
        var config = AppConfig()
        config.profiles = [profile]
        let data = try JSONEncoder().encode(SyncedConfig(updatedAt: Date(), device: "x", config: config))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"hasPassword\":true"), text)
        XCTAssertFalse(text.contains("\"password\""), text)
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
        // 写着密码的旧文件：密码不读进来。
        let old = try JSONDecoder().decode(Profile.self, from: Data(#"{"name":"x","host":"h","port":1,"username":"u","password":"leak"}"#.utf8))
        XCTAssertFalse(old.hasPassword)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("leak"))
    }

    func testRedaction() {
        XCTAssertEqual(Redact.secrets("http_proxy=http://dev:p%40ss%20word@devproxy.example:8080"), "http_proxy=http://dev:***@devproxy.example:8080")
        XCTAssertEqual(Redact.secrets("socks5://u:x@h:1 and http://a:b@c"), "socks5://u:***@h:1 and http://a:***@c")
        XCTAssertEqual(Redact.secrets("http://me@proxy:3128"), "http://me@proxy:3128")
        XCTAssertEqual(Redact.secrets("mail me@example.com"), "mail me@example.com")
        XCTAssertEqual(Redact.secrets("proxy=http://h:8080"), "proxy=http://h:8080")
    }

    func testRedactsKnownPasswordsInAnyForm() {
        let password = #"p@ss wo'rd"\x"#
        // networksetup 的参数里是原样的；授权对话框那条路上还要经过 shell 单引号和 AppleScript 字符串的转义。
        let desired = DesiredProxy(profile: Profile(name: "公司代理", color: "#2563eb", host: "proxy.corp.example", port: 3128), password: password)
        XCTAssertEqual(desired.passwords, [])
        var profile = Profile(name: "公司代理", color: "#2563eb", host: "proxy.corp.example", port: 3128)
        profile.username = "alice"
        let withLogin = DesiredProxy(profile: profile, password: password)
        XCTAssertEqual(Set(withLogin.passwords), [password])
        let arguments = withLogin.commands(service: "Wi-Fi").first { $0.contains(password) } ?? []
        XCTAssertFalse(arguments.isEmpty)
        let raw = "networksetup " + arguments.joined(separator: " ") + " failed"
        let shell = arguments.map(Shell.shellQuote).joined(separator: " ")
        let script = Shell.appleScriptString(shell)
        let url = profile.proxyURL(password: password)
        for text in [raw, shell, script, "proxy=\(url)", "http://alice:\(password)@proxy.corp.example:3128"] {
            let redacted = Redact.secrets(text, known: withLogin.passwords)
            XCTAssertFalse(redacted.contains("ss wo"), redacted)
            XCTAssertFalse(redacted.contains("p%40ss"), redacted)
            XCTAssertTrue(redacted.contains("***"), redacted)
        }
        XCTAssertTrue(Redact.secrets(raw, known: withLogin.passwords).contains("alice"))
        // 太短的不换，免得把整段话换得看不懂；网址里的照样遮住。
        XCTAssertEqual(Redact.secrets("on alice ab failed", known: ["ab"]), "on alice ab failed")
        XCTAssertEqual(Redact.secrets("http://alice:ab@h:1", known: ["ab"]), "http://alice:***@h:1")
    }

    func testGitCredentialFile() {
        let content = GitProxy.credentialFileContent(proxyURL: "http://dev:p%40ss@h:8080")
        XCTAssertTrue(content.contains("[http]\n\tproxy = \"http://dev:p%40ss@h:8080\"\n"), content)
        XCTAssertTrue(content.contains("[https]\n\tproxy = "), content)
        XCTAssertEqual(GitProxy.pathPattern("/Users/me/Library/Application Support/Proxi/git-proxy.inc"),
                       "^/Users/me/Library/Application Support/Proxi/git-proxy\\.inc$")
        XCTAssertTrue(GitProxy.credentialFile.path.hasSuffix("/Proxi/git-proxy.inc"))
    }

    /// 真的写进钥匙串再读出来、删掉（runner 的钥匙串不能用时跳过）。
    func testKeychainRoundTrip() throws {
        let id = UUID()
        do {
            try ProxyKeychain.set("first", for: id)
        } catch {
            throw XCTSkip("钥匙串不能用：\(error.localizedDescription)")
        }
        defer { ProxyKeychain.delete(for: id) }
        XCTAssertEqual(ProxyKeychain.password(for: id), "first")
        try ProxyKeychain.set("second", for: id)
        XCTAssertEqual(ProxyKeychain.password(for: id), "second")
        ProxyKeychain.delete(for: id)
        XCTAssertNil(ProxyKeychain.password(for: id))
    }

    func testEnvironmentNamesAndTerminalCommands() {
        XCTAssertEqual(EnvironmentProxy.names, ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"])
        let export = TerminalCommands.export(proxyURL: "socks5://127.0.0.1:1080", noProxy: "localhost")
        XCTAssertTrue(export.contains("all_proxy='socks5://127.0.0.1:1080'"), export)
        XCTAssertTrue(export.contains("ALL_PROXY='socks5://127.0.0.1:1080'"), export)
        XCTAssertTrue(TerminalCommands.fish(proxyURL: "http://h:1", noProxy: "").contains("set -gx all_proxy 'http://h:1'"))
    }
}

/// 从以前的版本更新过来：读配置时去掉以前版本的设置，代理引擎的数据挪到它自己的目录（不删），找出要关掉的代理和后台助手。
final class LegacyCleanupTests: XCTestCase {
    private let builtInID = "6D2F2A1E-0000-4000-8000-0000000000AA"
    private let plainID = "6D2F2A1E-0000-4000-8000-000000000001"

    private var legacyConfig: Data {
        Data("""
        {"profiles":[{"id":"\(builtInID)","name":"Built-in","color":"#2563eb","kind":"http","host":"127.0.0.1","port":7890,"engine":true,"targets":["system","git"]},
                     {"id":"\(plainID)","name":"公司代理","color":"#16a34a","kind":"http","host":"proxy.corp","port":3128}],
         "engine":{"mode":"rule","mixedPort":7890},
         "speedDisplay":"engine",
         "testURL":"https://cp.cloudflare.com/generate_204",
         "automation":{"permission":"full","networkRules":[{"match":"other","action":"mode:global"}]}}
        """.utf8)
    }

    func testConfigDropsLegacySettings() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: legacyConfig)
        XCTAssertEqual(config.profiles.map(\.name), ["公司代理"])
        XCTAssertEqual(config.speedDisplay, .system)
        XCTAssertEqual(config.testURL, AppConfig.defaultTestURL)
        XCTAssertEqual(config.automation.permission, .operate)
        XCTAssertTrue(config.automation.networkRules.isEmpty)
        // 写回去的配置里没有以前版本的设置。
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertNil(written["engine"])
        let profiles = try XCTUnwrap(written["profiles"] as? [[String: Any]])
        XCTAssertNil(profiles.first?["engine"])
        // 自己填的测速地址不动。
        let custom = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"testURL":"http://intranet.example/ping"}"#.utf8))
        XCTAssertEqual(custom.testURL, "http://intranet.example/ping")
        XCTAssertEqual(AppConfig().testURL, "https://www.apple.com/library/test/success.html")
    }

    func testInspectFindsTheActiveBuiltInProfile() {
        let state = Data(#"{"lastProfileID":"\#(builtInID)","enabledByUs":true,"share":{"enabled":true}}"#.utf8)
        let findings = LegacyCleanup.inspect(configData: legacyConfig, stateData: state)
        XCTAssertTrue(findings.hadLegacySettings)
        XCTAssertTrue(findings.needsMigration)
        XCTAssertTrue(findings.hasEngineData)
        XCTAssertEqual(findings.builtInProfiles.map(\.id.uuidString), [builtInID])
        XCTAssertEqual(findings.activeBuiltIn?.targets, [.system, .git])
        XCTAssertEqual(findings.activeBuiltIn?.port, 7890)

        // 没开着，或者开着的是自己的配置：不用关。
        let off = Data(#"{"lastProfileID":"\#(builtInID)","enabledByUs":false}"#.utf8)
        XCTAssertNil(LegacyCleanup.inspect(configData: legacyConfig, stateData: off).activeBuiltIn)
        let plain = Data(#"{"lastProfileID":"\#(plainID)","enabledByUs":true}"#.utf8)
        XCTAssertNil(LegacyCleanup.inspect(configData: legacyConfig, stateData: plain).activeBuiltIn)
    }

    func testFreshConfigNeedsNothing() throws {
        var config = AppConfig()
        config.profiles = [Profile(name: "Charles", color: "#000", host: "127.0.0.1", port: 8888)]
        let findings = LegacyCleanup.inspect(configData: try JSONEncoder().encode(config), stateData: try JSONEncoder().encode(PersistedState()))
        XCTAssertFalse(findings.needsMigration)
        XCTAssertFalse(findings.hasEngineData)
        XCTAssertNil(findings.activeBuiltIn)
        XCTAssertFalse(LegacyCleanup.inspect(configData: nil, stateData: nil).needsMigration)
        // 以前版本里只有代理引擎的默认设置、没有订阅和节点：要迁移，但不算有数据（不弹说明）。
        let bare = LegacyCleanup.inspect(configData: Data(#"{"profiles":[],"engine":{"mode":"rule","subscriptions":[]}}"#.utf8), stateData: nil)
        XCTAssertTrue(bare.needsMigration)
        XCTAssertFalse(bare.hasEngineData)
        let withNodes = LegacyCleanup.inspect(configData: Data(#"{"engine":{"manualNodes":[{"name":"a","link":"ss://x"}]}}"#.utf8), stateData: nil)
        XCTAssertTrue(withNodes.hasEngineData)
        let sharing = LegacyCleanup.inspect(configData: Data("{}".utf8), stateData: Data(#"{"share":{"enabled":true}}"#.utf8))
        XCTAssertTrue(sharing.hasEngineData)
    }

    func testMovesEngineDataWithoutDeletingAnything() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("legacy \(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory.appendingPathComponent("core/rules"), withIntermediateDirectories: true)
        try Data("rules".utf8).write(to: directory.appendingPathComponent("core/rules/a.list"))
        try fm.createDirectory(at: directory.appendingPathComponent("imports"), withIntermediateDirectories: true)
        try Data("nodes".utf8).write(to: directory.appendingPathComponent("imports/nodes.yaml"))
        let importsURL = URL(fileURLWithPath: directory.appendingPathComponent("imports/nodes.yaml").path).absoluteString
        try Data(#"[{"path":"\#(directory.appendingPathComponent("imports").path)/x"}]"#.utf8).write(to: directory.appendingPathComponent("journal.json"))
        let config = #"{"profiles":[],"engine":{"subscriptions":[{"name":"f","url":"\#(importsURL)"}]}}"#
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data(#"{"share":{"enabled":true},"traffic":{}}"#.utf8).write(to: directory.appendingPathComponent("state.json"))

        let done = LegacyCleanup.migrateEngineData(in: directory)
        XCTAssertEqual(Set(done), ["core", "imports", "journal.json", "config.json", "state.json"])
        let engine = directory.appendingPathComponent("engine")
        XCTAssertEqual(try String(contentsOf: engine.appendingPathComponent("core/rules/a.list"), encoding: .utf8), "rules")
        XCTAssertEqual(try String(contentsOf: engine.appendingPathComponent("imports/nodes.yaml"), encoding: .utf8), "nodes")
        // 配置原样复制，指向 imports/ 的地址换到新位置；原来的 config.json 还在，另有一份备份。
        let copied = try String(contentsOf: engine.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertTrue(copied.contains(URL(fileURLWithPath: engine.appendingPathComponent("imports/nodes.yaml").path).absoluteString), copied)
        XCTAssertTrue(copied.contains(#""subscriptions""#))
        XCTAssertEqual(try String(contentsOf: engine.appendingPathComponent("config-0.12-backup.json"), encoding: .utf8), config)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("config.json"), encoding: .utf8), config)
        XCTAssertTrue(fm.fileExists(atPath: engine.appendingPathComponent("state.json").path))
        XCTAssertTrue(fm.fileExists(atPath: engine.appendingPathComponent("state-0.12-backup.json").path))
        let journal = try String(contentsOf: engine.appendingPathComponent("journal.json"), encoding: .utf8)
        XCTAssertTrue(journal.contains(engine.appendingPathComponent("imports").path), journal)
        // 再跑一次什么都不动（目标已经有了）。
        XCTAssertTrue(LegacyCleanup.migrateEngineData(in: directory).isEmpty)
        XCTAssertEqual(try String(contentsOf: engine.appendingPathComponent("config.json"), encoding: .utf8), copied)
    }

    func testPersistedStateDropsLegacyKeys() throws {
        let data = Data(#"{"lastProfileID":"\#(plainID)","enabledByUs":true,"share":{"enabled":true},"traffic":{}}"#.utf8)
        let state = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(state.lastProfileID?.uuidString, plainID)
        XCTAssertFalse(state.noticeShown)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        XCTAssertNil(written["share"])
        XCTAssertNil(written["traffic"])
        XCTAssertEqual(state.extensionState, ExtensionState(), "以前的版本没有扩展的状态，默认关着")
    }

    /// 现在写出来的键都在已知的名单里，不然每次启动都会当成以前版本的设置。
    func testKnownKeysMatchWhatIsWritten() throws {
        var config = AppConfig()
        config.profiles = [Profile(name: "a", color: "#000", host: "h", port: 1)]
        let configKeys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]).keys
        XCTAssertEqual(Set(configKeys), LegacyCleanup.knownConfigKeys)
        var state = PersistedState()
        state.lastProfileID = UUID()
        state.original = ProxySnapshot()
        let stateKeys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]).keys
        XCTAssertTrue(Set(stateKeys).isSubset(of: LegacyCleanup.knownStateKeys), "\(stateKeys)")
    }

    func testHelperRemovalScript() {
        let script = LegacyCleanup.helperRemovalScript
        XCTAssertTrue(script.contains("launchctl bootout system/com.whrss9527.proxyswitch.helper"), script)
        XCTAssertTrue(script.contains("'/Library/PrivilegedHelperTools/com.whrss9527.proxyswitch.'*"), script)
        XCTAssertTrue(script.contains("'/Library/LaunchDaemons/com.whrss9527.proxyswitch.helper.plist'"), script)
        XCTAssertTrue(script.contains("rm -rf '/Library/Application Support/ProxySwitch'"), script)
        // 只删以前版本的东西，不碰用户目录。
        XCTAssertFalse(script.contains("~"), script)
        XCTAssertFalse(script.contains(NSHomeDirectory()), script)
    }
}
