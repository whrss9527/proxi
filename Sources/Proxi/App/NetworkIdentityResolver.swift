import Foundation

/// 默认网关刚出现时 ARP 可能还没填好；匹配规则前有上限地补读身份。
@MainActor
struct NetworkIdentityResolver {
    let read: () async -> NetworkIdentity
    let probe: (String) async -> Void
    var pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(400)) }

    func resolve() async -> NetworkIdentity {
        var identity = await read()
        // 初次读取加两次重试；没有 IPv4 网关时不发探测请求。
        for _ in 0..<2 {
            guard !Task.isCancelled, identity.awaitingRouterMAC, let ip = identity.routerIP else { break }
            await probe(ip)
            do { try await pause() } catch { break }
            guard !Task.isCancelled else { break }
            identity = await read()
        }
        return identity
    }
}

extension NetworkIdentity {
    /// MAC 没读到时不要把这次匹配当成同一网络的最终结果。
    var awaitingRouterMAC: Bool {
        routerMAC == nil && routerIP.map(NetworkAutomation.isIPv4Address) == true
    }
}
