import XCTest
@testable import ProxiEngine

final class NodeQueryTests: XCTestCase {
    private let first = UUID()
    private let second = UUID()

    private var nodes: [ProxyNode] {
        [
            ProxyNode(name: "🇭🇰 香港 01", type: "Shadowsocks", delay: 120, subscription: "甲", source: first),
            ProxyNode(name: "日本 Tokyo 02", type: "Vmess", delay: 0, subscription: "甲", source: first),
            ProxyNode(name: "US-LA 03", type: "Trojan", delay: 300, subscription: "乙", source: second),
            ProxyNode(name: "RUSSIA 04", type: "Trojan", delay: nil, subscription: "乙", source: second),
            ProxyNode(name: "剩余流量 10G", type: "Shadowsocks", delay: 80, subscription: "乙", source: second),
            ProxyNode(name: "HK02 IPLC", type: "Shadowsocks", delay: 60, subscription: "乙", source: second),
        ]
    }

    func testRegions() {
        XCTAssertEqual(NodeRegion.detect("🇭🇰 香港 01")?.code, "HK")
        XCTAssertEqual(NodeRegion.detect("HK02 IPLC")?.code, "HK")
        XCTAssertEqual(NodeRegion.detect("日本 Tokyo 02")?.code, "JP")
        XCTAssertEqual(NodeRegion.detect("US-LA 03")?.code, "US")
        // RUSSIA 里的 US 不算美国。
        XCTAssertEqual(NodeRegion.detect("RUSSIA 04")?.code, "RU")
        XCTAssertNil(NodeRegion.detect("剩余流量 10G"))
        XCTAssertEqual(NodeRegion.named("jp")?.flag, "🇯🇵")
        let regions = NodeQuery.regions(in: nodes)
        XCTAssertEqual(regions.map { $0.region?.code ?? "other" }, ["HK", "JP", "US", "RU", "other"])
        XCTAssertEqual(regions.first?.count, 2)
        XCTAssertEqual(NodeQuery.types(in: nodes).map(\.type), ["shadowsocks", "trojan", "vmess"])
    }

    func testFiltersAndSorting() {
        var query = NodeQuery(sort: .delay)
        XCTAssertEqual(query.apply(nodes, favorites: []).map(\.name), ["HK02 IPLC", "剩余流量 10G", "🇭🇰 香港 01", "US-LA 03", "日本 Tokyo 02", "RUSSIA 04"])
        XCTAssertEqual(query.apply(nodes, favorites: ["US-LA 03"]).first?.name, "US-LA 03")
        query.source = first
        XCTAssertEqual(query.apply(nodes, favorites: []).map(\.name), ["🇭🇰 香港 01", "日本 Tokyo 02"])
        query.source = nil
        query.region = "HK"
        XCTAssertEqual(query.apply(nodes, favorites: []).map(\.name), ["HK02 IPLC", "🇭🇰 香港 01"])
        query.region = NodeQuery.otherRegion
        XCTAssertEqual(query.apply(nodes, favorites: []).map(\.name), ["剩余流量 10G"])
        query.region = nil
        query.onlyAvailable = true
        query.type = "trojan"
        XCTAssertEqual(query.apply(nodes, favorites: []).map(\.name), ["US-LA 03"])
        XCTAssertTrue(query.isFiltering)
        query.reset()
        XCTAssertFalse(query.isFiltering)
        XCTAssertEqual(query.sort, .delay)
        query.sort = .name
        query.onlyFavorites = true
        XCTAssertEqual(query.apply(nodes, favorites: ["日本 Tokyo 02", "HK02 IPLC"]).map(\.name), ["HK02 IPLC", "日本 Tokyo 02"])
    }

