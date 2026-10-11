import Foundation
import Security
import SystemConfiguration

/// 每个服务独立执行，管理员授权合并成一次；某个服务失败不阻断其他服务。
enum SystemServiceProxy {
    struct Plan: Sendable {
        var id: String
        var name: String
        var desired: DesiredProxy
    }

    static func read(also ids: [String] = []) -> SystemServiceRead {
        var result = SystemServiceRead()
        guard let preferences = SCPreferencesCreate(nil, "Proxi" as CFString, nil) else {
            result.failures["SystemConfiguration"] = L("无法读取")
            return result
        }
        var all = NetworkServices.all()
        for id in ids where !all.contains(where: { $0.id == id || $0.name == id }) {
            if let service = SCNetworkServiceCopy(preferences, id as CFString) {
                all.append(NetworkServices.Service(name: (SCNetworkServiceGetName(service) as String?) ?? id, bsdName: nil, enabled: false, id: id))
            }
        }
        let selected = Set(NetworkServices.selectServices(services: all, isActive: NetworkServices.isActive(bsdName:)).map(\.id) + all.filter { ids.contains($0.id) || ids.contains($0.name) }.map(\.id))
        for item in all where selected.contains(item.id) {
            do {
                guard let service = SCNetworkServiceCopy(preferences, item.id as CFString),
                      let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
                    throw SystemProxyError.command(L("无法读取"))
                }
                let dictionary = SCNetworkProtocolGetConfiguration(proxies) as? [String: Any]
                result.settings.append(try SystemServiceSettings(id: item.id, name: item.name, dictionary: dictionary,
                    protocolEnabled: SCNetworkProtocolGetEnabled(proxies)))
            } catch { result.failures[item.name] = Redact.secrets(error.localizedDescription) }
        }
        return result
    }

    static func apply(_ plans: [Plan],
                      run: (String, [String]) async throws -> ShellResult = { try await Shell.run($0, $1) },
                      authorize: (String) async throws -> ShellResult = { try await Shell.run(SystemProxy.osascriptPath, ["-e", $0], timeout: 180) }) async -> SystemServiceResult {
        var result = SystemServiceResult()
        var privileged: [Plan] = []
        for plan in plans {
            do {
                for arguments in plan.desired.commands(service: plan.name) {
                    let command = try await run(SystemProxy.networksetupPath, arguments)
                    let text = Redact.secrets(command.trimmedOutput, known: plan.desired.passwords)
                    if !command.succeeded || text.contains("Error") {
                        if SystemProxy.isAdminError(text) { throw SystemProxyError.needsAdmin(text) }
                        throw SystemProxyError.command(L("networksetup %@ 失败：%@", arguments[0], text))
                    }
                }
                result.succeeded.append(plan.id)
            } catch SystemProxyError.needsAdmin {
                privileged.append(plan)
            } catch { result.failures[plan.name] = Redact.secrets(error.localizedDescription, known: plan.desired.passwords) }
        }
        guard !privileged.isEmpty else { return result }
        do {
            let command = try await authorize(authorizationScript(privileged))
            guard command.succeeded else {
                throw SystemProxyError.needsAdmin(Redact.secrets(command.trimmedOutput, known: privileged.flatMap { $0.desired.passwords }))
            }
            let statuses = parseStatuses(command.trimmedOutput)
            for (index, plan) in privileged.enumerated() {
                if let status = statuses[index], status == nil { result.succeeded.append(plan.id) }
                else { result.failures[plan.name] = Redact.secrets(statuses[index].flatMap { $0 } ?? L("无法读取"), known: plan.desired.passwords) }
            }
        } catch {
            let text = Redact.secrets(error.localizedDescription, known: privileged.flatMap { $0.desired.passwords })
            for plan in privileged { result.failures[plan.name] = text }
        }
        return result
    }

    /// shell 每个函数遇错只结束本服务；输出固定编号和 base64，避免错误文本混进状态协议。
    static func authorizationScript(_ plans: [Plan]) -> String {
        var lines: [String] = []
        for (index, plan) in plans.enumerated() {
            lines.append("service_\(index)() {")
            for arguments in plan.desired.commands(service: plan.name) {
                let command = ([SystemProxy.networksetupPath] + arguments).map(Shell.shellQuote).joined(separator: " ")
                lines.append("out=$(\(command) 2>&1); code=$?; if [ \"$code\" -ne 0 ]; then return 1; fi; case \"$out\" in *Error*) return 1;; esac")
            }
            lines.append("return 0; }")
            lines.append("if service_\(index); then printf '\(index)\\tOK\\n'; else printf '\(index)\\tERR\\t'; printf '%s' \"$out\" | /usr/bin/base64 | /usr/bin/tr -d '\\n'; printf '\\n'; fi")
        }
        return "do shell script " + Shell.appleScriptString(lines.joined(separator: "\n")) + " with administrator privileges"
    }

    static func parseStatuses(_ text: String) -> [Int: String?] {
        var statuses: [Int: String?] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, let index = Int(fields[0]) else { continue }
            if fields[1] == "OK" { statuses.updateValue(nil, forKey: index) }
            else if fields.count == 3, fields[1] == "ERR", let data = Data(base64Encoded: String(fields[2])) {
                statuses[index] = String(decoding: data, as: UTF8.self)
            }
        }
        return statuses
    }

    /// 恢复完整协议字典，避免 networksetup 丢掉关着的地址和未知字段。阻塞的授权和提交在独立队列上。
    static func restore(_ settings: [SystemServiceSettings]) async -> SystemServiceResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var authorization: AuthorizationRef?
                defer { if let authorization { AuthorizationFree(authorization, []) } }
                let first = writeConfigurations(settings, authorization: nil)
                guard first.needsAuthorization else { continuation.resume(returning: first.result); return }
                let status = AuthorizationCreate(nil, nil, [], &authorization)
                guard status == errAuthorizationSuccess, let authorization else {
                    continuation.resume(returning: authorizationFailure(settings, status: status)); return
                }
                let granted = "system.preferences.network".withCString { name in
                    var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                    return withUnsafeMutablePointer(to: &item) { pointer in
                        var rights = AuthorizationRights(count: 1, items: pointer)
                        return AuthorizationCopyRights(authorization, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
                    }
                }
                guard granted == errAuthorizationSuccess else {
                    continuation.resume(returning: authorizationFailure(settings, status: granted)); return
                }
                continuation.resume(returning: writeConfigurations(settings, authorization: authorization).result)
            }
        }
    }

    private static func authorizationFailure(_ settings: [SystemServiceSettings], status: OSStatus) -> SystemServiceResult {
        SystemServiceResult(failures: Dictionary(uniqueKeysWithValues: settings.map { ($0.name, L("修改系统代理需要管理员权限：%@", String(status))) }))
    }

    private static func writeConfigurations(_ settings: [SystemServiceSettings], authorization: AuthorizationRef?) -> (result: SystemServiceResult, needsAuthorization: Bool) {
        let preferences: SCPreferences?
        if let authorization { preferences = SCPreferencesCreateWithAuthorization(nil, "Proxi" as CFString, nil, authorization) }
        else { preferences = SCPreferencesCreate(nil, "Proxi" as CFString, nil) }
        guard let preferences else { return (authorizationFailure(settings, status: OSStatus(SCError())), false) }
        var result = SystemServiceResult()
        var needsAuthorization = false
        guard SCPreferencesLock(preferences, true) else {
            return (authorizationFailure(settings, status: OSStatus(SCError())), SCError() == kSCStatusAccessError)
        }
        defer { SCPreferencesUnlock(preferences) }
        var modified: [SystemServiceSettings] = []
        for item in settings {
            // 服务已删除时无设置可恢复；不要把同名的新服务误当成原服务。
            guard let service = SCNetworkServiceCopy(preferences, item.id as CFString) else { result.succeeded.append(item.id); continue }
            guard let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
                result.failures[item.name] = L("无法读取"); continue
            }
            if SCNetworkProtocolSetConfiguration(proxies, item.dictionary.map { $0 as CFDictionary }) && SCNetworkProtocolSetEnabled(proxies, item.protocolEnabled) {
                modified.append(item)
            } else {
                let status = SCError()
                needsAuthorization = needsAuthorization || status == kSCStatusAccessError
                result.failures[item.name] = String(cString: SCErrorString(status))
            }
        }
        if !modified.isEmpty {
            if SCPreferencesCommitChanges(preferences) && SCPreferencesApplyChanges(preferences) {
                result.succeeded += modified.map(\.id)
            } else {
                let status = SCError()
                needsAuthorization = needsAuthorization || status == kSCStatusAccessError
                for item in modified { result.failures[item.name] = String(cString: SCErrorString(status)) }
            }
        }
        return (result, needsAuthorization)
    }
}

enum SystemServiceCleanup {
    static func direct(_ records: [String: SystemServiceBackup], also services: [String] = [], backend: ProxyBackend) async -> SystemServiceResult {
        let read = backend.readSystemServices(also: Array(records.keys) + services)
        let plans = read.settings.map { item in
            SystemServiceProxy.Plan(id: item.id, name: item.name,
                desired: DesiredProxy(offWithAutoDiscovery: records[item.id]?.autoDiscovery ?? item.snapshot.autoDiscovery,
                                      bypassDomains: item.snapshot.exceptions))
        }
        var result = await backend.applySystemPlans(plans)
        result.failures.merge(read.failures) { _, new in new }
        // 已删除的稳定 ID 不写入同名替代服务。
        let existing = Set(read.settings.map(\.id))
        if read.failures.isEmpty { result.succeeded += records.keys.filter { !existing.contains($0) } }
        return result
    }
}
