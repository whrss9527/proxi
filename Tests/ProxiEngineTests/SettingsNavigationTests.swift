import XCTest
@testable import ProxiEngine

final class SettingsNavigationTests: XCTestCase {
    @MainActor
    func testCrossWindowSelectionDoesNotBounceBack() {
        let navigation = SettingsNavigation()
        let original = navigation.page
        let requested = SidebarItem.proxi(.diagnostics)
        navigation.select(requested)
        // 对方尚未显示时，选中项也必须保持用户刚点击的页；本地内容不变。
        XCTAssertEqual(navigation.sidebarItem, requested)
        XCTAssertEqual(navigation.page, original)
        navigation.didShow()
        XCTAssertEqual(navigation.sidebarItem, .engine(original))
    }

    @MainActor
    func testLocalSelectionCancelsPendingHandoff() {
        let navigation = SettingsNavigation()
        navigation.select(.proxi(.diagnostics))
        navigation.select(.engine(.core))
        XCTAssertEqual(navigation.page, .core)
        XCTAssertEqual(navigation.sidebarItem, .engine(.core))
        XCTAssertNil(navigation.requestedSidebarItem)
    }
}
