import AppKit
import XCTest
@testable import Proxi

final class SettingsWindowHandoffTests: XCTestCase {
    @MainActor
    func testIncomingWindowStaysTransparentUntilBothWindowAndApplicationAreActive() {
        let window = makeWindow()
        let handoff = SettingsWindowHandoff(window: window)
        defer { handoff.cancel(); window.close() }
        let request = handoff.beginShowing()
        window.orderFront(nil)

        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertFalse(handoff.finishShowing(request, applicationIsActive: true, visibleOnScreen: { _ in true }))
        window.reportsKey = true
        XCTAssertFalse(handoff.finishShowing(request, applicationIsActive: false, visibleOnScreen: { _ in true }))
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(handoff.finishShowing(request, applicationIsActive: true, visibleOnScreen: { _ in true }))
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(handoff.finishShowing(request, applicationIsActive: true, visibleOnScreen: { _ in true }))
    }

    @MainActor
    func testStaleCallbackCannotRevealLaterRequestOrAClosedWindow() {
        let window = makeWindow()
        let handoff = SettingsWindowHandoff(window: window)
        defer { handoff.cancel(); window.close() }
        let old = handoff.beginShowing()
        let current = handoff.beginShowing()
        window.orderFront(nil)
        window.reportsKey = true

        XCTAssertFalse(handoff.finishShowing(old, applicationIsActive: true, visibleOnScreen: { _ in true }))
        XCTAssertEqual(window.alphaValue, 0)
        window.orderOut(nil)
        XCTAssertFalse(handoff.finishShowing(current, applicationIsActive: true, visibleOnScreen: { _ in true }))
        handoff.cancel()
        XCTAssertEqual(window.alphaValue, 1)
        window.orderFront(nil)
        XCTAssertFalse(handoff.finishShowing(current, applicationIsActive: true, visibleOnScreen: { _ in true }))
    }

    @MainActor
    func testLocalPageChangeDoesNotHideAnAlreadyVisibleWindow() {
        let window = makeWindow()
        let handoff = SettingsWindowHandoff(window: window)
        defer { handoff.cancel(); window.close() }
        window.orderFront(nil)
        window.reportsKey = true
        let request = handoff.beginShowing()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertTrue(handoff.finishShowing(request, applicationIsActive: true, visibleOnScreen: { _ in true }))
    }

    @MainActor
    func testOutgoingPixelsStayStableWhenNativeContentChangesOnFocusLoss() throws {
        let window = makeWindow()
        let content = FocusColorView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = content
        window.reportsKey = true
        window.orderFront(nil)
        let frame = try XCTUnwrap(content.superview)
        let originalCount = frame.subviews.count
        let handoff = SettingsWindowHandoff(window: window)
        defer { handoff.cancel(); window.close() }
        let before = try centerColor(frame)
        handoff.freeze()
        XCTAssertEqual(frame.subviews.count, originalCount + 1)
        XCTAssertNil(frame.subviews.last?.hitTest(NSPoint(x: 100, y: 100)))

        // 模拟原生视图因真实窗口失焦重画，冻结画面不能跟着变暗。
        window.reportsKey = false
        content.needsDisplay = true
        let frozen = try centerColor(frame)
        XCTAssertEqual(frozen.redComponent, before.redComponent, accuracy: 0.01)
        handoff.cancel()
        XCTAssertEqual(frame.subviews.count, originalCount)
        let after = try centerColor(frame)
        XCTAssertGreaterThan(before.redComponent - after.redComponent, 0.4)
        XCTAssertTrue(window.isVisible)
    }

    @MainActor
    func testRepeatedHandoffDoesNotStackCoversAndCancellationRestoresHiddenWindow() throws {
        let window = makeWindow()
        let handoff = SettingsWindowHandoff(window: window)
        defer { handoff.cancel(); window.close() }
        window.orderFront(nil)
        let frame = try XCTUnwrap(window.contentView?.superview)
        let originalCount = frame.subviews.count
        handoff.freeze()
        handoff.freeze()
        XCTAssertEqual(frame.subviews.count, originalCount + 1)
        window.orderOut(nil)
        handoff.beginShowing()
        XCTAssertEqual(frame.subviews.count, originalCount)
        window.orderFront(nil)
        handoff.cancel()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1)
    }

    @MainActor
    func testUnansweredHandoffRestoresBothWindowsAfterTimeout() async throws {
        let outgoing = makeWindow()
        let incoming = makeWindow()
        var sourceTimeouts = 0
        var destinationTimeouts = 0
        let source = SettingsWindowHandoff(window: outgoing) { sourceTimeouts += 1 }
        let destination = SettingsWindowHandoff(window: incoming) { destinationTimeouts += 1 }
        defer { source.cancel(); destination.cancel(); outgoing.close(); incoming.close() }
        outgoing.orderFront(nil)
        let frame = try XCTUnwrap(outgoing.contentView?.superview)
        let originalCount = frame.subviews.count
        source.freeze()
        let request = destination.beginShowing()
        incoming.orderFront(nil)
        try await Task.sleep(nanoseconds: 5_200_000_000)
        XCTAssertEqual(sourceTimeouts, 1)
        XCTAssertEqual(destinationTimeouts, 1)
        XCTAssertEqual(frame.subviews.count, originalCount)
        XCTAssertTrue(outgoing.isVisible)
        XCTAssertFalse(incoming.isVisible)
        XCTAssertEqual(incoming.alphaValue, 1)
        incoming.reportsKey = true
        incoming.orderFront(nil)
        XCTAssertFalse(destination.finishShowing(request, applicationIsActive: true, visibleOnScreen: { _ in true }))
    }

    @MainActor
    func testDoesNotAcknowledgeBeforeWindowServerHasPresentedTheWindow() {
        let window = makeWindow()
        let handoff = SettingsWindowHandoff(window: window)
        defer { handoff.cancel(); window.close() }
        let request = handoff.beginShowing()
        window.orderFront(nil)
        window.reportsKey = true
        XCTAssertFalse(handoff.finishShowing(request, applicationIsActive: true, visibleOnScreen: { _ in false }))
        // AppKit 已经记下 alpha=1，显示服务器仍未显现时不能让源窗口消失。
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertTrue(handoff.finishShowing(request, applicationIsActive: true, visibleOnScreen: { _ in true }))
    }

    @MainActor
    func testAcknowledgementMatchesActualWindowServerVisibility() async throws {
        let window = makeWindow()
        let handoff = SettingsWindowHandoff(window: window)
        defer { handoff.cancel(); window.close() }
        let request = handoff.beginShowing()
        window.orderFront(nil)
        window.reportsKey = true
        let deadline = Date().addingTimeInterval(2)
        var acknowledged = false
        repeat {
            acknowledged = handoff.finishShowing(request, applicationIsActive: true)
            if acknowledged { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        XCTAssertTrue(acknowledged)
        XCTAssertTrue(SettingsWindowHandoff.isVisibleOnScreen(window))
    }

    @MainActor
    private func makeWindow() -> FocusWindow {
        _ = NSApplication.shared
        let window = FocusWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                                 styleMask: [.titled, .closable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }

    @MainActor
    private func centerColor(_ view: NSView) throws -> NSColor {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    }
}

@MainActor
private final class FocusWindow: NSWindow {
    var reportsKey = false
    override var isKeyWindow: Bool { reportsKey }
}

@MainActor
private final class FocusColorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: window?.isKeyWindow == true ? 0.9 : 0.3, alpha: 1).setFill()
        bounds.fill()
    }
}
