import XCTest
@testable import ProxiEngine

final class DNSPolicyTests: XCTestCase {
    func testAddEditAndDeleteKeepsStableIdentity() throws {
        var dns = DNSSettings()
        let policy = DNSPolicy(domain: " Example.COM\n", servers: [" 223.5.5.5 "])
        XCTAssertNil(dns.savePolicy(policy))
        XCTAssertEqual(dns.policies.first?.domain, "example.com")
        XCTAssertEqual(dns.policies.first?.servers, ["223.5.5.5"])
        var edited = policy
        edited.domain = "+.example.com"
        edited.servers = ["tls://dns.example.com", "1.1.1.1"]
        XCTAssertNil(dns.savePolicy(edited))
        XCTAssertEqual(dns.policies, [edited])
        let restored = try JSONDecoder().decode(DNSSettings.self, from: JSONEncoder().encode(dns))
        XCTAssertEqual(restored, dns)
        dns.policies.removeAll { $0.id == edited.id }
        XCTAssertTrue(dns.policies.isEmpty)
    }

    func testDuplicateDomainCannotOverwriteAnotherEntry() {
        var dns = DNSSettings()
        let original = DNSPolicy(domain: "example.com", servers: ["223.5.5.5"])
        let other = DNSPolicy(domain: "other.example", servers: ["1.1.1.1"])
        dns.policies = [original, other]
        XCTAssertNotNil(dns.savePolicy(DNSPolicy(domain: "EXAMPLE.COM", servers: ["8.8.8.8"])))
        var renamed = other
        renamed.domain = "EXAMPLE.COM"
        XCTAssertNotNil(dns.savePolicy(renamed))
        XCTAssertEqual(dns.policies, [original, other])
        // 精确匹配和包含子域名的匹配可以并存。
        XCTAssertNil(dns.savePolicy(DNSPolicy(domain: "+.example.com", servers: ["1.1.1.1"])))
    }

    func testInvalidEditLeavesSavedPolicyIntact() {
        var dns = DNSSettings()
        let policy = DNSPolicy(domain: "example.com", servers: ["223.5.5.5"])
        dns.policies = [policy]
        var edited = policy
        edited.servers = []
        XCTAssertNotNil(dns.savePolicy(edited))
        edited.servers = ["ftp://dns.example.com"]
        XCTAssertNotNil(dns.savePolicy(edited))
        edited.domain = "https://example.com"
        XCTAssertNotNil(dns.savePolicy(edited))
        XCTAssertEqual(dns.policies, [policy])
    }

    func testDuplicatePersistedPoliciesAreRejectedBeforeGeneratingYAML() {
        var dns = DNSSettings()
        dns.enabled = true
        dns.policies = [DNSPolicy(domain: "example.com", servers: ["223.5.5.5"]),
                        DNSPolicy(domain: "EXAMPLE.COM", servers: ["1.1.1.1"])]
        XCTAssertNotNil(dns.validate())
    }

    func testLegacyAndDisabledSettingsKeepMappings() throws {
        XCTAssertTrue(try JSONDecoder().decode(DNSSettings.self, from: Data("{}".utf8)).policies.isEmpty)
        let text = #"{"enabled":false,"policies":[{"domain":" EXAMPLE.COM ","servers":["223.5.5.5"]}]}"#
        let dns = try JSONDecoder().decode(DNSSettings.self, from: Data(text.utf8))
        XCTAssertFalse(dns.enabled)
        XCTAssertEqual(dns.policies.first?.domain, "example.com")
        XCTAssertEqual(try JSONDecoder().decode(DNSSettings.self, from: JSONEncoder().encode(dns)), dns)
    }
}

final class DNSPolicyIntegrationTests: XCTestCase {
    func testImportPersistenceAndResolverConfigurationDoNotChangeRulesOrHosts() throws {
        let text = """
        dns:
          enable: true
          nameserver: [1.1.1.1]
          nameserver-policy:
            "example.com": 223.5.5.5
            "+.corp.example": [10.0.0.53, "tls://dns.example.com"]
        """
        var config = AppConfig()
        config.engine.customRules = [CustomRule(pattern: "example.com", policy: .direct, kind: .domain)]
        config.engine.hosts = [HostEntry(domain: "nas.lan", value: "192.168.1.5")]
        let plan = try ConfigImporter.plan(text, sourceName: "DNS", existing: config)
        XCTAssertTrue(plan.warnings.isEmpty)
        let applied = ConfigImporter.apply(plan, to: config, mode: .merge, directory: URL(fileURLWithPath: "/tmp/proxi-dns-import")).config
        XCTAssertEqual(applied.engine.customRules, config.engine.customRules)
        XCTAssertEqual(applied.engine.hosts, config.engine.hosts)
        XCTAssertEqual(applied.engine.dns.nameservers, ["1.1.1.1"])
        XCTAssertEqual(applied.engine.dns.policies.map(\.servers), [["223.5.5.5"], ["10.0.0.53", "tls://dns.example.com"]])
        let saved = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(applied))
        XCTAssertEqual(saved.engine.dns, applied.engine.dns)
        let yaml = CoreConfigBuilder.yaml(.init(engine: saved.engine, secret: "test", directory: URL(fileURLWithPath: "/tmp/proxi-dns"),
                                               testURL: "https://www.apple.com/library/test/success.html", rules: ["DOMAIN,example.com,DIRECT", "MATCH,节点"]))
        XCTAssertTrue(yaml.contains("  nameserver-policy:\n    \"example.com\": [\"223.5.5.5\"]"))
        XCTAssertTrue(yaml.contains("\"+.corp.example\": [\"10.0.0.53\", \"tls://dns.example.com\"]"))
        XCTAssertTrue(yaml.contains("\"nas.lan\": \"192.168.1.5\""))
        XCTAssertTrue(yaml.contains("DOMAIN,example.com,DIRECT"))
        XCTAssertFalse(yaml.contains("\"example.com\": \"223.5.5.5\""))
        let backup = try ConfigImporter.plan(ConfigImporter.backupJSON(saved), sourceName: "备份")
        XCTAssertEqual(backup.backup?.engine.dns, saved.engine.dns)
        let described = try ConfigImporter.plan(ConfigImporter.describeJSON(saved), sourceName: "描述")
        XCTAssertEqual(described.dns?.policies.map(\.domain).sorted(), saved.engine.dns.policies.map(\.domain).sorted())
    }
}
