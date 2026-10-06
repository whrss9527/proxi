import Foundation

/// 环境变量 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY 写到用户的 launchd 环境（launchctl setenv），
/// 只影响之后由 launchd 新启动的程序；已运行的终端 App 新开标签页或窗口仍继承旧环境，须重开整个 App 或粘贴终端命令。
/// 大小写两种都设置：curl 等只认小写的 http_proxy。
enum EnvironmentProxy {
    static let launchctlPath = "/bin/launchctl"
    static let names = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]

    /// 空值表示不设置绕过列表，终端复制命令和 launchd 使用同一语义。
    static func noProxyValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func set(proxyURL: String, noProxy: String) async throws {
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            try await setenv(name, proxyURL)
        }
        for name in ["NO_PROXY", "no_proxy"] {
            if let value = noProxyValue(noProxy) {
                try await setenv(name, value)
            } else {
                try await unsetenv(name)
            }
        }
    }

    static func clear() async throws {
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"] {
            try await unsetenv(name)
        }
    }

    /// 当前 launchd 环境里的值，诊断显示用（密码已经隐藏）。
    static func current() async -> [String: String] {
        var values: [String: String] = [:]
        for name in names {
            let result = try? await Shell.run(launchctlPath, ["getenv", name], timeout: 10)
            values[name] = Redact.secrets(result?.trimmedOutput ?? "")
        }
        return values
    }

    private static func setenv(_ name: String, _ value: String) async throws {
        let result = try await Shell.run(launchctlPath, ["setenv", name, value], timeout: 10)
        if !result.succeeded {
            throw SystemProxyError.command(L("launchctl setenv %@ 失败：%@", name, result.trimmedOutput))
        }
    }

    private static func unsetenv(_ name: String) async throws {
        let result = try await Shell.run(launchctlPath, ["unsetenv", name], timeout: 10)
        if !result.succeeded {
            throw SystemProxyError.command(L("launchctl unsetenv %@ 失败：%@", name, result.trimmedOutput))
        }
    }
}

/// git 全局代理：调用 git 本身修改 ~/.gitconfig。
/// 带密码的地址不放到命令行上：写进只有自己能读的一个文件（git-proxy.inc），~/.gitconfig 里用 include.path 引用它。
enum GitProxy {
    static var gitPath: String? { Shell.lookPath("git") }

    static var credentialFile: URL { Store.directory.appendingPathComponent("git-proxy.inc") }

    /// include 文件的内容。
    static func credentialFileContent(proxyURL: String) -> String {
        let value = "\"" + proxyURL.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return "# Proxi 写的代理设置（带密码，只有你自己能读），关闭代理时删掉。\n[http]\n\tproxy = \(value)\n[https]\n\tproxy = \(value)\n"  // l10n-ignore：文件内容
    }

    /// git config --unset-all 用的正则：只匹配这个文件的路径。
    static func pathPattern(_ path: String) -> String {
        var pattern = "^"
        for character in path {
            if ".[]()*+?{}|^$\\".contains(character) { pattern.append("\\") }
            pattern.append(character)
        }
        return pattern + "$"
    }

