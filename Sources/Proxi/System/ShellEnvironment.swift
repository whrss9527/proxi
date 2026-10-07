import Foundation

enum ProxyShell: String, CaseIterable {
    case zsh, bash, fish

    static var current: ProxyShell {
        let name = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").lastPathComponent
        return ProxyShell(rawValue: name) ?? .zsh
    }
}

/// 只生成当前 shell 的命令，不开启应用、不修改 launchd 或用户配置。
enum ShellEnvironment {
    static let names = ["http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]

    static func options(_ arguments: [String]) -> (shell: ProxyShell, unset: Bool)? {
        var shell = ProxyShell.current, unset = false, index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--unset": unset = true
            case "--shell":
                index += 1
                guard index < arguments.count, let value = ProxyShell(rawValue: arguments[index]) else { return nil }
                shell = value
            default: return nil
            }
            index += 1
        }
        return (shell, unset)
    }

    /// 只读快照；读取失败直接报错，不创建配置、备份或 GUI。
    static func snapshot(configURL: URL, stateURL: URL, unset: Bool) throws -> (AppConfig?, PersistedState) {
        if unset { return (nil, PersistedState()) }
        let decoder = JSONDecoder()
        let state = FileManager.default.fileExists(atPath: stateURL.path)
            ? try decoder.decode(PersistedState.self, from: Data(contentsOf: stateURL)) : PersistedState()
        guard state.enabledByUs, FileManager.default.fileExists(atPath: configURL.path) else { return (nil, state) }
        return (try decoder.decode(AppConfig.self, from: Data(contentsOf: configURL)), state)
    }

    static func variables(config: AppConfig?, state: PersistedState, unset: Bool,
                          password: (UUID) -> String?) throws -> [String: String] {
        guard !unset, state.enabledByUs, let id = state.lastProfileID,
              let profile = config?.profiles.first(where: { $0.id == id }), profile.kind != .pac,
              (state.appliedTargets ?? Array(profile.targets)).contains(.environment) else { return [:] }
        var secret = ""
        if profile.needsPassword {
            guard let saved = password(id) else {
                throw ControlError.invalid(L("无法非交互读取代理密码；终端环境保持不变。"))
            }
            secret = saved
        }
        let url = profile.proxyURL(password: secret)
        var result: [String: String] = [:]
        for name in names where name.lowercased() != "no_proxy" { result[name] = url }
        if let bypass = EnvironmentProxy.noProxyValue(profile.noProxy) {
            result["no_proxy"] = bypass
            result["NO_PROXY"] = bypass
        }
        return result
    }

    static func command(_ variables: [String: String], shell: ProxyShell) -> String {
        if shell == .fish {
            return names.map { name in
                variables[name].map { "set -gx \(name) \(TerminalCommands.shellQuote($0))" } ?? "set -e \(name)"
            }.joined(separator: "; ")
        }
        let unset = names.filter { variables[$0] == nil }
        let values = names.compactMap { name in variables[name].map { "\(name)=\(TerminalCommands.shellQuote($0))" } }
        return [unset.isEmpty ? "" : "unset " + unset.joined(separator: " "),
                values.isEmpty ? "" : "export " + values.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: "; ")
    }

    /// 重复执行初始化不会重复添加钩子；已有提示符命令保留。
    static func initialization(_ shell: ProxyShell) -> String {
        switch shell {
        case .zsh:
            return """
            function _proxi_prompt() {
              local _proxi_env
              if _proxi_env="$(proxi env --shell zsh 2>/dev/null)"; then eval "$_proxi_env"; fi
            }
            autoload -Uz add-zsh-hook
            add-zsh-hook precmd _proxi_prompt
            """
        case .bash:
            return """
            _proxi_prompt() {
              local _proxi_env
              if _proxi_env="$(proxi env --shell bash 2>/dev/null)"; then eval "$_proxi_env"; fi
            }
            if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
              [[ " ${PROMPT_COMMAND[*]} " == *" _proxi_prompt "* ]] || PROMPT_COMMAND=(_proxi_prompt "${PROMPT_COMMAND[@]}")
            else
              case ";${PROMPT_COMMAND-};" in
                *";_proxi_prompt;"*) ;;
                *) PROMPT_COMMAND="_proxi_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
              esac
            fi
            """
        case .fish:
            return """
            function _proxi_prompt --on-event fish_prompt
              set -l _proxi_env (proxi env --shell fish 2>/dev/null)
              if test $status -eq 0
                eval $_proxi_env
              end
            end
            """
        }
    }
}
