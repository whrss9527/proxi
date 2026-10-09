import AppKit
import XCTest
@testable import Proxi

final class SettingsPageReadyTests: XCTestCase {
    @MainActor
    func testHiddenWindowReportsOnlyAfterPageLayoutCompletes() async {
        let (window, page) = makePage()
        defer { window.close() }
        window.alphaValue = 0
        var revisions: [UInt] = []
        page.configure(revision: 1) { revisions.append($0) }
        XCTAssertTrue(revisions.isEmpty)
        page.layoutSubtreeIfNeeded()
        XCTAssertTrue(revisions.isEmpty, "布局栈尚未结束时不能显示窗口")
        await drainCallbacks()
        XCTAssertEqual(revisions, [1], "透明窗口也必须能完成布局确认")
        page.needsLayout = true
        page.layoutSubtreeIfNeeded()
        await drainCallbacks()
        XCTAssertEqual(revisions, [1])
    }

    @MainActor
    func testNewPageDiscardsPendingPreviousPageCallback() async {
        let (window, page) = makePage()
        defer { window.close() }
        var revisions: [UInt] = []
        page.configure(revision: 1) { revisions.append($0) }
        page.layoutSubtreeIfNeeded()
        page.configure(revision: 2) { revisions.append($0) }
        page.layoutSubtreeIfNeeded()
        await drainCallbacks()
        XCTAssertEqual(revisions, [2])
    }

    @MainActor
    func testDetachedPageCannotCompleteHandoff() async {
        let (window, page) = makePage()
        defer { window.close() }
        var revisions: [UInt] = []
        page.configure(revision: 1) { revisions.append($0) }
        page.layoutSubtreeIfNeeded()
        page.removeFromSuperview()
        await drainCallbacks()
        XCTAssertTrue(revisions.isEmpty)
        window.contentView?.addSubview(page)
        page.layoutSubtreeIfNeeded()
        await drainCallbacks()
        XCTAssertEqual(revisions, [1])
    }

    @MainActor
    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private func makePage() -> (NSWindow, SettingsPageReadyView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = SettingsPageReadyView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(page)
        return (window, page)
    }
}