    static func set(proxyURL: String) async throws {
        guard let git = gitPath else { throw SystemProxyError.command(L("没有找到 git")) }
        try await clear()
        if Redact.secrets(proxyURL) != proxyURL {
            let url = credentialFile
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: url)
            guard fm.createFile(atPath: url.path, contents: Data(credentialFileContent(proxyURL: proxyURL).utf8), attributes: [.posixPermissions: 0o600]) else {
                throw SystemProxyError.command(L("写不了 %@", url.path))
            }
            let result = try await Shell.run(git, ["config", "--global", "--add", "include.path", url.path])
            if !result.succeeded {
                throw SystemProxyError.command(L("git config %@ 失败：%@", "include.path", result.trimmedOutput))
            }
            return
        }
        for key in ["http.proxy", "https.proxy"] {
            let result = try await Shell.run(git, ["config", "--global", key, proxyURL])
            if !result.succeeded {
                throw SystemProxyError.command(L("git config %@ 失败：%@", key, result.trimmedOutput))
            }
        }
    }

    /// 清除；没装 git 时不算错误。
    static func clear() async throws {
        guard let git = gitPath else { return }
        for key in ["http.proxy", "https.proxy"] {
            let result = try await Shell.run(git, ["config", "--global", "--unset-all", key])
            // 退出码 5 表示这个键本来就不存在。
            if !result.succeeded && result.status != 5 {
                throw SystemProxyError.command(L("git config --unset %@ 失败：%@", key, result.trimmedOutput))
            }
        }
        let include = try await Shell.run(git, ["config", "--global", "--unset-all", "include.path", pathPattern(credentialFile.path)])
        if !include.succeeded && include.status != 5 {
            throw SystemProxyError.command(L("git config --unset %@ 失败：%@", "include.path", include.trimmedOutput))
        }
        try? FileManager.default.removeItem(at: credentialFile)
    }

    /// 现在生效的 http.proxy（包括 include 进来的），密码已经隐藏。
    static func current() async -> String {
        guard let git = gitPath else { return "" }
        let result = try? await Shell.run(git, ["config", "--global", "--includes", "--get", "http.proxy"], timeout: 10)
        return Redact.secrets(result?.trimmedOutput ?? "")
    }
}

/// npm / pnpm / yarn 1 的代理：改用户目录的 .npmrc。
enum NpmProxy {
    static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".npmrc")
    }

    static func set(proxyURL: String, noProxy: String) throws {
        try write(update(read(), proxyURL: proxyURL, noProxy: noProxy))
    }

    static func clear() throws {
        try write(update(read(), proxyURL: "", noProxy: ""))
    }

    /// 现在的设置，密码已经隐藏。
    static func current() -> [String: String] {
        var values: [String: String] = [:]
        for line in ((try? read()) ?? "").split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, ["proxy", "https-proxy", "noproxy"].contains(parts[0]) {
                values[parts[0]] = Redact.secrets(parts[1])
            }
        }
        return values
    }

    /// 更新 .npmrc 的文本：proxy、https-proxy、noproxy 三项改成新值（空值表示删除），其余行原样保留。
    static func update(_ content: String, proxyURL: String, noProxy: String) -> String {
        let wanted: [(String, String)] = [("proxy", proxyURL), ("https-proxy", proxyURL), ("noproxy", noProxy)]
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var kept: [String] = []
        for line in lines {
            let key = line.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if wanted.contains(where: { $0.0 == key }) {
                continue
            }
            kept.append(line)
        }
        for (key, value) in wanted where !value.isEmpty {
            kept.append("\(key)=\(value)")
        }
        return kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
    }

    /// 读 .npmrc；没有这个文件时是空的。文件在但读不出来（没有权限、不是 UTF-8）时报错，
    /// 不能当成空文件再整个写回去，那样里面的镜像地址、登录令牌就都没了。
    private static func read() throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw SystemProxyError.command(L("读不了 %@，没有改它：%@", path, error.localizedDescription))
        }
    }

    /// 写回 .npmrc：先写到同一个目录里的临时文件再换过去（写到一半不会留下半个文件）。
    /// .npmrc 是指向 dotfiles 的链接时写到它指向的文件，链接本身不动；里面有密码时只让自己能读，没有时保留原来的权限。
    private static func write(_ content: String) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        // 本来就没有 .npmrc、也没什么要写的：不凭空建一个空文件。
        if content.isEmpty && !fm.fileExists(atPath: target.path) { return }
        let secret = Redact.secrets(content) != content
        let existing = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue
        let mode = secret ? 0o600 : (existing ?? 0o644)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".npmrc.proxi-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: Data(content.utf8), attributes: [.posixPermissions: mode]) else {
            throw SystemProxyError.command(L("写不了 %@", target.path))
        }
        if rename(temporary.path, target.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: temporary)
            throw SystemProxyError.command(L("写不了 %@：%@", target.path, reason))
        }
    }
}