    func testMakeGroupFromConditions() {
        var query = NodeQuery()
        query.region = "HK"
        query.source = second
        let group = query.makeGroup(name: "香港自动", kind: .urlTest, favorites: [])
        XCTAssertEqual(group.sources, [second])
        XCTAssertEqual(group.matches(nodes.map(\.name)), ["🇭🇰 香港 01", "HK02 IPLC"])
        XCTAssertEqual(query.suggestedGroupName(sourceName: "乙"), "香港自动")
        query.text = "IPLC"
        let narrowed = query.makeGroup(name: "x", kind: .urlTest, favorites: [])
        XCTAssertEqual(narrowed.matches(nodes.map(\.name)), ["HK02 IPLC"])
        XCTAssertNil(PolicyGroup.validateFilter(narrowed.filter))
        var other = NodeQuery()
        other.region = NodeQuery.otherRegion
        XCTAssertEqual(other.makeGroup(name: "x", kind: .select, favorites: []).matches(nodes.map(\.name)), ["剩余流量 10G"])
        var favorites = NodeQuery()
        favorites.onlyFavorites = true
        XCTAssertEqual(favorites.makeGroup(name: "x", kind: .select, favorites: ["US-LA 03"]).matches(nodes.map(\.name)), ["US-LA 03"])
    }
}

