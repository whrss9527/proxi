import XCTest
@testable import ProxiEngine

final class DNSMappingTests: XCTestCase {
    func testEditingMappingPreservesIdentityAndOtherMappingsAfterPersistence() throws {
        var dns = DNSSettings()
        dns.enabled = true
        let exact = DNSPolicy(domain: "Example.COM.", servers: ["223.5.5.5"])
        let suffix = DNSPolicy(domain: "+.example.com", servers: ["10.0.0.53"])
        dns.policies = [exact, suffix]
        var edited = DNSPolicy(domain: " example.com\n", servers: ["tls://dns.example.com:853"])
        edited.id = exact.id
        XCTAssertNil(edited.validate(among: dns.policies))
        dns.policies = edited.replacing(in: dns.policies)
        let saved = try JSONDecoder().decode(DNSSettings.self, from: JSONEncoder().encode(dns))
        XCTAssertEqual(saved.policies.map(\.id), [exact.id, suffix.id])
        XCTAssertEqual(saved.policies[0].servers, ["tls://dns.example.com:853"])
        XCTAssertEqual(saved.policies[1], suffix)
        XCTAssertNil(saved.validate())
    }

    func testDuplicateMappingRejectedWithoutConfusingExactAndSuffix() {
        var dns = DNSSettings()
        dns.enabled = true
        dns.policies = [DNSPolicy(domain: "example.com", servers: ["223.5.5.5"])]
        let duplicate = DNSPolicy(domain: " EXAMPLE.COM. ", servers: ["119.29.29.29"])
        XCTAssertNotNil(duplicate.validate(among: dns.policies))
        XCTAssertNil(DNSPolicy(domain: "+.example.com", servers: ["10.0.0.53"]).validate(among: dns.policies))
        dns.policies.append(duplicate)
        XCTAssertNotNil(dns.validate())
    }

    func testInvalidDomainsAndServerEndpointsRejected() {
        for domain in ["", "https://example.com", "example.com/path", "example..com", "example.com..", "+.", "*.example..com"] {
            XCTAssertNotNil(DNSPolicy(domain: domain, servers: ["223.5.5.5"]).validate(), domain)
        }
        for server in ["", "223.5.5.5:0", "223.5.5.5:65536", "223.5.5.5:abc", "[::1]:bad", "https://", "https:///dns-query", "tls://dns.example.com:70000", "ftp://dns.example.com"] {
            XCTAssertNotNil(DNSSettings.validateServer(server), server)
        }
        for server in ["223.5.5.5", "223.5.5.5:5353", "::1", "[::1]:5353", "https://dns.example.com/dns-query", "tls://dns.example.com:853", "udp://127.0.0.1:53", "system", "dhcp://en0"] {
            XCTAssertNil(DNSSettings.validateServer(server), server)
        }
    }

    func testOldSettingsAndMappingWithoutIDStillDecode() throws {
        let old = try JSONDecoder().decode(DNSSettings.self, from: Data(#"{"enabled":true,"policies":[{"domain":"EXAMPLE.COM","servers":["223.5.5.5"]}]}"#.utf8))
        XCTAssertNil(old.validate())
        XCTAssertEqual(old.policies.first?.domain, "example.com")
        XCTAssertEqual(old.nameservers, DNSSettings.defaultNameservers)
        let empty = try JSONDecoder().decode(DNSSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.policies.isEmpty)
        XCTAssertFalse(empty.enabled)
    }

    func testBackupAndDescriptionRoundTripProduceDomainSpecificDNS() throws {
        var config = AppConfig()
        config.engine.dns.enabled = true
        config.engine.dns.fallback = []
        config.engine.dns.policies = [
            DNSPolicy(domain: "example.com", servers: ["223.5.5.5", "119.29.29.29"]),
            DNSPolicy(domain: "+.corp.example", servers: ["10.0.0.53:5353"]),
        ]
        let directory = URL(fileURLWithPath: "/tmp/proxi-dns-mapping")
        for text in [try ConfigImporter.backupJSON(config), ConfigImporter.describeJSON(config)] {
            let plan = try ConfigImporter.plan(text, sourceName: "dns.json")
            let restored = ConfigImporter.apply(plan, to: AppConfig(), mode: .replace, directory: directory).config
            let input = CoreConfigBuilder.Input(engine: restored.engine, secret: "test", directory: directory,
                testURL: "https://www.apple.com/library/test/success.html", rules: ["MATCH,DIRECT"])
            let yaml = CoreConfigBuilder.yaml(input)
            let parsed = try YAMLParser.parse(yaml)
            XCTAssertEqual(parsed["dns"]?["nameserver-policy"]?["example.com"]?.stringArray, ["223.5.5.5", "119.29.29.29"])
            XCTAssertEqual(parsed["dns"]?["nameserver-policy"]?["+.corp.example"]?.stringArray, ["10.0.0.53:5353"])
            XCTAssertEqual(parsed["dns"]?["nameserver"]?.stringArray, DNSSettings.defaultNameservers)
        }
    }
}
