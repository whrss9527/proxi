import AppKit
import QuartzCore
import ScreenCaptureKit

@main struct LayerProbe {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 240), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        content.wantsLayer = true
        content.layer!.backgroundColor = NSColor.red.cgColor
        window.contentView = content
        window.orderFrontRegardless()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(200))
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let target = shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) }!
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = 320
        configuration.height = 240
        func color() async throws -> NSColor {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: image)
            return bitmap.colorAt(x: image.width / 2, y: image.height / 2)!.usingColorSpace(.deviceRGB)!
        }
        let before = try await color()
        let handoff = SettingsWindowHandoff(window: window)
        handoff.freeze()
        print("LAYERS", content.superview!.wantsLayer, content.superview!.layer != nil, content.superview!.subviews.last!.wantsLayer, content.superview!.subviews.last!.layer != nil)
        content.layer!.backgroundColor = NSColor.blue.cgColor
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(200))
        let frozen = try await color()
        handoff.cancel()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(200))
        let after = try await color()
        print("LAYER_COLORS", before, frozen, after)
        window.close()
        guard before.redComponent > 0.9, frozen.redComponent > 0.9, after.blueComponent > 0.9 else {
            fatalError("屏幕合成后的覆盖图没有保留图层内容")
        }
    }
}
