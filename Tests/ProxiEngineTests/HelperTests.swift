import XCTest
@testable import ProxiEngine
#if canImport(Darwin)
import Darwin
import Security
#else
import Glibc
#endif

final class HelperTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ps-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("source/rules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("target"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSafeRelativePaths() {
        for good in ["config.yaml", "rules/rs-1234.list", "providers/manual.txt", "Country.mmdb"] {
            XCTAssertTrue(HelperFiles.isSafeRelativePath(good), good)
        }
        for bad in ["", "/etc/passwd", "../x", "rules/../../x", "rules//x", "./config.yaml", "rules/.", "a\0b", String(repeating: "a", count: 1100)] {
            XCTAssertFalse(HelperFiles.isSafeRelativePath(bad), bad)
        }
    }

    func testCopiesOnlyRegularFilesOfTheOwner() throws {
        let source = root.appendingPathComponent("source").path
        let target = root.appendingPathComponent("target").path
        let owner = UInt32(getuid())
        try "mixed-port: 7890\n".write(toFile: source + "/config.yaml", atomically: true, encoding: .utf8)
        try "DOMAIN,a.com\n".write(toFile: source + "/rules/a.list", atomically: true, encoding: .utf8)
        try HelperFiles.copy(["config.yaml", "rules/a.list"], from: source, to: target, owner: owner, secret: "k1")
        // 配置按解析出来的内容重新写出，密钥换成助手给的。
        XCTAssertEqual(try String(contentsOfFile: target + "/config.yaml", encoding: .utf8), "mixed-port: 7890\nsecret: \"k1\"\n")
        XCTAssertEqual(try String(contentsOfFile: target + "/rules/a.list", encoding: .utf8), "DOMAIN,a.com\n")
        // 复制过去的文件和目录只有自己（助手里是 root）能读：配置里有控制接口的密钥，节点文件里有服务器的密码。
        func mode(_ path: String) throws -> Int? {
            (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        }
        XCTAssertEqual(try mode(target + "/config.yaml"), 0o600)
        XCTAssertEqual(try mode(target + "/rules"), 0o700)
        // 再复制一次会覆盖，不留临时文件。
        try "mixed-port: 7891\n".write(toFile: source + "/config.yaml", atomically: true, encoding: .utf8)
        try HelperFiles.copy(["config.yaml"], from: source, to: target, owner: owner, secret: "k1")
        XCTAssertEqual(try String(contentsOfFile: target + "/config.yaml", encoding: .utf8), "mixed-port: 7891\nsecret: \"k1\"\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/config.yaml.ps-tmp"))

        // 符号链接（哪怕指向自己的文件）、目录、别人的文件、不安全的路径都不复制。
        try FileManager.default.createSymbolicLink(atPath: source + "/link.yaml", withDestinationPath: source + "/config.yaml")
        XCTAssertThrowsError(try HelperFiles.copy(["link.yaml"], from: source, to: target, owner: owner, secret: "k1"))
        XCTAssertThrowsError(try HelperFiles.copy(["rules"], from: source, to: target, owner: owner, secret: "k1"))
        XCTAssertThrowsError(try HelperFiles.copy(["config.yaml"], from: source, to: target, owner: owner &+ 1, secret: "k1"))
        XCTAssertThrowsError(try HelperFiles.copy(["../source/config.yaml"], from: source, to: target, owner: owner, secret: "k1"))
        XCTAssertThrowsError(try HelperFiles.copy(["missing.yaml"], from: source, to: target, owner: owner, secret: "k1"))
        XCTAssertThrowsError(try HelperFiles.copy(["config.yaml"], from: "relative/dir", to: target, owner: owner, secret: "k1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/link.yaml"))
    }

    func testLaunchdPlist() throws {
        let data = try HelperInstaller.plist(uid: 501, appVersion: "0.10.0", clientRequirement: "cdhash H\"abc\"")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, HelperPaths.label)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [HelperPaths.executable, "helper", "run", "--uid", "501", "--version", "0.10.0", "--client", "cdhash H\"abc\""])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
    }

    func testStatusAndVersions() {
        let status = HelperStatus(["protocol": HelperProtocol.version, "version": "0.10.0", "core": "v1.19.31", "running": true, "forwarding": false])
        XCTAssertTrue(status.isCurrent)
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.coreVersion, "v1.19.31")
        XCTAssertFalse(HelperStatus(["protocol": 0]).isCurrent)
        XCTAssertEqual(HelperDaemon.coreVersion(from: "Mihomo Meta v1.19.31 darwin arm64 with go1.26.8"), "v1.19.31")
        XCTAssertNil(HelperDaemon.coreVersion(from: "garbage"))
        // 内核目录在 root 的数据目录里，和用户的目录分开。
        XCTAssertTrue(HelperPaths.coreDirectory.hasPrefix(HelperPaths.dataDirectory + "/"))
        XCTAssertFalse(HelperPaths.coreDirectory.contains("~"))
    }
    // MARK: 只听代理引擎的

    func testClientRequirement() {
        // 开发者签名的：认 bundle id 和 Team ID，代理引擎更新以后照样认。
        XCTAssertEqual(HelperClientCheck.requirement(identifier: "com.whrss9527.proxyswitch.engine", teamID: "ABCDE12345", cdhash: "00ff"),
                       "identifier \"com.whrss9527.proxyswitch.engine\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
        // ad-hoc 签名的：只认这一份程序。
        XCTAssertEqual(HelperClientCheck.requirement(identifier: "x", teamID: nil, cdhash: "00ff"), "cdhash H\"00ff\"")
        XCTAssertEqual(HelperClientCheck.requirement(identifier: "x", teamID: "", cdhash: "00ff"), "cdhash H\"00ff\"")
        // 没有签名、或者读出来的东西不像样（不会拼进要求里）：不装。
        XCTAssertNil(HelperClientCheck.requirement(identifier: "x", teamID: nil, cdhash: nil))
        XCTAssertNil(HelperClientCheck.requirement(identifier: "x", teamID: nil, cdhash: "zz\" or true"))
        XCTAssertEqual(HelperClientCheck.requirement(identifier: "x", teamID: "AB\" or anchor apple", cdhash: "01"), "cdhash H\"01\"")
    }

    func testDaemonRefusesWithoutRequirement() throws {
        // 没有记下要求（旧的 launchd 配置）时谁都不接受。
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        #else
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds), 0)
        #endif
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertFalse(HelperDaemon(uid: getuid(), appVersion: "0.14.9", clientRequirement: "").clientAllowed(fds[0]))
        #if !canImport(Security)
        XCTAssertFalse(HelperDaemon(uid: getuid(), appVersion: "0.14.9", clientRequirement: "cdhash H\"00\"").clientAllowed(fds[0]))
        #endif
    }

    #if canImport(Security)
    func testPeerSignatureChecksTheConnectedProcess() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        let ownCode = try XCTUnwrap(code)
        var requirement: SecRequirement?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(ownCode, [], &requirement), errSecSuccess)
        var text: CFString?
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), [], &text), errSecSuccess)
        let ownRequirement = try XCTUnwrap(text) as String
        // 相同 UID 只通过正确的进程签名；错误或无效要求一律拒绝。
        XCTAssertTrue(CodeSignature.peer(fds[0], satisfies: ownRequirement))
        XCTAssertTrue(HelperDaemon(uid: getuid(), appVersion: "test", clientRequirement: ownRequirement).clientAllowed(fds[0]))
        XCTAssertFalse(CodeSignature.peer(fds[0], satisfies: "identifier \"com.example.unrelated-client\""))
        XCTAssertFalse(CodeSignature.peer(fds[0], satisfies: "not a requirement"))
        XCTAssertFalse(CodeSignature.peer(-1, satisfies: ownRequirement))
    }
    #endif

    // MARK: 以 root 运行前核对配置

    private func problems(_ yaml: String) throws -> [String] {
        HelperConfigCheck.problems(in: try YAMLParser.parse(yaml), directory: "/root/core")
    }

    func testConfigCheckRejectsSettingsThatReachOutsideTheDirectory() throws {
        XCTAssertEqual(try problems("mixed-port: 7890\nexternal-controller-unix: /tmp/x.sock\n"), ["external-controller-unix"])
        XCTAssertEqual(try problems("external-ui: ui\nexternal-ui-url: https://example.com/ui.zip\n"), ["external-ui", "external-ui-url"])
        XCTAssertEqual(try problems("\"external-controller-pipe\": x\n"), ["external-controller-pipe"])
        XCTAssertEqual(try problems("ntp:\n  enable: true\n  write-to-system: true\n"), ["ntp.write-to-system"])
        XCTAssertEqual(try problems("ntp:\n  enable: true\n  write-to-system: false\n"), [])
        XCTAssertEqual(try problems("""
        proxy-providers:
          a:
            path: /etc/x.yaml
          b:
            path: ./providers/../../x.yaml
          c:
            path: config.yaml
          d:
            path: ./providers/d.yaml
          e:
            path: /root/core/rules/e.list
        """), ["proxy-providers.a.path", "proxy-providers.b.path", "proxy-providers.c.path"])
        XCTAssertEqual(try problems("rule-providers:\n  r:\n    path: /root/core-other/r.list\n"), ["rule-providers.r.path"])
        XCTAssertEqual(try problems("tls:\n  certificate: /etc/cert.pem\n  private-key: \"-----BEGIN PRIVATE KEY-----\\nabc\"\n"), ["tls.certificate"])
        XCTAssertTrue(HelperConfigCheck.isInside("/root/core", "/root/core"))
        XCTAssertFalse(HelperConfigCheck.isInside("/root/core2/x", "/root/core"))
    }

    func testConfigIsRewrittenWithTheHelperSecret() throws {
        let data = Data("mixed-port: 7890\nsecret: \"from-user\"\nsecret: \"again\"\nrules:\n  - MATCH,DIRECT\n".utf8)
        let text = String(decoding: try HelperConfigCheck.sanitized(data, directory: "/root/core", secret: "k2"), as: UTF8.self)
        XCTAssertEqual(text, "mixed-port: 7890\nrules:\n  - MATCH,DIRECT\nsecret: \"k2\"\n")
        XCTAssertThrowsError(try HelperConfigCheck.sanitized(Data("external-ui: ui\n".utf8), directory: "/root/core", secret: "k2"))
        XCTAssertThrowsError(try HelperConfigCheck.sanitized(Data("- not a mapping\n".utf8), directory: "/root/core", secret: "k2"))
        XCTAssertThrowsError(try HelperConfigCheck.sanitized(Data([0xff, 0xfe]), directory: "/root/core", secret: "k2"))
    }

    func testRejectedConfigCopiesNothing() throws {
        let source = root.appendingPathComponent("source").path
        let target = root.appendingPathComponent("target").path
        try "external-controller-unix: /tmp/x.sock\n".write(toFile: source + "/config.yaml", atomically: true, encoding: .utf8)
        try "DOMAIN,a.com\n".write(toFile: source + "/rules/a.list", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HelperFiles.copy(["rules/a.list", "config.yaml"], from: source, to: target, owner: UInt32(getuid()), secret: "k1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/rules/a.list"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/config.yaml"))
    }

    func testGeneratedConfigsPassAndKeepTheirMeaning() throws {
        var engine = EngineConfig()
        engine.subscriptions = [Subscription(name: "订阅A", url: "https://sub.example.com/a")]
        engine.customRules = [CustomRule(pattern: "192.168.1.20", policy: .reject, kind: .device)]
        let home = URL(fileURLWithPath: HelperPaths.coreDirectory)
        let ruleSet = RuleProviderSpec(name: "rs-1", path: home.appendingPathComponent("rules/rs-1.list").path, behavior: .domain, format: "text")
        let tun = TunInputs(stack: .mixed, dnsMode: .fakeIP, captureLocal: true, gateway: true, upstream: .engine, localAddresses: ["192.168.1.23"])
        let share = ShareInputs(port: 7892, allowedPrefixes: ShareConfig().allowedPrefixes, upstream: .engine)
        let input = CoreConfigBuilder.Input(engine: engine, secret: "from-user", directory: home, testURL: "https://www.apple.com/library/test/success.html",
                                            rules: ["RULE-SET,rs-1,节点", "MATCH,节点"], share: share, ruleProviders: [ruleSet], tun: tun)
        let text = CoreConfigBuilder.yaml(input)
        let original = try YAMLParser.parse(text)
        XCTAssertEqual(HelperConfigCheck.problems(in: original, directory: HelperPaths.coreDirectory), [])
        let sanitized = try HelperConfigCheck.sanitized(Data(text.utf8), directory: HelperPaths.coreDirectory, secret: "k3")
        var expected = original
        expected.remove("secret")
        expected.set("secret", .string("k3"))
        XCTAssertEqual(try YAMLParser.parse(String(decoding: sanitized, as: UTF8.self)), expected)
    }
}
