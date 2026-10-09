import AppKit
import SwiftUI
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
    func testSwiftUIPageChangesWhileWindowIsTransparent() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let first = expectation(description: "初始页完成布局")
        let second = expectation(description: "目标页完成布局")
        let report: (UInt) -> Void = { revision in
            if revision == 1 { first.fulfill() }
            if revision == 2 { second.fulfill() }
        }
        let hosting = NSHostingView(rootView: PageFixture(revision: 1, report: report))
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFront(nil)
        await fulfillment(of: [first], timeout: 2)
        hosting.rootView = PageFixture(revision: 2, report: report)
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(window.alphaValue, 0)
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

private struct PageFixture: View {
    let revision: UInt
    let report: (UInt) -> Void
    var body: some View {
        Group {
            if revision == 1 { Text("初始页") }
            else { VStack { Text("目标页"); Toggle("选项", isOn: .constant(false)) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsPageReady(revision: revision, onReady: report))
    }
}
