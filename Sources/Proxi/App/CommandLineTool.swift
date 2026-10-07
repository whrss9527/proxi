import Foundation

/// 命令行：`proxi status`、`proxi use 公司代理`、`proxi mcp` 这类用法，不启动图形界面。
/// 经本机控制接口操作正在运行的 Proxi；它没在运行时先在后台把它打开。
enum CommandLineTool {
    static let commands: Set<String> = [
        "status", "on", "off", "toggle", "use", "profiles", "test", "logs",
        "call", "tools", "mcp", "help", "version", "env", "shell-init",
    ]

    /// 带了认识的子命令时由命令行处理。--json 写在子命令前面（proxi --json status）也认，不然会再打开一个图形界面的 Proxi。
    static func shouldHandle(_ arguments: [String]) -> Bool {
        guard let first = arguments.dropFirst().first(where: { $0 != "--json" }) else { return false }
        return commands.contains(first) || ["-h", "--help", "--version"].contains(first)
    }

    static func run(_ arguments: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        var args = Array(arguments.dropFirst())
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }
        guard let command = args.first else {
            print(help)
            return 0
        }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "help", "-h", "--help":
                print(help)
                return 0
            case "version", "--version":
                print("Proxi \(UpdateChecker.currentVersion)")
                return 0
            case "env":
                guard let options = ShellEnvironment.options(rest) else { printError(help); return 2 }
                let (config, state) = try ShellEnvironment.snapshot(configURL: Store.configURL, stateURL: Store.stateURL, unset: options.unset)
                let variables = try ShellEnvironment.variables(config: config, state: state, unset: options.unset) {
                    ProxyKeychain.password(for: $0, allowUI: false)
                }
                if json {
                    print(JSONRPC.pretty(["schemaVersion": 1, "shell": options.shell.rawValue,
                                          "enabled": !variables.isEmpty, "variables": variables,
                                          "unset": ShellEnvironment.names.filter { variables[$0] == nil }]))
                } else {
                    print(ShellEnvironment.command(variables, shell: options.shell))
                }
                return 0
            case "shell-init":
                guard rest.count == 1, let shell = ProxyShell(rawValue: rest[0]) else { printError(help); return 2 }
                let script = ShellEnvironment.initialization(shell)
                if json { print(JSONRPC.pretty(["schemaVersion": 1, "shell": shell.rawValue, "script": script])) }
                else { print(script) }
                return 0
            case "tools":
                for tool in ControlCatalog.tools {
                    print(L("%@（%@，%@）：%@", tool.name, tool.title, tool.permission.title, tool.description))
                }
                return 0
            case "mcp":
                runMCP()
                return 0
            default:
                guard let (method, params) = try request(for: command, rest) else {
                    printError(L("用法不对。\n\n") + help)
                    return 2
                }
                let result = try callLaunching(method, params: params, client: "cli")
                if json {
                    print(JSONRPC.pretty(result))
                } else {
                    printHuman(method, result)
                }
                return 0
            }
        } catch let error as ControlError {
            printError(error.message)
            return error.code == JSONRPC.permissionDenied ? 3 : 1
        } catch {
            printError(error.localizedDescription)
            return 1
        }
    }

    // MARK: - 子命令 → 工具

    static func request(for command: String, _ rest: [String]) throws -> (String, [String: Any])? {
        let joined = rest.joined(separator: " ")
        var params: [String: Any] = [:]
        switch command {
        case "status": return ("get_status", params)
        case "on":
            if !rest.isEmpty { params["profile"] = joined }
            return ("turn_on", params)
        case "use":
            guard !rest.isEmpty else { return nil }
            params["profile"] = joined
            return ("use_profile", params)
        case "off": return ("turn_off", params)
        case "toggle": return ("toggle", params)
        case "profiles": return ("list_profiles", params)
        case "test":
            if !rest.isEmpty { params["profile"] = joined }
            return ("test_profiles", params)
        case "logs":
            if let lines = rest.first.flatMap({ Int($0) }) { params["lines"] = lines }
            return ("get_logs", params)
        case "call":
            guard let name = rest.first else { return nil }
            if rest.count > 1 {
                let text = rest[1...].joined(separator: " ")
                guard let data = text.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ControlError.invalid(L("参数要是 JSON 对象，比如 '{\"profile\":\"公司代理\"}'"))
                }
                params = object
            }
            return (name, params)
        default:
            return nil
        }
    }

    // MARK: - 调用

    /// 调用工具；Proxi 没在运行时在后台打开它，等控制接口起来再调。
    static func callLaunching(_ method: String, params: [String: Any], client: String) throws -> [String: Any] {
        do {
            return try ControlSocketClient.call(method, params: params, client: client)
        } catch let error as ControlError where error.code == JSONRPC.notRunning {
            guard launchApp() else { throw error }
            for _ in 0..<60 {
                Thread.sleep(forTimeInterval: 0.25)
                if FileManager.default.fileExists(atPath: UnixSocket.defaultPath) {
                    do {
                        return try ControlSocketClient.call(method, params: params, client: client)
                    } catch let retry as ControlError where retry.code == JSONRPC.notRunning {
                        continue
                    }
                }
            }
            throw error
        }
    }

    /// 在后台打开 Proxi（不抢焦点）。
    static func launchApp() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            process.arguments = ["-g", bundle.path]
        } else {
            process.arguments = ["-g", "-b", "com.whrss9527.proxyswitch"]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func runMCP() {
        let server = MCPServer(version: UpdateChecker.currentVersion) { name, arguments in
            try callLaunching(name, params: arguments, client: "mcp")
        }
        server.run()
    }

    // MARK: - 输出

    static func printHuman(_ method: String, _ result: [String: Any]) {
        if let text = result["text"] as? String {
            print(text)
        }
        func rows(_ key: String) -> [[String: Any]] { (result[key] as? [[String: Any]]) ?? [] }
        switch method {
        case "get_status":
            if let system = result["systemProxy"] as? String {
                print(L("系统代理：%@", system))
            }
            if let ext = result["extension"] as? [String: Any], (ext["enabled"] as? Bool) == true {
                if (ext["running"] as? Bool) == true, let port = ext["port"] as? Int {
                    print(L("代理引擎（扩展）：运行中，本机端口 %@", String(port)))
                } else {
                    print(L("代理引擎（扩展）：已开启，没在运行"))
                }
            }
        case "list_profiles":
            for profile in rows("profiles") {
                print("\((profile["active"] as? Bool) == true ? "●" : " ") \(profile["name"] ?? "")  \(profile["summary"] ?? "")")
            }
        case "test_profiles":
            for item in rows("results") {
                let latency = (item["latencyMs"] as? Int).map { "\($0) ms" } ?? ""
                print("\((item["ok"] as? Bool) == true ? "✓" : "✗") \(item["profile"] ?? "")  \(latency)  \(item["message"] ?? "")")
            }
        case "get_logs":
            print((result["app"] as? String) ?? "")
        default:
            break
        }
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((L("proxi：") + message + "\n").utf8))
    }

    static var help: String { AppLanguage.isEnglish ? helpEnglish : helpChinese }

    // l10n-ignore：中文界面的用法说明，英文的在 helpEnglish。
    static let helpChinese = """
    用法：proxi <命令> [参数] [--json]

    查看
      status                    代理现在的状态
      profiles                  代理配置
      logs [行数]               日志
      env [--shell zsh|bash|fish] [--unset]  当前终端的代理环境
      shell-init zsh|bash|fish   提示符自动刷新钩子

    开关和切换
      on [配置名]               开启代理（不写配置名就开上次用的）
      use <配置名>              切换到某个配置并开启（名字可以只写一部分）
      off                       关闭代理：系统代理、终端、git、npm 的代理都清掉
      toggle                    开着就关，关着就开
      test [配置名]             测试代理服务器能不能连上

    其他
      tools                     全部工具（AI 助手用的也是这些）
      call <工具> ['{"参数":"值"}']
      mcp                       作为 MCP 服务器运行（给 AI 助手用）
      version

    env 和 shell-init 不启动 Proxi。其他控制命令在 Proxi 没运行时自动打开，权限在「自动化」页调整。
    """

    static let helpEnglish = """
    Usage: proxi <command> [arguments] [--json]

    View
      status                    Current proxy status
      profiles                  Proxy profiles
      logs [lines]              Logs
      env [--shell zsh|bash|fish] [--unset]  Proxy environment for this shell
      shell-init zsh|bash|fish   Prompt refresh hook

    Switch
      on [profile]              Turn the proxy on (the last used profile if none is given)
      use <profile>             Switch to a profile and turn it on (part of the name is enough)
      off                       Turn the proxy off: clears the system, Terminal, git and npm proxy settings
      toggle                    Turn it off if it's on, on if it's off
      test [profile]            Check whether the proxy server can be reached

    Other
      tools                     All tools (the same ones AI assistants use)
      call <tool> ['{"param":"value"}']
      mcp                       Run as an MCP server (for AI assistants)
      version

    env and shell-init do not launch Proxi. Other control commands open it in the background. Permissions are in Settings → Automation.
    """
}
