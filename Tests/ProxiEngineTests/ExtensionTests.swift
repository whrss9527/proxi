import XCTest
@testable import ProxiEngine

/// 代理引擎作为 Proxi 的扩展新加的部分：固定的内核版本和校验和、网址检测、写给 Proxi 的状态文件、数据目录。
final class ExtensionTests: XCTestCase {
    func testCorePins() throws {
        XCTAssertEqual(CorePin.version, "v1.19.31")
        for architecture in ["arm64", "x86_64"] {
            let asset = try XCTUnwrap(CorePin.asset(for: architecture))
            XCTAssertEqual(asset.archiveSHA256.count, 64)
            XCTAssertEqual(asset.binarySHA256.count, 64)
            XCTAssertTrue(asset.archiveSHA256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            XCTAssertEqual(asset.url.host, "github.com")
            XCTAssertTrue(asset.url.path.hasPrefix("/MetaCubeX/mihomo/releases/download/\(CorePin.version)/"))
            XCTAssertTrue(CorePin.binarySHA256s.contains(asset.binarySHA256))
        }
        XCTAssertNil(CorePin.asset(for: "ppc"))
        XCTAssertEqual(CorePin.geoIPSHA256.count, 64)
        XCTAssertFalse(CorePin.geoIPURL.absoluteString.contains("latest"), "GeoIP 要固定在某一次发布")
    }

    func testDownloadLocations() {
        XCTAssertTrue(Store.directory.path.hasSuffix("/Proxi/engine") || ProcessInfo.processInfo.environment["PROXI_ENGINE_DIR"] != nil)
        XCTAssertEqual(CoreDownload.coreURL.deletingLastPathComponent().lastPathComponent, "bin")
        XCTAssertEqual(CoreDownload.coreURL.lastPathComponent, "mihomo")
        XCTAssertEqual(CoreDownload.geoIPURL.lastPathComponent, "Country.mmdb")
        XCTAssertEqual(AppInfo.bundleIdentifier, "com.whrss9527.proxyswitch.engine")
    }

    func testHelperRefusesUnknownCore() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fake-core-\(UUID().uuidString)")
        try Data("not the core".utf8).write(to: file)
        XCTAssertThrowsError(try HelperInstaller.verifyCore(file.path, removeIfWrong: false)) { error in
            XCTAssertEqual((error as? HelperError)?.diagnosticCode, "core_checksum")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "只检查来源时不删")
        XCTAssertThrowsError(try HelperInstaller.verifyCore(file.path, removeIfWrong: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "复制到助手目录里的认不出的内核要删掉")
    }

    func testURLCheck() {
        XCTAssertEqual(ServiceClassifier.normalize("example.com"), "https://example.com")
        XCTAssertEqual(ServiceClassifier.normalize(" https://example.com/a?b=1 "), "https://example.com/a?b=1")
        XCTAssertEqual(ServiceClassifier.normalize("http://192.0.2.1:8080/"), "http://192.0.2.1:8080/")
        XCTAssertNil(ServiceClassifier.normalize(""))
        XCTAssertNil(ServiceClassifier.normalize("not a url"))
        let ok = ServiceClassifier.classify(url: "https://example.com", response: ServiceResponse(status: 204, url: "https://example.com", latency: 120))
        XCTAssertTrue(ok.isAvailable)
        XCTAssertEqual(ok.latency, 120)
        XCTAssertEqual(ok.title, "example.com")
        let blocked = ServiceClassifier.classify(url: "https://example.com", response: ServiceResponse(status: 403, url: "https://example.com", latency: 80))
        XCTAssertFalse(blocked.isAvailable)
        XCTAssertEqual(blocked.status, .blocked("HTTP 403"))
        let failed = ServiceClassifier.classify(url: "https://example.com", response: nil)
        XCTAssertFalse(failed.isAvailable)
        XCTAssertNil(failed.latency)
    }

    func testStatusFileFormat() throws {
        let file = EngineStatusFile(version: "1.0.0", pid: 42, mixedPort: 7890, coreRunning: true, coreReady: true, summary: "x", updatedAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(file)) as? [String: Any])
        // Proxi 那边（ExtensionStatus）按这些键读。
        XCTAssertEqual(object["mixedPort"] as? Int, 7890)
        XCTAssertEqual(object["pid"] as? Int, 42)
        XCTAssertEqual(object["coreRunning"] as? Bool, true)
        XCTAssertEqual(object["version"] as? String, "1.0.0")
        XCTAssertEqual(object["updatedAt"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(EngineStatusFile.url.lastPathComponent, "status.json")
    }

    func testNoServicePresetsInDefaults() {
        // 默认配置里不带任何规则集、策略组；规则库里只有通用的去广告列表。
        let engine = EngineConfig()
        XCTAssertTrue(engine.ruleSets.isEmpty)
        XCTAssertTrue(engine.groups.isEmpty)
        for entry in RuleLibrary.all {
            XCTAssertEqual(entry.policy, .reject, entry.name)
        }
    }
}
