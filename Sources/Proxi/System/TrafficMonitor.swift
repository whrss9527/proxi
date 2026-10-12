import Foundation

/// 网卡的收发字节数。只算 en* 网卡（有线、Wi‑Fi、雷雳桥接），不算回环和隧道接口（隧道流量最终也走物理网卡，算上会重复）。
enum InterfaceCounters {
    struct Sample: Equatable, Sendable {
        var received: UInt32
        var sent: UInt32
    }

    /// 每个网卡当前的计数（系统给的是 32 位计数，会回绕，所以按网卡分别记）。
    static func read() -> [String: Sample] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [:] }
        defer { freeifaddrs(start) }
        var result: [String: Sample] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = start
        while let current = pointer {
            let interface = current.pointee
            pointer = interface.ifa_next
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let data = interface.ifa_data else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en"),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = Sample(received: stats.ifi_ibytes, sent: stats.ifi_obytes)
        }
        return result
    }

    /// 两次采样之间的收发字节数（处理 32 位回绕）。
    static func delta(from old: [String: Sample], to new: [String: Sample]) -> (received: UInt64, sent: UInt64) {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, sample) in new {
            guard let previous = old[name] else { continue }
            received += UInt64(sample.received &- previous.received)
            sent += UInt64(sample.sent &- previous.sent)
        }
        return (received, sent)
    }
}

/// 网速的显示文字：固定 5 个字符宽（数字用等宽字体），例如「   0B」「 9.9K」「 999K」「 1.2M」。
enum SpeedFormatter {
    /// 菜单栏里的网速：数字固定 3 位，整数部分不满 3 位时用小数补足（0.00B、1.23K、12.3K、123K），其余四舍五入；
    /// 单位 B / K / M / G，到 999.5 就进位到下一个单位。位数固定，文字宽度几乎不变，开关可以紧挨着文字。
    static func compact(bytesPerSecond: Int) -> String {
        var value = Double(max(0, bytesPerSecond))
        for unit in ["B", "K", "M", "G"] {
            if value < 999.5 || unit == "G" {
                return threeDigits(value) + unit
            }
            value /= 1024
        }
        return threeDigits(value) + "G"
    }

    /// 3 位数字：9.99 以内两位小数，99.9 以内一位小数，再大取整（最大 999）。
    static func threeDigits(_ value: Double) -> String {
        if value < 9.995 {
            return String(format: "%.2f", value)
        }
        if value < 99.95 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.0f", min(value, 999))
    }

    /// 带单位的完整写法，提示和面板里用。
    static func full(bytesPerSecond: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .binary) + "/s"
    }
}
