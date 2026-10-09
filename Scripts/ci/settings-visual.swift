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
func splitter(_ root: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 25 else { return nil }
    if attribute(root, kAXRoleAttribute) as? String == kAXSplitterRole { return root }
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = splitter(child, depth: depth + 1) { return found }
    }
    return nil
}
func dumpTree(_ root: AXUIElement, depth: Int = 0) {
    guard depth < 15 else { return }
    print(String(repeating: " ", count: depth), attribute(root, kAXRoleAttribute) ?? "?" as CFString,
          attribute(root, kAXTitleAttribute) ?? attribute(root, kAXDescriptionAttribute) ?? "" as CFString)
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] { dumpTree(child, depth: depth + 1) }
}
func pageIdentifiers(_ root: AXUIElement, depth: Int = 0) -> Set<String> {
    guard depth < 25 else { return [] }
    var found = Set<String>()
    if let identifier = attribute(root, kAXIdentifierAttribute) as? String,
       identifier.hasPrefix("settings-page-") { found.insert(identifier) }
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        found.formUnion(pageIdentifiers(child, depth: depth + 1))
    }
    return found
}
func dividerX(_ root: AXUIElement) -> CGFloat {
    guard let divider = splitter(root), let value = attribute(divider, kAXPositionAttribute) else {
        fatalError("找不到分栏位置")
    }
    var point = CGPoint.zero
    AXValueGetValue(value as! AXValue, .cgPoint, &point)
    return point.x
}
func visibleSettingsOwners() -> Set<pid_t> {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return Set(windows.compactMap { item in
        guard let bounds = item[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width >= 760,
              item[kCGWindowLayer as String] as? Int == 0,
              (item[kCGWindowAlpha as String] as? Double ?? 0) >= 0.99 else { return nil }
        return item[kCGWindowOwnerPID as String] as? pid_t
    })
}
final class Frames: NSObject, SCStreamOutput, @unchecked Sendable {
    var index = 0
    var rect: CGRect = .zero
    var scale: CGFloat = 1
    var captured: [(Data, Int, Int, Int)] = []
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let x = Int((rect.minX + 4) * scale), y = Int((rect.minY + 150) * scale)
        let p = base + y * bytes + x * 4
        print("PIXEL", index, CMSampleBufferGetPresentationTimeStamp(sample).seconds, p[0], p[1], p[2])
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        // 回调只拷贝像素。PNG 编码放到停止采样之后，免得漏掉只出现一帧的闪烁。
        captured.append((Data(bytes: base, count: bytes * height), width, height, bytes))
        index += 1
    }
    func checkBackground() throws {
        let samples: [[Int]] = captured.map { data, _, _, bytes in
            let offset = Int((rect.minY + 150) * scale) * bytes + Int((rect.minX + 4) * scale) * 4
            return (0..<3).map { Int(data[offset + $0]) }
        }
        guard let first = samples.first else { fatalError("没有屏幕画面") }
        for (index, sample) in samples.enumerated() {
            guard zip(first, sample).allSatisfy({ abs($0.0 - $0.1) <= 4 }) else {
                fatalError("第 \(index) 帧侧栏底色改变或露出桌面：\(first) → \(sample)")
            }
        }
        print("PASS sidebar background", first)
    }
    func save() throws {
        for (i, item) in captured.enumerated() {
            let (data, width, height, bytes) = item
            let provider = CGDataProvider(data: data as CFData)!
            let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            try png.write(to: output.appendingPathComponent(String(format: "%05d.png", i)))
        }
    }
}
@main struct Main {
    @MainActor static func main() async throws {
        print("OS:", ProcessInfo.processInfo.operatingSystemVersionString, "AX:", AXIsProcessTrusted())
        guard AXIsProcessTrusted() else { fatalError("CI 未授予无障碍权限，不能把未点击侧栏算作通过") }
        let modes = CGDisplayCopyAllDisplayModes(CGMainDisplayID(), [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
        print("DISPLAY_MODES", modes.map { "\($0.width)x\($0.height):\($0.pixelWidth)x\($0.pixelHeight)" })
        if let retina = modes.first(where: { $0.width >= 1024 && $0.width <= 1280 && $0.pixelWidth >= $0.width * 2 }) {
            print("RETINA", CGDisplaySetDisplayMode(CGMainDisplayID(), retina, nil).rawValue)
            try await Task.sleep(for: .seconds(1))
        }
        print("BACKING_SCALE", NSScreen.main!.backingScaleFactor)
        let deadline = Date().addingTimeInterval(30)
        while NSRunningApplication.runningApplications(withBundleIdentifier: "com.whrss9527.proxyswitch.engine").isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let backdrop = CIImage(color: CIColor(red: 0.15, green: 0.65, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let cg = CIContext().createCGImage(backdrop, from: backdrop.extent)!
        let backdropURL = output.appendingPathComponent("wallpaper.png")
        try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: backdropURL)
        try NSWorkspace.shared.setDesktopImageURL(backdropURL, for: NSScreen.main!, options: [:])
        NSWorkspace.shared.open(URL(string: "proxi://settings?page=general")!)
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let readyDeadline = Date().addingTimeInterval(20)
        while !content.windows.contains(where: { $0.owningApplication?.bundleIdentifier == "com.whrss9527.proxyswitch" && $0.frame.width >= 760 }) {
            guard Date() < readyDeadline else { fatalError("主程序设置未显示") }
            try await Task.sleep(for: .seconds(1))
            NSWorkspace.shared.open(URL(string: "proxi://settings?page=general")!)
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        try await Task.sleep(for: .seconds(1))
        let display = content.displays[0]
        let configuration = SCStreamConfiguration()
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.width = display.width * Int(NSScreen.main!.backingScaleFactor)
        configuration.height = display.height * Int(NSScreen.main!.backingScaleFactor)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = false
        configuration.queueDepth = 8
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: nil)
        let frames = Frames()
        let window = content.windows.first { $0.owningApplication?.bundleIdentifier == "com.whrss9527.proxyswitch" && $0.frame.width >= 760 }!
        frames.rect = window.frame
        frames.scale = NSScreen.main!.backingScaleFactor
        print("WINDOW", window.frame)
        let queue = DispatchQueue(label: "screen-frames")
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let mainApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.whrss9527.proxyswitch").first!
        let mainRoot = AXUIElementCreateApplication(mainApp.processIdentifier)
        if let divider = splitter(mainRoot) {
            var point = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(attribute(divider, kAXPositionAttribute) as! AXValue, .cgPoint, &point)
            AXValueGetValue(attribute(divider, kAXSizeAttribute) as! AXValue, .cgSize, &size)
            point.y += size.height / 2
            print("DIVIDER_BEFORE", point, size)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
            for _ in 0..<12 {
                point.x -= 5
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(16))
            }
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
        } else { fatalError("找不到分栏拖动条") }
        try await Task.sleep(for: .milliseconds(300))
        let expectedDivider = dividerX(mainRoot)
        guard expectedDivider < frames.rect.minX + 230 else { fatalError("未实际改变侧栏宽度") }
        let mainID = "com.whrss9527.proxyswitch"
        let engineID = mainID + ".engine"
        for (appID, title, destinationID, page) in [
            (mainID, "Advanced", engineID, "advanced"),
            (engineID, "Extensions", mainID, "extensions"),
            (mainID, "Nodes & Subscriptions", engineID, "nodes"),
            (engineID, "Diagnose", mainID, "diagnostics"),
            (mainID, "Advanced", engineID, "advanced"),
            (engineID, "General", mainID, "general")
        ] {
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first!
            let root = AXUIElementCreateApplication(app.processIdentifier)
            guard let target = button(root, title: title) else { dumpTree(root); fatalError("找不到侧栏按钮：\(title)") }
            print("CLICK", title, CACurrentMediaTime())
            var origin = CGPoint.zero, size = CGSize.zero
            let positionValue = attribute(target, kAXPositionAttribute) as! AXValue
            let sizeValue = attribute(target, kAXSizeAttribute) as! AXValue
            AXValueGetValue(positionValue, .cgPoint, &origin)
            AXValueGetValue(sizeValue, .cgSize, &size)
            let point = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(80))
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
            let destination = NSRunningApplication.runningApplications(withBundleIdentifier: destinationID).first!
            let destinationRoot = AXUIElementCreateApplication(destination.processIdentifier)
            let deadline = Date().addingTimeInterval(4)
            while true {
                let shown = visibleSettingsOwners()
                if shown.contains(destination.processIdentifier) {
                    let identifiers = pageIdentifiers(destinationRoot)
                    guard identifiers == ["settings-page-" + page] else {
                        dumpTree(destinationRoot)
                        fatalError("目标窗口显现时露出了别的页面：\(identifiers)，预期 \(page)")
                    }
                    guard abs(dividerX(destinationRoot) - expectedDivider) <= 1 else {
                        fatalError("切页改变了侧栏宽度")
                    }
                    if !shown.contains(app.processIdentifier) { break }
                }
                guard Date() < deadline else { fatalError("切页没有完成：\(title)") }
                try await Task.sleep(for: .milliseconds(20))
            }
            print("PASS", title, "divider", dividerX(destinationRoot))
            try await Task.sleep(for: .milliseconds(300))
        }
        try await Task.sleep(for: .milliseconds(300))
        try await stream.stopCapture()
        queue.sync {}
        try frames.save()
        guard frames.index > 10 else { fatalError("屏幕采样不足") }
        try frames.checkBackground()
        print("frames:", frames.index)
    }
}
