import XCTest
@testable import Proxi

final class ShellEnvironmentTests: XCTestCase {
    func active() -> (AppConfig, PersistedState, Profile) {
        let profile = Profile(name: "Work", color: "#123456", host: "proxy.corp.example", port: 3128, targets: [.environment])
        var config = AppConfig(); config.profiles = [profile]
        var state = PersistedState(); state.enabledByUs = true; state.lastProfileID = profile.id
        return (config, state, profile)
    }

    func testDisabledExplicitUnsetPacAndUnownedEnvironmentClearVariablesWithoutReadingPasswords() throws {
        let (config, state, _) = active()
        let never: (UUID) -> String? = { _ in XCTFail("Should not read keychain"); return nil }
        var disabled = state; disabled.enabledByUs = false
        XCTAssertEqual(try ShellEnvironment.variables(config: config, state: disabled, unset: false, password: never), [:])
        XCTAssertEqual(try ShellEnvironment.variables(config: config, state: state, unset: true, password: never), [:])
        var other = state; other.appliedTargets = [.system]
        XCTAssertEqual(try ShellEnvironment.variables(config: config, state: other, unset: false, password: never), [:])
        var pac = config; pac.profiles[0].kind = .pac
        XCTAssertEqual(try ShellEnvironment.variables(config: pac, state: state, unset: false, password: never), [:])
        var legacy = config; legacy.profiles[0].targets = [.system]
        XCTAssertEqual(try ShellEnvironment.variables(config: legacy, state: state, unset: false, password: never), [:])
    }

    func testPasswordFailureEmitsNoFallbackCredentialAndValuesUseSuccessfulOwnership() throws {
        var (config, state, _) = active()
        config.profiles[0].username = "user"; config.profiles[0].hasPassword = true
        config.profiles[0].targets = [.system]
        state.appliedTargets = [.environment]
        XCTAssertThrowsError(try ShellEnvironment.variables(config: config, state: state, unset: false) { _ in nil })
        let values = try ShellEnvironment.variables(config: config, state: state, unset: false) { _ in "p'ass;$()" }
        XCTAssertTrue(values["http_proxy"]?.contains("user:") == true)
        XCTAssertEqual(values["http_proxy"], values["HTTP_PROXY"])
        XCTAssertEqual(values.count, 8)
    }

    func testCommandsEscapeShellSyntaxAndClearBothEmptyBypassVariables() async throws {
        var (config, state, _) = active()
        config.profiles[0].noProxy = " \n"
        let values = try ShellEnvironment.variables(config: config, state: state, unset: false) { _ in nil }
        XCTAssertNil(values["no_proxy"])
        for shell in [ProxyShell.bash, .zsh] {
            let command = ShellEnvironment.command(values, shell: shell)
            let result = try await Shell.run("/bin/" + shell.rawValue, ["-c", "export no_proxy=old NO_PROXY=old; " + command + "; printf '%s|%s|%s' \"$http_proxy\" \"${no_proxy-unset}\" \"${NO_PROXY-unset}\""])
            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(result.output, "http://proxy.corp.example:3128|unset|unset")
            let escaped = ShellEnvironment.command(["http_proxy": "literal' ; $(echo injected)"], shell: shell)
            let roundtrip = try await Shell.run("/bin/" + shell.rawValue, ["-c", escaped + "; printf '%s' \"$http_proxy\""])
            XCTAssertEqual(roundtrip.output, "literal' ; $(echo injected)")
        }
    }

    func testSnapshotWorksWithoutAppAndDoesNotOverwriteMalformedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("config.json"), stateURL = root.appendingPathComponent("state.json")
        let (config, state, _) = active()
        try JSONEncoder().encode(config).write(to: configURL)
        try JSONEncoder().encode(state).write(to: stateURL)
        let (loadedConfig, loadedState) = try ShellEnvironment.snapshot(configURL: configURL, stateURL: stateURL, unset: false)
        XCTAssertEqual(loadedConfig?.profiles, config.profiles)
        XCTAssertEqual(loadedState, state)
        let bad = Data("not json".utf8); try bad.write(to: stateURL)
        XCTAssertThrowsError(try ShellEnvironment.snapshot(configURL: configURL, stateURL: stateURL, unset: false))
        XCTAssertEqual(try Data(contentsOf: stateURL), bad)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
        XCTAssertFalse(try ShellEnvironment.snapshot(configURL: configURL, stateURL: stateURL, unset: true).1.enabledByUs)
    }

    func testOptionsAndCommandRecognition() {
        XCTAssertTrue(CommandLineTool.shouldHandle(["proxi", "env"]))
        XCTAssertTrue(CommandLineTool.shouldHandle(["proxi", "--json", "shell-init", "bash"]))
        XCTAssertEqual(ShellEnvironment.options(["--unset", "--shell", "fish"])?.shell, .fish)
        XCTAssertTrue(ShellEnvironment.options(["--unset"])?.unset == true)
        for arguments in [["--shell"], ["--shell", "powershell"], ["extra"]] { XCTAssertNil(ShellEnvironment.options(arguments)) }
    }

    func testPromptHooksRefreshAndKeepExistingHooksWhenInitializedTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("proxi")
        try "#!/bin/sh\nprintf \"export http_proxy='http://new:3128'\\n\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        for shell in [ProxyShell.bash, .zsh] {
            let hook = ShellEnvironment.initialization(shell)
            let prefix = "export PATH=" + TerminalCommands.shellQuote(root.path) + ":$PATH; "
            let existing = shell == .bash ? "PROMPT_COMMAND='echo old'; " : "autoload -Uz add-zsh-hook; function old_hook() { :; }; add-zsh-hook precmd old_hook; "
            let inspect = shell == .bash ? "printf '%s|%s' \"$http_proxy\" \"$PROMPT_COMMAND\"" : "printf '%s|%s' \"$http_proxy\" \"${precmd_functions[*]}\""
            let result = try await Shell.run("/bin/" + shell.rawValue, ["-c", prefix + existing + hook + "\n" + hook + "\n_proxi_prompt; " + inspect])
            XCTAssertTrue(result.succeeded, result.output)
            XCTAssertTrue(result.output.hasPrefix("http://new:3128|"), result.output)
            XCTAssertTrue(result.output.contains(shell == .bash ? "echo old" : "old_hook"), result.output)
            XCTAssertEqual(result.output.components(separatedBy: "_proxi_prompt").count, 2, result.output)
        }
    }

    func testFishHookAndCommands() async throws {
        guard let fish = Shell.lookPath("fish") else {
            if ProcessInfo.processInfo.environment["PROXI_REQUIRE_FISH"] == "1" { XCTFail("CI must install fish"); return }
            throw XCTSkip("fish is verified in CI")
        }
        let text = "literal' ; $(echo injected)"
        let command = ShellEnvironment.command(["http_proxy": text], shell: .fish)
        let result = try await Shell.run(fish, ["-c", command + "; printf '%s' \"$http_proxy\""])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.output, text)
        let hook = ShellEnvironment.initialization(.fish)
        let exercise = "set -g fish_greeting ''; function proxi; echo \"set -gx http_proxy 'http://new:3128'\"; end; " + hook + "\n" + hook + "\nemit fish_prompt; printf '%s' \"$http_proxy\""
        let refreshed = try await Shell.run(fish, ["-c", exercise])
        XCTAssertTrue(refreshed.succeeded, refreshed.output)
        XCTAssertEqual(refreshed.output, "http://new:3128")
    }
}
