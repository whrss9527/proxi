import AppKit
import XCTest
@testable import Proxi

final class StatusImageCacheTests: XCTestCase {
    func testCompactBucketReusesImageAndEveryVisibleChangeInvalidates() {
        // 替身计数代替 NSImage，不创建窗口或状态栏。
        var cache = StatusImageCache<Int>()
        var builds = 0
        func key(_ raw: Int) -> StatusImageKey {
            .init(state: .on(.systemGreen), upload: SpeedFormatter.compact(bytesPerSecond: raw), download: "0.00B", layout: .speedLeft, textColor: NSColor.black.cgColor, appearance: "aqua")
        }
        func render(_ key: StatusImageKey) -> Int { cache.image(for: key) { builds += 1; return builds } }
        var visible = key(1_258_291)
        XCTAssertEqual(render(visible), 1)
        XCTAssertEqual(render(key(1_258_292)), 1)
        visible.upload = "1.21M"; XCTAssertEqual(render(visible), 2)
        visible.download = "1.00K"; XCTAssertEqual(render(visible), 3)
        visible.state = .warning(.systemGreen); XCTAssertEqual(render(visible), 4)
        visible.state = .on(.systemBlue); XCTAssertEqual(render(visible), 5)
        visible.textColor = NSColor.white.cgColor; XCTAssertEqual(render(visible), 6)
        visible.appearance = "darkAqua"; XCTAssertEqual(render(visible), 7)
        visible.layout = .speedRight; XCTAssertEqual(render(visible), 8)
        visible.upload = nil; visible.download = nil; XCTAssertEqual(render(visible), 9)
        XCTAssertEqual(render(visible), 9)
    }
}