final class ControlProtocolTests: XCTestCase {
    func testCatalogAndSchemas() {
        let names = ControlCatalog.tools.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertNotNil(ControlCatalog.tool(named: "get_status"))
        let addRule = ControlCatalog.tool(named: "add_rule")!
        XCTAssertEqual(addRule.permission, .full)
        let schema = addRule.inputSchema
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["required"] as? [String], ["value", "policy"])
        XCTAssertTrue(ControlPermission.full.allows(.operate))
        XCTAssertFalse(ControlPermission.readOnly.allows(.operate))
        XCTAssertFalse(ControlPermission.off.allows(.readOnly))
        let params = ControlParams(["a": " x ", "n": 3, "b": "yes", "e": ""])
        XCTAssertEqual(params.string("a"), "x")
        XCTAssertNil(params.string("e"))
        XCTAssertEqual(params.int("n"), 3)
        XCTAssertEqual(params.bool("b"), true)
        XCTAssertThrowsError(try params.require("missing"))
    }

    func testDefaultPermissionIsEverydayUse() throws {
        // 和 Proxi 一样默认只给「日常操作」：改配置要自己在设置里放开；自己选过的照旧。
        XCTAssertEqual(AutomationConfig().permission, .operate)
        XCTAssertEqual(try JSONDecoder().decode(AutomationConfig.self, from: Data("{}".utf8)).permission, .operate)
        XCTAssertEqual(try JSONDecoder().decode(AutomationConfig.self, from: Data(#"{"permission":"bogus"}"#.utf8)).permission, .operate)
        XCTAssertEqual(try JSONDecoder().decode(AutomationConfig.self, from: Data(#"{"permission":"full"}"#.utf8)).permission, .full)
        XCTAssertFalse(AutomationConfig().permission.allows(.full))
    }

    func testSocketRoundTrip() throws {
        let path = NSTemporaryDirectory() + "ps-test-\(UUID().uuidString.prefix(6)).sock"
        let server = ControlSocketServer(path: path) { line in
            let request = JSONRPC.decode(line) ?? [:]
            let method = request["method"] as? String ?? ""
            if method == "fail" {
                return JSONRPC.encode(JSONRPC.error(id: request["id"], code: JSONRPC.permissionDenied, message: "权限不够"))
            }
            return JSONRPC.encode(JSONRPC.result(id: request["id"], ["echo": method, "client": request["client"] as? String ?? ""]))
        }
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let result = try ControlSocketClient.call("get_status", client: "cli", path: path, timeout: 5)
        XCTAssertEqual(result["echo"] as? String, "get_status")
        XCTAssertEqual(result["client"] as? String, "cli")
        XCTAssertThrowsError(try ControlSocketClient.call("fail", client: "cli", path: path, timeout: 5)) { error in
            XCTAssertEqual((error as? ControlError)?.code, JSONRPC.permissionDenied)
        }
        // 几个并发的客户端。
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let group = DispatchGroup()
        let answers = Counter()
        for index in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                if let result = try? ControlSocketClient.call("m\(index)", client: "cli", path: path, timeout: 5), result["echo"] as? String == "m\(index)" {
                    answers.increment()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(answers.count, 8)
        server.stop()
        XCTAssertThrowsError(try ControlSocketClient.call("x", client: "cli", path: path, timeout: 2)) { error in
            XCTAssertEqual((error as? ControlError)?.code, JSONRPC.notRunning)
        }
    }
}

final class CommandLineTests: XCTestCase {
    func testShouldHandle() {
        XCTAssertTrue(CommandLineTool.shouldHandle(["Proxi", "status"]))
        XCTAssertFalse(CommandLineTool.shouldHandle(["Proxi", "mcp"]))
        XCTAssertFalse(CommandLineTool.shouldHandle(["Proxi", "on"]))
        XCTAssertTrue(CommandLineTool.shouldHandle(["Proxi", "helper"]))
        XCTAssertTrue(CommandLineTool.shouldHandle(["Proxi", "--help"]))
        XCTAssertFalse(CommandLineTool.shouldHandle(["Proxi"]))
        // 系统启动程序时可能带的参数不算命令。
        XCTAssertFalse(CommandLineTool.shouldHandle(["Proxi", "-psn_0_12345"]))
        XCTAssertFalse(CommandLineTool.shouldHandle(["Proxi", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    func testRequests() throws {
        func request(_ args: String..., type: String? = nil, replace: Bool = false, preview: Bool = false) throws -> (String, [String: Any])? {
            try CommandLineTool.request(for: args[0], Array(args.dropFirst()), type: type, replace: replace, preview: preview)
        }
        XCTAssertEqual(try request("status")?.0, "get_status")
        XCTAssertEqual(try request("node", "香港", "02")?.1["name"] as? String, "香港 02")
        XCTAssertNil(try request("node"))
        let group = try XCTUnwrap(try request("group", "组B", "日本", "01"))
        XCTAssertEqual(group.0, "select_group")
        XCTAssertEqual(group.1["member"] as? String, "日本 01")
        let rule = try XCTUnwrap(try request("rule", "add", "ai.example", "美国", type: "suffix"))
        XCTAssertEqual(rule.0, "add_rule")
        XCTAssertEqual(rule.1["policy"] as? String, "美国")
        XCTAssertEqual(rule.1["type"] as? String, "suffix")
        XCTAssertEqual(try request("rule", "remove", "ai.example")?.0, "remove_rule")
        XCTAssertNil(try request("rule", "add", "x"))
        XCTAssertEqual(try request("sub", "update")?.0, "update_subscriptions")
        XCTAssertEqual(try request("ruleset", "add", "广告拦截", "reject")?.1["library"] as? String, "广告拦截")
        XCTAssertEqual(try request("ruleset", "add", "https://x/a.list")?.1["url"] as? String, "https://x/a.list")
        XCTAssertEqual(try request("share", "on")?.1["enabled"] as? Bool, true)
        XCTAssertNil(try request("share", "maybe"))
        XCTAssertEqual(try request("logs", "50")?.1["lines"] as? Int, 50)
        let imported = try XCTUnwrap(try request("import", "https://example.com/c.yaml", replace: true))
        XCTAssertEqual(imported.0, "import_config")
        XCTAssertEqual(imported.1["mode"] as? String, "replace")
        XCTAssertEqual(imported.1["url"] as? String, "https://example.com/c.yaml")
        XCTAssertEqual(try request("import", "https://example.com/c.yaml", preview: true)?.0, "preview_import")
        XCTAssertEqual(try request("call", "select_node", #"{"name":"香港"}"#)?.1["name"] as? String, "香港")
        XCTAssertThrowsError(try request("call", "select_node", "not json"))
        XCTAssertNil(try request("bogus"))
        // 每个子命令对应的工具都在清单里。
        XCTAssertEqual(try request("check", "https://example.com", "节点 1")?.0, "check_url")
        XCTAssertEqual(try request("check", "https://example.com")?.1["url"] as? String, "https://example.com")
        XCTAssertNil(try request("on"))
        for command in ["status", "nodes", "groups", "test", "rules", "subs", "traffic", "logs", "connections", "undo", "history", "export"] {
            let name = try XCTUnwrap(try request(command)?.0, command)
            XCTAssertNotNil(ControlCatalog.tool(named: name), command)
        }
    }
}
