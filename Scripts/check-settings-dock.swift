import AppKit

// 两个程序已由冒烟测试启动。反复打开两边的页面，持续采样应用身份；
// 不只检查切换结束后的状态，避免漏掉中途临时进入 Dock 的情况。
let identifiers = ["com.whrss9527.proxyswitch", "com.whrss9527.proxyswitch.engine"]
let engineURL = URL(fileURLWithPath: CommandLine.arguments[1])
var samples = 0
func checkPolicies() {
    for identifier in identifiers {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first else {
            fatalError("程序没有运行：\(identifier)")
        }
        guard app.activationPolicy == .accessory else {
            fatalError("设置切换时进入了 Dock：\(identifier)，policy=\(app.activationPolicy.rawValue)")
        }
    }
    samples += 1
}
func sample(for seconds: TimeInterval) {
    let until = Date().addingTimeInterval(seconds)
    repeat {
        checkPolicies()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    } while Date() < until
}
func checkForeground(_ identifier: String) {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == identifier else {
        fatalError("目标设置没有取得前台：\(identifier)")
    }
    let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first!
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let hasSettingsWindow = windows.contains { window in
        guard (window[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
              (window[kCGWindowLayer as String] as? Int) == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double else { return false }
        return width >= 760 && height >= 520
    }
    guard hasSettingsWindow else { fatalError("目标设置窗口没有显示：\(identifier)") }
}
checkPolicies()
for page in ["extensions", "diagnostics", "extensions", "diagnostics"] {
    NSWorkspace.shared.open(URL(string: "proxi://settings?page=\(page)")!)
    sample(for: 1.5)
    checkForeground(identifiers[0])
    // 已在运行时使用重新打开事件，与设置页的跨程序打开路径一致。
    NSWorkspace.shared.openApplication(at: engineURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        if let error { fatalError("打开扩展设置失败：\(error)") }
    }
    sample(for: 1.5)
    checkForeground(identifiers[1])
}
print("设置往返切换 4 次，两边始终保持 accessory；采样 \(samples) 次")
