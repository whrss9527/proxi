import XCTest
@testable import ProxiEngine

final class ParsingTests: XCTestCase {
    func testProxiChecksums() throws {
        let text = """
        说明行
        0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0  Proxi-macos.zip
        DEADBEEF  太短的
        5891B5B522D5DF086D0FF0B110FBD9D21BB4FC7163AF34D08286A2E846F6BE03 *hello.txt
        """
        XCTAssertEqual(ProxiChecksums.parse(text), [
            "Proxi-macos.zip": "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
            "hello.txt": "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03",
        ])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("checksum-\(UUID().uuidString).bin")
        try Data("hello\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try ProxiChecksums.sha256(of: file), "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    }

    func testNetworkRoutes() {
        let github = URL(string: "https://github.com/whrss9527/proxi/releases/download/v1/Proxi-macos.zip")!
        var off = ProxySnapshot()
        off.httpEnabled = false
        var coreProxy = ProxySnapshot()
        coreProxy.httpEnabled = true; coreProxy.httpHost = "127.0.0.1"; coreProxy.httpPort = 7890
        coreProxy.httpsEnabled = true; coreProxy.httpsHost = "127.0.0.1"; coreProxy.httpsPort = 7890
        var other = ProxySnapshot()
        other.httpsEnabled = true; other.httpsHost = "proxy.corp"; other.httpsPort = 3128

        XCTAssertEqual(NetworkRoute.routes(for: github, corePort: 7890, system: off), [.core(7890), .direct])
        XCTAssertEqual(NetworkRoute.routes(for: github, corePort: 7890, system: coreProxy), [.core(7890), .direct])
        XCTAssertEqual(NetworkRoute.routes(for: github, corePort: 7890, system: other), [.core(7890), .system, .direct])
        XCTAssertEqual(NetworkRoute.routes(for: github, corePort: nil, system: other), [.system, .direct])
        XCTAssertEqual(NetworkRoute.routes(for: github, corePort: nil, system: off), [.direct])
        // 本机地址（测试用的发布源）不经代理。
        XCTAssertEqual(NetworkRoute.routes(for: URL(string: "http://127.0.0.1:8765/latest.json")!, corePort: 7890, system: other), [.direct])
        XCTAssertTrue(coreProxy.pointsAtLocalhost(port: 7890))
        XCTAssertFalse(coreProxy.pointsAtLocalhost(port: 7891))

        let configuration = URLSessionConfiguration.ephemeral
        NetworkRoute.core(7890).apply(to: configuration)
        XCTAssertEqual(configuration.connectionProxyDictionary?[kCFNetworkProxiesHTTPSPort as String] as? Int, 7890)
        NetworkRoute.direct.apply(to: configuration)
        XCTAssertEqual(configuration.connectionProxyDictionary?.count, 0)
        NetworkRoute.system.apply(to: configuration)
        XCTAssertNil(configuration.connectionProxyDictionary)
    }

    func testRuleConversion() {
        let conf = """
        [General]
        skip-proxy = 192.168.0.0/16
        [Rule]
        # 注释
        DOMAIN-SUFFIX,google.com,Proxy
        DOMAIN-SUFFIX,google.com,Proxy
        DOMAIN,ad.example.com,Reject
        DOMAIN-KEYWORD,baidu,direct
        IP-CIDR,91.108.56.0/22,PROXY,no-resolve
        IP-CIDR6,2001:b28:f23d::/48,Proxy
        GEOIP,cn,DIRECT
        USER-AGENT,MicroMessenger*,Proxy
        RULE-SET,https://example.com/apple.list,PROXY
        RULE-SET,local-name,DIRECT
        FINAL,direct
        [URL Rewrite]
        ^https?://(www.)?g.cn https://www.google.com 302
        """
        let converted = RuleConverter.convert(conf)
        XCTAssertEqual(converted.rules, [
            "DOMAIN-SUFFIX,google.com,节点",
            "DOMAIN,ad.example.com,REJECT",
            "DOMAIN-KEYWORD,baidu,DIRECT",
            "IP-CIDR,91.108.56.0/22,节点,no-resolve",
            "IP-CIDR6,2001:b28:f23d::/48,节点",
            "GEOIP,CN,DIRECT",
            "MATCH,DIRECT",
        ])
        XCTAssertEqual(converted.ruleSets, [RuleSetReference(url: "https://example.com/apple.list", policy: "节点")])
        XCTAssertEqual(converted.skipped, 2)

        // Surge 的 .list 规则集：没有策略字段，用默认策略；内联到 FINAL 之前。
        let list = RuleConverter.convert("DOMAIN-SUFFIX,apple.news\nIP-CIDR,17.0.0.0/8,no-resolve\n", defaultPolicy: "节点")
        XCTAssertEqual(list.rules, ["DOMAIN-SUFFIX,apple.news,节点", "IP-CIDR,17.0.0.0/8,节点,no-resolve"])
        let merged = RuleConverter.merge(converted, ruleSetRules: ["https://example.com/apple.list": list.rules])
        XCTAssertEqual(merged.last, "MATCH,DIRECT")
        XCTAssertEqual(merged.count, converted.rules.count + list.rules.count)
        XCTAssertTrue(merged.contains("DOMAIN-SUFFIX,apple.news,节点"))

        // Clash 的规则文件和 payload 列表。
        let clash = "port: 7890\nrules:\n  - DOMAIN-SUFFIX,x.com,Proxy\n  - 'GEOIP,CN,DIRECT'\n  - MATCH,Proxy\nproxies: []\n"
        XCTAssertEqual(RuleConverter.convert(clash).rules, ["DOMAIN-SUFFIX,x.com,节点", "GEOIP,CN,DIRECT", "MATCH,节点"])
        // 带双引号的列表项按 YAML 的规则解转义：导入时写出来的规则文件里正则的 \. 是 "\\."，读回来要还原，不然正则多了个反斜杠就匹配不上。
        let escaped = "rules:\n  - \"DOMAIN-REGEX,^.*\\\\.google\\\\.com$,DIRECT\"\n  - 'DOMAIN,it''s.example,DIRECT'\n"
        XCTAssertEqual(RuleConverter.convert(escaped).rules, ["DOMAIN-REGEX,^.*\\.google\\.com$,DIRECT", "DOMAIN,it's.example,DIRECT"])
        let payload = "payload:\n  - '+.example.com'\n  - 'sub.example.org'\n  - '10.0.0.0/8'\n"
        XCTAssertEqual(RuleConverter.convert(payload, defaultPolicy: "DIRECT").rules, ["DOMAIN-SUFFIX,example.com,DIRECT", "DOMAIN,sub.example.org,DIRECT", "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"])
        XCTAssertEqual(RuleConverter.policy("Reject"), "REJECT")
        XCTAssertEqual(RuleConverter.policy("自定义组"), "节点")
        // 和自定义策略组同名的策略指到那个组；强制去向时全部改过去，FINAL 不动。
        XCTAssertEqual(RuleConverter.policy("组B", groups: ["组B"]), "组B")
        XCTAssertEqual(RuleConverter.policy("streaming", groups: ["Streaming"]), "Streaming")
        let grouped = RuleConverter.convert("DOMAIN-SUFFIX,media.example,组B\nDOMAIN-SUFFIX,x.com,Proxy\nFINAL,DIRECT", groups: ["组B"])
        XCTAssertEqual(grouped.rules, ["DOMAIN-SUFFIX,media.example,组B", "DOMAIN-SUFFIX,x.com,节点", "MATCH,DIRECT"])
        let forced = RuleConverter.convert("DOMAIN-SUFFIX,media.example,组B\nDOMAIN,ad.example.com,REJECT\nIP-CIDR,1.1.1.0/24,DIRECT,no-resolve\nRULE-SET,https://x/a.list,DIRECT\n+.plain.com\nFINAL,DIRECT", force: "REJECT", groups: ["组B"])
        XCTAssertEqual(forced.rules, ["DOMAIN-SUFFIX,media.example,REJECT", "DOMAIN,ad.example.com,REJECT", "IP-CIDR,1.1.1.0/24,REJECT,no-resolve", "DOMAIN-SUFFIX,plain.com,REJECT", "MATCH,DIRECT"])
        XCTAssertEqual(forced.ruleSets, [RuleSetReference(url: "https://x/a.list", policy: "REJECT")])
    }

    func testCoreConfig() throws {
        var engine = EngineConfig()
        engine.subscriptions = [Subscription(name: "订阅A", url: "https://air.example.com/sub?token=\"x\"")]
        engine.mixedPort = 7891
        engine.apiPort = 9098
        let input = CoreConfigBuilder.Input(engine: engine, secret: "s3cret", directory: URL(fileURLWithPath: "/tmp/core"), testURL: "https://cp.cloudflare.com/generate_204", rules: RuleConverter.chinaDirectRules)
        let yaml = CoreConfigBuilder.yaml(input)
        XCTAssertTrue(yaml.contains("mixed-port: 7891\n"))
        XCTAssertTrue(yaml.contains("external-controller: \"127.0.0.1:9098\"\n"))
        XCTAssertTrue(yaml.contains("secret: \"s3cret\"\n"))
        XCTAssertTrue(yaml.contains("    url: \"https://air.example.com/sub?token=\\\"x\\\"\"\n"))
        XCTAssertTrue(yaml.contains("    path: \"/tmp/core/providers/\(engine.subscriptions[0].providerName).yaml\"\n"))
        XCTAssertTrue(yaml.contains("    use: [\(engine.subscriptions[0].providerName)]\n"))
        XCTAssertTrue(yaml.contains("  - \"GEOIP,CN,DIRECT\"\n  - \"MATCH,节点\"\n"))
        XCTAssertTrue(yaml.hasSuffix("\n"))
        // 没有 MATCH 时补上。
        var global = input
        global.rules = ["DOMAIN-SUFFIX,x.com,DIRECT"]
        XCTAssertTrue(CoreConfigBuilder.yaml(global).hasSuffix("  - \"MATCH,节点\"\n"))
        XCTAssertEqual(CoreConfigBuilder.quote("a\"b\\c\n"), "\"a\\\"b\\\\c\\n\"")
        XCTAssertEqual(CoreConfigBuilder.makeSecret().count, 32)
        XCTAssertTrue(yaml.contains("find-process-mode: always\n"))
        XCTAssertFalse(yaml.contains("rule-providers:"))

        // 自定义策略组：手动选择的带「节点」「自动选择」「DIRECT」，自动类的只有筛出来的节点；筛选默认不区分大小写。
        var grouped = engine
        grouped.groups = [
            PolicyGroup(name: "组B", kind: .select, filter: "港|HK"),
            PolicyGroup(name: "自动香港", kind: .urlTest, filter: "(?i)hk"),
            PolicyGroup(name: "轮询", kind: .loadBalance),
            PolicyGroup(name: "备用", kind: .fallback, filter: "US"),
        ]
        var groupedInput = input
        groupedInput.engine = grouped
        groupedInput.ruleProviders = [
            RuleProviderSpec(name: "rs-abcd1234", path: "/tmp/core/rules/rs-abcd1234.txt", behavior: .classical, format: "text"),
            RuleProviderSpec(name: "rs-ffff0000", path: "/tmp/core/rules/rs-ffff0000.mrs", behavior: .domain, format: "mrs"),
        ]
        groupedInput.rules = ["RULE-SET,rs-abcd1234,组B", "RULE-SET,rs-ffff0000,REJECT", "MATCH,节点"]
        let groupedYAML = CoreConfigBuilder.yaml(groupedInput)
        let use = "    use: [\(engine.subscriptions[0].providerName)]\n"
        XCTAssertTrue(groupedYAML.contains("  - name: \"组B\"\n    type: select\n    proxies: [\"节点\", \"自动选择\", \"DIRECT\"]\n" + use + "    filter: \"(?i)港|HK\"\n"))
        XCTAssertTrue(groupedYAML.contains("  - name: \"自动香港\"\n    type: url-test\n    url: \"https://cp.cloudflare.com/generate_204\"\n    interval: 600\n    tolerance: 80\n    lazy: true\n" + use + "    filter: \"(?i)hk\"\n"))
        XCTAssertTrue(groupedYAML.contains("  - name: \"轮询\"\n    type: load-balance\n    url: \"https://cp.cloudflare.com/generate_204\"\n    interval: 600\n    strategy: round-robin\n    lazy: true\n" + use + "  - name: \"备用\"\n    type: fallback\n    url: \"https://cp.cloudflare.com/generate_204\"\n    interval: 600\n    lazy: true\n" + use + "    filter: \"(?i)US\"\n"))
        XCTAssertTrue(groupedYAML.contains("rule-providers:\n  rs-abcd1234:\n    type: file\n    behavior: classical\n    format: text\n    path: \"/tmp/core/rules/rs-abcd1234.txt\"\n  rs-ffff0000:\n    type: file\n    behavior: domain\n    format: mrs\n    path: \"/tmp/core/rules/rs-ffff0000.mrs\"\n"))
        XCTAssertTrue(groupedYAML.contains("  - \"RULE-SET,rs-abcd1234,组B\"\n  - \"RULE-SET,rs-ffff0000,REJECT\"\n  - \"MATCH,节点\"\n"))
        // 没有加载订阅（只做共享）时策略组照样要有（规则里引用了它们）：手动选择的只有三个固定候选，自动类的只有直连，都不带 use 和筛选。
        var shareOnly = groupedInput
        shareOnly.engine.enabled = false
        let shareOnlyYAML = CoreConfigBuilder.yaml(shareOnly)
        XCTAssertTrue(shareOnlyYAML.contains("  - name: \"组B\"\n    type: select\n    proxies: [\"节点\", \"自动选择\", \"DIRECT\"]\n  - name: \"自动香港\"\n"))
        XCTAssertTrue(shareOnlyYAML.contains("  - name: \"自动香港\"\n    type: url-test\n    url: \"https://cp.cloudflare.com/generate_204\"\n    interval: 600\n    tolerance: 80\n    lazy: true\n    proxies: [\"DIRECT\"]\n"))
        XCTAssertTrue(shareOnlyYAML.contains("    strategy: round-robin\n    lazy: true\n    proxies: [\"DIRECT\"]\n"))
        XCTAssertFalse(shareOnlyYAML.contains("use:"))
        XCTAssertFalse(shareOnlyYAML.contains("filter:"))
        XCTAssertTrue(shareOnlyYAML.contains("  - \"RULE-SET,rs-abcd1234,组B\"\n"))
    }

    func testEngineModels() throws {
        XCTAssertNil(Subscription.validate(url: "https://air.example.com/sub"))
        XCTAssertNil(Subscription.validate(url: "file:///Users/me/nodes.txt"))
        XCTAssertEqual(Subscription(name: "f", url: "file:///Users/me/nodes.txt").filePath, "/Users/me/nodes.txt")
        XCTAssertNil(Subscription(name: "h", url: "https://x/y").filePath)
        XCTAssertNotNil(Subscription.validate(url: "ss://abc"))
        XCTAssertNotNil(Subscription.validate(url: ""))
        var fileEngine = EngineConfig()
        fileEngine.subscriptions = [Subscription(name: "f", url: "file:///tmp/nodes.txt")]
        let fileYAML = CoreConfigBuilder.yaml(CoreConfigBuilder.Input(engine: fileEngine, secret: "s", directory: URL(fileURLWithPath: "/tmp/core"), testURL: "https://t", rules: []))
        XCTAssertTrue(fileYAML.contains("    type: file\n    path: \"/tmp/core/providers/\(fileEngine.subscriptions[0].providerName).yaml\"\n"))
        XCTAssertFalse(fileYAML.contains("interval: 86400"))
        var engine = EngineConfig()
        XCTAssertFalse(engine.wantsCore)
        engine.subscriptions = [Subscription(name: "a", url: "https://x/y")]
        XCTAssertTrue(engine.wantsCore)
        engine.enabled = false
        XCTAssertFalse(engine.wantsCore)
        engine.ruleSets = [RuleSet.chinaDirect(), RuleSet(name: "完整配置", url: "https://example.com/rules.conf", policy: nil)]
        engine.groups = [PolicyGroup(name: "组 A", kind: .select, filter: "a")]
        engine.finalPolicy = .group("组 A")
        let data = try JSONEncoder().encode(engine)
        let decoded = try JSONDecoder().decode(EngineConfig.self, from: data)
        XCTAssertEqual(decoded, engine)
        XCTAssertEqual(decoded.ruleSets[1].kind, .inline)
        XCTAssertEqual(decoded.groupNames, ["组 A"])
        XCTAssertEqual(try JSONDecoder().decode(EngineConfig.self, from: Data("{}".utf8)).mixedPort, 7890)
        // 新的配置默认没有规则集；旧配置里的单一规则来源迁移成规则集：内置的照旧；规则地址按文件自己的策略，FINAL 也跟着文件。
        XCTAssertEqual(try JSONDecoder().decode(EngineConfig.self, from: Data("{}".utf8)).ruleSets, [])
        XCTAssertEqual(EngineConfig().ruleSets, [])
        let migratedURL = try JSONDecoder().decode(EngineConfig.self, from: Data(#"{"ruleSource":{"kind":"url","url":"https://example.com/rules.conf"}}"#.utf8))
        XCTAssertEqual(migratedURL.ruleSets.count, 1)
        XCTAssertEqual(migratedURL.ruleSets[0].name, "rules")
        XCTAssertEqual(migratedURL.ruleSets[0].url, "https://example.com/rules.conf")
        XCTAssertNil(migratedURL.ruleSets[0].policy)
        XCTAssertNil(migratedURL.finalPolicy)
        XCTAssertEqual(try JSONDecoder().decode(EngineConfig.self, from: Data(#"{"ruleSource":{"kind":"chinaDirect"}}"#.utf8)).ruleSets, [RuleSet.chinaDirect()])
        XCTAssertTrue(try JSONDecoder().decode(EngineConfig.self, from: Data(#"{"ruleSets":[]}"#.utf8)).ruleSets.isEmpty)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("ruleSource"))
        XCTAssertEqual(try JSONDecoder().decode(RuleSource.self, from: Data(#"{"kind":"url","url":"https://a/b"}"#.utf8)), .url("https://a/b"))
        XCTAssertEqual(try JSONDecoder().decode(RuleSource.self, from: Data(#"{"kind":"nope"}"#.utf8)), .chinaDirect)

        // 内置代理的配置：HTTP 和 SOCKS 都指到内核端口。
        let profile = Profile.engineProfile(port: 7890)
        XCTAssertTrue(profile.engine)
        XCTAssertEqual(profile.summary, "代理引擎 · 127.0.0.1:7890")
        let desired = DesiredProxy(profile: profile)
        XCTAssertEqual(desired.http, DesiredProxy.Endpoint(host: "127.0.0.1", port: 7890))
        XCTAssertEqual(desired.socks, DesiredProxy.Endpoint(host: "127.0.0.1", port: 7890))
        let roundTrip = try JSONDecoder().decode(Profile.self, from: try JSONEncoder().encode(profile))
        XCTAssertTrue(roundTrip.engine)
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
}

/// 共享期间防睡眠：决定逻辑，以及真的向系统要一条断言再释放。
final class SleepGuardTests: XCTestCase {
    func testShouldHold() {
        XCTAssertTrue(PowerAssertion.shouldHold(wanted: true, onBattery: false, allowOnBattery: false))
        XCTAssertFalse(PowerAssertion.shouldHold(wanted: true, onBattery: true, allowOnBattery: false))
        XCTAssertTrue(PowerAssertion.shouldHold(wanted: true, onBattery: true, allowOnBattery: true))
        XCTAssertFalse(PowerAssertion.shouldHold(wanted: false, onBattery: false, allowOnBattery: true))
    }

    @MainActor
    func testAssertionIsCreatedAndReleased() {
        let guardian = SleepGuard()
        guardian.update(wanted: true, allowOnBattery: true)
        XCTAssertEqual(guardian.status, .holding)
        XCTAssertTrue(PowerAssertion.currentNames().contains(PowerAssertion.name))
        guardian.update(wanted: false, allowOnBattery: true)
        XCTAssertEqual(guardian.status, .off)
        XCTAssertFalse(PowerAssertion.currentNames().contains(PowerAssertion.name))
        // 共享设置里的默认值：保持，但只在接电源时。
        let share = ShareConfig()
        XCTAssertTrue(share.keepAwake)
        XCTAssertFalse(share.keepAwakeOnBattery)
    }
}

/// 网址诊断：网址的整理、内核日志行的解析、结论引擎的每个场景。
final class DiagnoseTests: XCTestCase {
    func testTargetNormalize() {
        XCTAssertEqual(DiagnoseTarget.normalize("video.example")?.absoluteString, "https://video.example")
        XCTAssertEqual(DiagnoseTarget.normalize(" http://a.b/c?d=1 ")?.absoluteString, "http://a.b/c?d=1")
        XCTAssertNil(DiagnoseTarget.normalize("ftp://x"))
        XCTAssertNil(DiagnoseTarget.normalize(""))
        XCTAssertNil(DiagnoseTarget.normalize("not a url"))
        let https = DiagnoseTarget(url: DiagnoseTarget.normalize("video.example")!, perspective: .mac)
        XCTAssertEqual(https.host, "video.example")
        XCTAssertEqual(https.port, 443)
        let http = DiagnoseTarget(url: DiagnoseTarget.normalize("http://example.com:8080/x")!, perspective: .device)
        XCTAssertEqual(http.port, 8080)
        XCTAssertEqual(DiagnoseTarget(url: DiagnoseTarget.normalize("http://example.com")!, perspective: .mac).port, 80)
    }

    func testRouteTraceParse() throws {
        let matched = try XCTUnwrap(RouteTrace.parse("[TCP] 192.168.1.20:52011 --> www.video.example:443 match DomainSuffix(video.example) using 节点[香港 01]"))
        XCTAssertEqual(matched.host, "www.video.example")
        XCTAssertEqual(matched.port, 443)
        XCTAssertEqual(matched.rule, "DomainSuffix(video.example)")
        XCTAssertEqual(matched.chain, "节点[香港 01]")
        XCTAssertEqual(matched.outbound, "香港 01")
        XCTAssertFalse(matched.isDirect)
        XCTAssertNil(matched.error)
        let direct = try XCTUnwrap(RouteTrace.parse("[TCP] 127.0.0.1:60000 --> cp.cloudflare.com:443 match Match using DIRECT"))
        XCTAssertEqual(direct.rule, "Match")
        XCTAssertTrue(direct.isDirect)
        let mode = try XCTUnwrap(RouteTrace.parse("[TCP] 127.0.0.1:60000(Safari) --> example.com:80 using GLOBAL"))
        XCTAssertEqual(mode.rule, "")
        XCTAssertEqual(mode.chain, "GLOBAL")
        XCTAssertEqual(mode.port, 80)
        let none = try XCTUnwrap(RouteTrace.parse("[TCP] 127.0.0.1:1 --> example.com:443 doesn't match any rule using DIRECT"))
        XCTAssertEqual(none.rule, "没有命中任何规则")
        XCTAssertTrue(none.isDirect)
        let failed = try XCTUnwrap(RouteTrace.parse("[TCP] dial 节点 (match Match/) 192.168.1.20:52012 --> www.video.example:443 error: dial tcp 1.2.3.4:443: i/o timeout"))
        XCTAssertEqual(failed.chain, "节点")
        XCTAssertEqual(failed.rule, "Match/")
        XCTAssertEqual(failed.host, "www.video.example")
        XCTAssertEqual(failed.error, "dial tcp 1.2.3.4:443: i/o timeout")
        let failedNoRule = try XCTUnwrap(RouteTrace.parse("[TCP] dial DIRECT 127.0.0.1:2 --> [::1]:443 error: connection refused"))
        XCTAssertEqual(failedNoRule.chain, "DIRECT")
        XCTAssertEqual(failedNoRule.host, "::1")
        XCTAssertEqual(failedNoRule.rule, "")
        XCTAssertNil(RouteTrace.parse("[UDP] 127.0.0.1:1 --> 1.1.1.1:53 match Match using DIRECT"))
        XCTAssertNil(RouteTrace.parse("time=... level=info msg=something else"))
    }

    func testVerdicts() {
        var facts = DiagnoseFacts(perspective: .mac, host: "video.example")
        // 本机没开代理：直连通就是正常，不通就让开代理。
        facts.direct = ProbeResult(ok: true, status: 200, latencyMs: 120, failure: nil)
        XCTAssertEqual(Verdict.make(facts).headline, "直连正常，本机没开代理")
        facts.direct = ProbeResult(ok: false, status: nil, latencyMs: nil, failure: .timeout)
        facts.engineHasNodes = true
        XCTAssertEqual(Verdict.make(facts).actions.first, .turnOnEngine)
        facts.engineHasNodes = false
        XCTAssertEqual(Verdict.make(facts).actions.first, .openNodes)
        // 经节点访问成功：链路正常。
        facts.engineHasNodes = true
        facts.macRoute = .engine
        facts.proxiedVia = "节点代理"
        facts.proxied = ProbeResult(ok: true, status: 200, latencyMs: 310, failure: nil)
        facts.trace = RouteTrace(host: "video.example", port: 443, rule: "Match", chain: "节点[香港 01]", error: nil)
        XCTAssertEqual(Verdict.make(facts).headline, "链路正常")
        // 规则分到直连但直连不通：让它走节点。
        facts.proxied = ProbeResult(ok: false, status: nil, latencyMs: nil, failure: .timeout)
        facts.trace = RouteTrace(host: "video.example", port: 443, rule: "GeoIP(CN)", chain: "DIRECT", error: "dial tcp 1.2.3.4:443: i/o timeout")
        let pinned = Verdict.make(facts)
        XCTAssertEqual(pinned.headline, "规则把它分到了直连，但直连不通")
        XCTAssertEqual(pinned.actions.first, .pinToProxy("video.example"))
        // 节点连不上：自动选择。
        facts.trace = RouteTrace(host: "video.example", port: 443, rule: "Match", chain: "节点[香港 01]", error: "i/o timeout")
        facts.nodeDelay = 0
        XCTAssertEqual(Verdict.make(facts).actions.first, .autoSelect)
        // 节点能通但这个网站不通：换节点。
        facts.nodeDelay = 86
        XCTAssertEqual(Verdict.make(facts).headline, "节点能通，但这个网站经它打不开")
        // 转发给上游代理失败。
        facts.trace = RouteTrace(host: "video.example", port: 443, rule: "Match", chain: "上游代理", error: "connection refused")
        XCTAssertEqual(Verdict.make(facts).headline, "转发给上游代理失败")
        // 设备视角：入口没监听；链路通但设备没有连接记录。
        var device = DiagnoseFacts(perspective: .device, host: "video.example")
        XCTAssertEqual(Verdict.make(device).actions, [.openShare])
        device.shareListening = true
        device.proxiedVia = "共享入口"
        device.proxied = ProbeResult(ok: true, status: 200, latencyMs: 300, failure: nil)
        device.deviceRecentConnections = 0
        XCTAssertTrue(Verdict.make(device).headline.contains("设备最近没有对它的连接"))
        device.deviceRecentConnections = 3
        XCTAssertEqual(Verdict.make(device).headline, "链路正常")
        XCTAssertEqual(Verdict.Action.pinToProxy("a.b").title, "让 a.b 走节点")
    }

    func testDiagnoseURLCommand() {
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://diagnose?url=https://video.example&from=device")!), .diagnose(url: "https://video.example", device: true))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://diagnose")!), .diagnose(url: nil, device: false))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://settings?page=diagnose")!), .settings(.diagnose))
        XCTAssertEqual(ProbeResult(ok: true, status: 204, latencyMs: 88, failure: nil).summary, "HTTP 204，88 ms")
        XCTAssertEqual(ProbeResult(ok: false, status: nil, latencyMs: nil, failure: .reset).summary, "连接被中断（常见于被屏蔽）")
        XCTAssertFalse(DNSProbe.resolve("localhost").isEmpty)
    }
}

/// 自定义规则：输入的整理、校验、生成的规则行和在配置里的位置。
final class CustomRuleTests: XCTestCase {
    func testNormalizeAndLines() throws {
        XCTAssertEqual(CustomRule.normalize("https://www.Video.Example/watch?v=1"), "www.video.example")
        XCTAssertEqual(CustomRule.normalize("*.video.example"), "video.example")
        XCTAssertEqual(CustomRule.normalize(" .Example.org. "), "example.org")
        XCTAssertEqual(CustomRule.normalize("video.example:443"), "video.example")
        XCTAssertEqual(CustomRule.normalize("10.0.0.0/8"), "10.0.0.0/8")
        XCTAssertEqual(CustomRule.normalize("fe80::1"), "fe80::1")
        XCTAssertEqual(CustomRule(pattern: "Video.Example", policy: .proxy).line, "DOMAIN-SUFFIX,video.example,节点")
        XCTAssertEqual(CustomRule(pattern: "8.8.8.8", policy: .direct).line, "IP-CIDR,8.8.8.8/32,DIRECT,no-resolve")
        XCTAssertEqual(CustomRule(pattern: "10.0.0.0/8", policy: .reject).line, "IP-CIDR,10.0.0.0/8,REJECT,no-resolve")
        XCTAssertEqual(CustomRule(pattern: "fe80::/10", policy: .direct).line, "IP-CIDR6,fe80::/10,DIRECT,no-resolve")
        XCTAssertNil(CustomRule(pattern: "not a domain", policy: .proxy).line)
        XCTAssertNil(CustomRule.validate("video.example"))
        XCTAssertNil(CustomRule.validate("8.8.8.8"))
        XCTAssertNotNil(CustomRule.validate(""))
        XCTAssertNotNil(CustomRule.validate("not a domain"))
        // 配置里的位置：局域网直连之后、预设规则之前；停用的不出现；全局模式下也在。
        var engine = EngineConfig()
        engine.customRules = [CustomRule(pattern: "video.example", policy: .proxy), CustomRule(pattern: "bank.example", policy: .direct)]
        engine.customRules[1].enabled = false
        let input = CoreConfigBuilder.Input(engine: engine, secret: "s", directory: URL(fileURLWithPath: "/tmp/core"), testURL: "https://t", rules: RuleConverter.chinaDirectRules)
        let yaml = CoreConfigBuilder.yaml(input)
        XCTAssertTrue(yaml.contains("  - \"IP-CIDR6,fe80::/10,DIRECT,no-resolve\"\n  - \"DOMAIN-SUFFIX,video.example,节点\"\n  - \"DOMAIN-SUFFIX,cn,DIRECT\"\n"))
        XCTAssertFalse(yaml.contains("bank.example"))
        var global = input
        global.rules = RuleConverter.globalRules
        XCTAssertTrue(CoreConfigBuilder.yaml(global).contains("  - \"DOMAIN-SUFFIX,video.example,节点\"\n  - \"MATCH,节点\"\n"))
        // 共享给设备时同样带着自定义规则。
        var shared = input
        shared.share = ShareInputs(port: 7892, allowedPrefixes: ["127.0.0.0/8"], upstream: .engine)
        XCTAssertTrue(CoreConfigBuilder.yaml(shared).contains("    - \"DOMAIN-SUFFIX,video.example,节点\"\n"))
        // 存取。
        let decoded = try JSONDecoder().decode(EngineConfig.self, from: try JSONEncoder().encode(engine))
        XCTAssertEqual(decoded, engine)
        XCTAssertTrue(try JSONDecoder().decode(EngineConfig.self, from: Data("{}".utf8)).customRules.isEmpty)
    }
}

/// 局域网共享：设置的解析、上游的判断、内核配置里的入口，以及连接列表的归并。
final class ShareTests: XCTestCase {
    func testShareConfig() throws {
        let parsed = ShareConfig.parseClients("192.168.1.20, 192.168.2.0/24; fe80::1\n10.0.0.256 bad/8 10.0.0.0/33 192.168.1.20")
        XCTAssertEqual(parsed.prefixes, ["192.168.1.20/32", "192.168.2.0/24", "fe80::1/128"])
        XCTAssertEqual(parsed.invalid, ["10.0.0.256", "bad/8", "10.0.0.0/33"])
        var share = ShareConfig()
        XCTAssertFalse(share.enabled)
        XCTAssertEqual(share.port, 7892)
        XCTAssertEqual(share.allowedPrefixes, ShareConfig.loopbackPrefixes + ShareConfig.lanPrefixes)
        XCTAssertNil(share.validate())
        // 填了设备就只允许它们，回环仍然在（内核自己的端口也受这份名单限制）。
        share.allowedClients = "192.168.1.20"
        XCTAssertEqual(share.allowedPrefixes, ["127.0.0.0/8", "::1/128", "192.168.1.20/32"])
        share.port = 80
        XCTAssertNotNil(share.validate())
        share.port = 7892
        share.allowedClients = "abc"
        XCTAssertNotNil(share.validate())
        // 本机状态里带着共享设置；旧文件没有这一项时用默认值。
        let old = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"syncEnabled":true}"#.utf8))
        XCTAssertEqual(old.share, ShareConfig())
        XCTAssertTrue(old.syncEnabled)
        var persisted = PersistedState()
        persisted.share.enabled = true
        persisted.share.port = 8899
        persisted.share.allowedClients = "192.168.1.20"
        let decoded = try JSONDecoder().decode(PersistedState.self, from: try JSONEncoder().encode(persisted))
        XCTAssertEqual(decoded.share, persisted.share)
    }

    func testShareUpstreamFollowsTheMac() {
        let http = Profile(name: "公司", color: "#000", kind: .http, host: "proxy.corp", port: 8080)
        let socks = Profile(name: "隧道", color: "#000", kind: .socks5, host: "127.0.0.1", port: 1080)
        let pac = Profile(name: "PAC", color: "#000", kind: .pac, pacURL: "http://x/p.pac")
        let engine = Profile.engineProfile(port: 7890)
        let off = ProxySnapshot()
        XCTAssertEqual(ShareUpstream(status: .off(next: http), snapshot: off), .direct)
        XCTAssertEqual(ShareUpstream(status: .on(engine), snapshot: off), .engine)
        XCTAssertEqual(ShareUpstream(status: .on(http), snapshot: off), .proxy(kind: .http, host: "proxy.corp", port: 8080))
        XCTAssertEqual(ShareUpstream(status: .on(socks), snapshot: off), .proxy(kind: .socks5, host: "127.0.0.1", port: 1080))
        XCTAssertNotNil(ShareUpstream(status: .on(pac), snapshot: off).warning)
        XCTAssertEqual(ShareUpstream(status: .on(pac), snapshot: off).title, "直接连接（PAC 没法转发）")
        // 别的程序设置的系统代理：转发给它；PAC 优先，没法转发。
        var external = ProxySnapshot()
        external.httpsEnabled = true
        external.httpsHost = "10.0.0.8"
        external.httpsPort = 8888
        XCTAssertEqual(ShareUpstream(status: .external(external.summary), snapshot: external), .proxy(kind: .http, host: "10.0.0.8", port: 8888))
        external.pacEnabled = true
        external.pacURL = "http://x/p.pac"
        XCTAssertNotNil(ShareUpstream(status: .external(external.summary), snapshot: external).warning)
        var socksOnly = ProxySnapshot()
        socksOnly.socksEnabled = true
        socksOnly.socksHost = "127.0.0.1"
        socksOnly.socksPort = 1086
        XCTAssertEqual(ShareUpstream(status: .external(socksOnly.summary), snapshot: socksOnly), .proxy(kind: .socks5, host: "127.0.0.1", port: 1086))
        XCTAssertEqual(ShareUpstream.proxy(kind: .socks5, host: "h", port: 1).title, "socks5://h:1")
        XCTAssertEqual(ShareUpstream.direct.summary, "设备经这台 Mac 直连")
    }

    func testCoreConfigWithShare() {
        var engine = EngineConfig()
        var input = CoreConfigBuilder.Input(engine: engine, secret: "s", directory: URL(fileURLWithPath: "/tmp/core"), testURL: "https://t", rules: RuleConverter.chinaDirectRules)
        // 没开共享：没有入口，也没有名单。域名嗅探总是开着（设备按假 IP 来连时也能按域名分流）。
        let plain = CoreConfigBuilder.yaml(input)
        XCTAssertFalse(plain.contains("listeners:"))
        XCTAssertFalse(plain.contains("lan-allowed-ips:"))
        XCTAssertFalse(plain.contains("sub-rules:"))
        XCTAssertTrue(plain.contains("\nsniffer:\n  enable: true\n  parse-pure-ip: true\n  override-destination: true\n"))
        XCTAssertTrue(plain.contains("    TLS:\n      ports: [443, 8443]\n"))
        // 只为共享而运行：本机的代理端口关掉，共享入口在 0.0.0.0，流量直连。
        input.share = ShareInputs(port: 7892, allowedPrefixes: ["127.0.0.0/8", "192.168.0.0/16"], upstream: .direct)
        let direct = CoreConfigBuilder.yaml(input)
        XCTAssertTrue(direct.contains("\nmixed-port: 0\n"))
        XCTAssertTrue(direct.contains("lan-allowed-ips:\n  - \"127.0.0.0/8\"\n  - \"192.168.0.0/16\"\n"))
        XCTAssertTrue(direct.contains("listeners:\n  - name: \"lan-share\"\n    type: mixed\n    listen: \"0.0.0.0\"\n    port: 7892\n    rule: \"lan-share\"\n"))
        XCTAssertTrue(direct.hasSuffix("sub-rules:\n  \"lan-share\":\n    - \"MATCH,DIRECT\"\n"))
        XCTAssertFalse(direct.contains("proxies:\n"))
        XCTAssertFalse(direct.contains("proxy-providers:"))
        // 本机用公司代理：局域网直连，其余转发给它。
        input.share?.upstream = .proxy(kind: .http, host: "proxy.corp", port: 3128)
        let relay = CoreConfigBuilder.yaml(input)
        XCTAssertTrue(relay.contains("proxies:\n  - name: \"上游代理\"\n    type: http\n    server: \"proxy.corp\"\n    port: 3128\n"))
        XCTAssertTrue(relay.contains("  \"lan-share\":\n    - \"DOMAIN-SUFFIX,local,DIRECT\"\n"))
        XCTAssertTrue(relay.contains("    - \"IP-CIDR,192.168.0.0/16,DIRECT,no-resolve\"\n    - \"IP-CIDR,169.254.0.0/16,DIRECT,no-resolve\"\n"))
        XCTAssertTrue(relay.hasSuffix("    - \"MATCH,上游代理\"\n"))
        input.share?.upstream = .proxy(kind: .socks5, host: "127.0.0.1", port: 1080)
        XCTAssertTrue(CoreConfigBuilder.yaml(input).contains("    type: socks5\n    server: \"127.0.0.1\"\n    port: 1080\n"))
        // 本机用内置代理：共享入口按和本机一样的规则分流，本机的代理端口照常开着。
        engine.subscriptions = [Subscription(name: "a", url: "https://x/y")]
        input.engine = engine
        input.share?.upstream = .engine
        let mirrored = CoreConfigBuilder.yaml(input)
        XCTAssertTrue(mirrored.contains("\nmixed-port: 7890\n"))
        XCTAssertTrue(mirrored.contains("proxy-providers:"))
        XCTAssertFalse(mirrored.contains("proxies:\n"))
        XCTAssertTrue(mirrored.contains("  \"lan-share\":\n    - \"DOMAIN-SUFFIX,local,DIRECT\"\n"))
        XCTAssertTrue(mirrored.hasSuffix("    - \"GEOIP,CN,DIRECT\"\n    - \"MATCH,节点\"\n"))
        XCTAssertEqual(CoreConfigBuilder.shareRules(upstream: .unsupported("x"), mainRules: ["MATCH,节点"]), ["MATCH,DIRECT"])
        XCTAssertEqual(CoreConfigBuilder.shareRules(upstream: .engine, mainRules: ["MATCH,节点"]), ["MATCH,节点"])
        // 内置代理停用时不加载订阅，只做共享。
        engine.enabled = false
        input.engine = engine
        let disabled = CoreConfigBuilder.yaml(input)
        XCTAssertFalse(disabled.contains("proxy-providers:"))
        XCTAssertTrue(disabled.contains("\nmixed-port: 0\n"))
    }

    func testShareClientsGrouping() throws {
        let json = """
        {"downloadTotal":1,"uploadTotal":1,"connections":[
          {"id":"1","metadata":{"network":"tcp","type":"Mixed","sourceIP":"192.168.1.20","destinationIP":"1.2.3.4","sourcePort":"1","destinationPort":"443","host":"store.playstation.com","inboundName":"lan-share"},"upload":10,"download":100,"start":"2026-09-27T10:00:01Z","chains":["DIRECT"],"rule":"Match","rulePayload":""},
          {"id":"2","metadata":{"network":"tcp","type":"Mixed","sourceIP":"192.168.1.20","destinationIP":"5.6.7.8","sourcePort":"2","destinationPort":"443","host":"","inboundName":"lan-share"},"upload":1,"download":2,"start":"2026-09-27T10:00:00Z","chains":["DIRECT"],"rule":"Match","rulePayload":""},
          {"id":"3","metadata":{"network":"tcp","type":"Mixed","sourceIP":"192.168.1.30","destinationIP":"","sourcePort":"9","destinationPort":"80","host":"example.org","inboundName":"lan-share"},"upload":0,"download":0,"start":"2026-09-27T10:00:05Z","chains":["上游代理"],"rule":"Match","rulePayload":""},
          {"id":"4","metadata":{"network":"tcp","type":"Mixed","sourceIP":"127.0.0.1","destinationIP":"","sourcePort":"3","destinationPort":"80","host":"example.com","inboundName":""},"upload":5,"download":5,"start":"2026-09-27T10:00:02Z","chains":["节点"],"rule":"Match","rulePayload":""}
        ]}
        """
        struct Envelope: Decodable { var connections: [CoreConnection] }
        let connections = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).connections
        XCTAssertEqual(connections.count, 4)
        XCTAssertEqual(connections[1].metadata.displayHost, "5.6.7.8")
        let clients = ShareClient.group(connections, listener: "lan-share")
        XCTAssertEqual(clients.map(\.ip), ["192.168.1.20", "192.168.1.30"])
        XCTAssertEqual(clients[0].connections, 2)
        XCTAssertEqual(clients[0].upload, 11)
        XCTAssertEqual(clients[0].download, 102)
        XCTAssertEqual(clients[0].lastHost, "store.playstation.com")
        XCTAssertEqual(clients[0].lastOutbound, "DIRECT")
        XCTAssertEqual(clients[1].lastHost, "example.org")
        XCTAssertEqual(clients[1].lastOutbound, "上游代理")
        // 内核在没有连接时给的是 null。
        XCTAssertTrue(ShareClient.group([], listener: "lan-share").isEmpty)
        // 「最近的连接」里的一条：目标、出口、规则、来源。
        let recent = ConnectionRecord(connections[0])
        XCTAssertEqual(recent.target, "store.playstation.com:443")
        XCTAssertEqual(recent.outbound, "DIRECT")
        XCTAssertEqual(recent.rule, "Match")
        XCTAssertEqual(recent.client, "192.168.1.20")
        XCTAssertTrue(recent.isShare)
        XCTAssertEqual(recent.source, "192.168.1.20")
        XCTAssertEqual(recent.route, "DIRECT")
        XCTAssertEqual(ConnectionRecord(connections[1]).target, "5.6.7.8:443")
        let local = ConnectionRecord(connections[3])
        XCTAssertFalse(local.isShare)
        XCTAssertEqual(local.source, "本机")
        XCTAssertEqual(local.route, "节点")
        XCTAssertNil(connections[3].group)
    }

    func testShareURLCommands() {
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://share")!), .share(nil))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://share/on")!), .share(true))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://share/off")!), .share(false))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://share?state=on")!), .share(true))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://settings?page=share")!), .settings(.share))
    }

    func testLocalNetworkAddresses() {
        // 只看有线、Wi‑Fi 和网桥，不含回环和链路本地地址。
        let addresses = LocalNetwork.ipv4Addresses()
        XCTAssertFalse(addresses.values.contains("127.0.0.1"))
        XCTAssertFalse(addresses.values.contains { $0.hasPrefix("169.254.") })
        XCTAssertTrue(addresses.keys.allSatisfy { $0.hasPrefix("en") || $0.hasPrefix("bridge") })
        XCTAssertEqual(LocalNetwork.addresses().map(\.ip).sorted(), Array(addresses.values).sorted())
    }
}
