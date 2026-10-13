import Foundation
import Security

/// 程序的代码签名：读出签名里的 Team ID（苹果开发者账号的 10 位编号），判断另一个程序是不是同一个开发者签的。
/// 用 Developer ID 签名的版本只接受同一个 Team ID 签名的更新：别人重新签过名的包，就算校验和对得上也不装。
/// ad-hoc 签名（没有开发者证书）的版本没有 Team ID，不做这项检查。
enum CodeSignature {
    /// 正在运行的这个程序的 Team ID。
    static let currentTeam: String? = teamIdentifier(of: Bundle.main.bundleURL)

    /// 签名里的 Team ID；ad-hoc 签名、苹果自带的程序、没有签名或读不出来时是 nil。
    static func teamIdentifier(of url: URL) -> String? {
        guard let code = staticCode(url) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
            return nil
        }
        return team
    }

    /// 证书链到苹果的根证书，并且叶子证书的组织单位（OU）是这个 Team ID。
    static func requirementText(teamIdentifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// url 处的程序签名完整（每个架构都查），并且是 teamIdentifier 这个开发者签的。
    static func isSigned(_ url: URL, byTeam teamIdentifier: String) -> Bool {
        guard let code = staticCode(url) else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText(teamIdentifier: teamIdentifier) as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    /// 签名的 cdhash（十六进制）；没有签名或读不出来时是 nil。ad-hoc 签名的程序靠它认出是不是同一份。
    static func cdhash(of url: URL) -> String? {
        guard let code = staticCode(url) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let hash = values[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else {
            return nil
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// 本机套接字连接的对方进程（按连接时内核记下的 audit token 找，不会被换掉的 PID 骗）的签名满足要求。
    static func peer(_ socket: Int32, satisfies requirementText: String) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        // SOL_LOCAL、LOCAL_PEERTOKEN（sys/un.h 里的值，Swift 里没有导出）。
        guard getsockopt(socket, 0, 0x006, &token, &length) == 0, Int(length) == MemoryLayout<audit_token_t>.size else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: tokenData] as CFDictionary, [], &code) == errSecSuccess,
              let code else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }
}
