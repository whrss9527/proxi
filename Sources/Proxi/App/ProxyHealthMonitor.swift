import Foundation

/// 健康检查只记录状态；请求、通知和菜单栏更新由 AppState 执行。
struct ProxyHealthMonitor {
    enum Notice { case failed, recovered }
    private(set) var health: Health = .unknown
    private(set) var interval: TimeInterval = 20
    private var endpoint: String?
    private var failures = 0
    private var successes = 0
    private var announcedFailure = false
    private var lastAnnouncement: [UUID: Date] = [:]

    /// 换配置、关闭检查时清掉连续计数，保留每个配置的通知冷却记录。
    mutating func reset() {
        endpoint = nil
        health = .unknown
        interval = 20
        failures = 0
        successes = 0
        announcedFailure = false
    }

    mutating func record(_ reachable: Bool, profile: Profile, now: Date) -> Notice? {
        let key = "\(profile.id)|\(profile.host)|\(profile.port)"
        if key != endpoint {
            reset()
            endpoint = key
        }
        if reachable {
            failures = 0
            successes = min(successes + 1, 2)
            // 初次成功可确认可用；故障后的恢复要连续两次，单次成功不清故障。
            guard health != .down || successes >= 2 else { return nil }
            let recovered = health == .down
            health = .ok
            interval = 20
            if recovered, announcedFailure {
                announcedFailure = false
                return .recovered
            }
        } else {
            successes = 0
            failures = min(failures + 1, 4)
            guard failures >= 2 else { return nil }
            interval = min(20 * Double(failures), 60)
            guard health != .down else { return nil }
            health = .down
            if lastAnnouncement[profile.id].map({ now.timeIntervalSince($0) >= 600 }) ?? true {
                lastAnnouncement[profile.id] = now
                announcedFailure = true
                return .failed
            }
        }
        return nil
    }
}
