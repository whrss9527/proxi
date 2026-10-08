// 只在 CI 上按窗口服务器的实际状态等待扩展窗口，不猜测绘制需要几秒。
import AppKit
import CoreGraphics
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1])
let pids = Set(apps.map(\.processIdentifier))
let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
let ready = windows.contains { window in
    guard let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
          pids.contains(pid.int32Value),
          let bounds = window[kCGWindowBounds as String] as? [String: NSNumber] else { return false }
    return (bounds["Width"]?.doubleValue ?? 0) > 100 && (bounds["Height"]?.doubleValue ?? 0) > 50
}
exit(ready ? 0 : 1)
