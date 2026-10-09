import AppKit
import XCTest
@testable import Proxi

final class SettingsWindowLayoutTests: XCTestCase {
    @MainActor
    func testHandoffPreservesDividerAndScrollPosition() throws {
        let source = makeWindow(sidebar: 205, documentHeight: 1200)
        let destination = makeWindow(sidebar: 260, documentHeight: 1200)
        defer { source.0.close(); destination.0.close() }
        source.2.contentView.scroll(to: NSPoint(x: 0, y: 135))
        let layout = try XCTUnwrap(SettingsWindowLayout.capture(from: source.0))
        let transported = try XCTUnwrap(SettingsWindowLayout.decode(layout.notificationInfo))
        transported.apply(to: destination.0)
        XCTAssertEqual(destination.1.arrangedSubviews[0].frame.width, source.1.arrangedSubviews[0].frame.width, accuracy: 0.5)
        XCTAssertEqual(destination.2.contentView.bounds.origin.y, source.2.contentView.bounds.origin.y, accuracy: 0.5)
    }

    @MainActor
    func testShorterSidebarClampsScrollOffset() {
        let destination = makeWindow(sidebar: 260, documentHeight: 500)
        defer { destination.0.close() }
        SettingsWindowLayout(sidebarWidth: 205, scrollY: 900).apply(to: destination.0)
        let maximum = max(0, destination.2.documentView!.bounds.height - destination.2.contentView.bounds.height)
        XCTAssertEqual(destination.2.contentView.bounds.origin.y, maximum, accuracy: 0.5)
    }

    @MainActor
    func testInvalidWidthDoesNotMoveDivider() {
        let destination = makeWindow(sidebar: 260, documentHeight: 1200)
        defer { destination.0.close() }
        let before = destination.1.arrangedSubviews[0].frame.width
        for width in [CGFloat.nan, .infinity, -1, 10000] {
            SettingsWindowLayout(sidebarWidth: width, scrollY: 0).apply(to: destination.0)
            XCTAssertEqual(destination.1.arrangedSubviews[0].frame.width, before)
        }
        XCTAssertNil(SettingsWindowLayout.decode(["sidebarLayout": Data("invalid".utf8)]))
        XCTAssertNil(SettingsWindowLayout.decode(nil))
    }

    @MainActor
    private func makeWindow(sidebar: CGFloat, documentHeight: CGFloat) -> (NSWindow, NSSplitView, NSScrollView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        split.isVertical = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: sidebar, height: 500))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: sidebar, height: documentHeight))
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(NSView(frame: NSRect(x: sidebar + 1, y: 0, width: 899 - sidebar, height: 500)))
        window.contentView = split
        split.setPosition(sidebar, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, split, scroll)
    }
}
