import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage

// 仅在独立测试账户运行。经无障碍树点击实际侧栏按钮，同时读取屏幕合成后的画面。
let output = URL(fileURLWithPath: CommandLine.arguments[1])
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}
func button(_ root: AXUIElement, title: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 25 else { return nil }
    let role = attribute(root, kAXRoleAttribute) as? String
    let label = (attribute(root, kAXTitleAttribute) as? String) ?? (attribute(root, kAXDescriptionAttribute) as? String)
    if role == kAXButtonRole, label == title { return root }
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = button(child, title: title, depth: depth + 1) { return found }
    }
    return nil
}
func dumpTree(_ root: AXUIElement, depth: Int = 0) {
    guard depth < 15 else { return }
    print(String(repeating: " ", count: depth), attribute(root, kAXRoleAttribute) ?? "?" as CFString,
          attribute(root, kAXTitleAttribute) ?? attribute(root, kAXDescriptionAttribute) ?? "" as CFString)
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] { dumpTree(child, depth: depth + 1) }
}
final class Frames: NSObject, SCStreamOutput, @unchecked Sendable {
    let context = CIContext()
    var index = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let frame = CIImage(cvPixelBuffer: buffer)
        if let cg = context.createCGImage(frame, from: frame.extent) {
            let bitmap = NSBitmapImageRep(cgImage: cg)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: output.appendingPathComponent(String(format: "%05d.png", index)))
            }
        }
        index += 1
    }
}
@main struct Main {
    @MainActor static func main() async throws {
        print("OS:", ProcessInfo.processInfo.operatingSystemVersionString, "AX:", AXIsProcessTrusted())
        guard AXIsProcessTrusted() else { fatalError("CI 未授予无障碍权限，不能把未点击侧栏算作通过") }
        let deadline = Date().addingTimeInterval(30)
        while NSRunningApplication.runningApplications(withBundleIdentifier: "com.whrss9527.proxyswitch.engine").isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        NSWorkspace.shared.open(URL(string: "proxi://settings?page=general")!)
        try await Task.sleep(for: .seconds(2))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = content.displays[0]
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = false
        configuration.queueDepth = 8
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: nil)
        let frames = Frames()
        let queue = DispatchQueue(label: "screen-frames")
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        for (appID, title) in [("com.whrss9527.proxyswitch", "Advanced"), ("com.whrss9527.proxyswitch.engine", "General"), ("com.whrss9527.proxyswitch", "Nodes & Subscriptions"), ("com.whrss9527.proxyswitch.engine", "General")] {
            try await Task.sleep(for: .seconds(1))
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first!
            let root = AXUIElementCreateApplication(app.processIdentifier)
            guard let target = button(root, title: title) else { dumpTree(root); fatalError("找不到侧栏按钮：\(title)") }
            print("CLICK", title, Date().timeIntervalSince1970)
            guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { fatalError("侧栏点击失败") }
        }
        try await Task.sleep(for: .seconds(1))
        try await stream.stopCapture()
        queue.sync {}
        print("frames:", frames.index)
    }
}
