import XCTest
@testable import Proxi

final class SettingsNavigationTests: XCTestCase {
    @MainActor
    func testCrossWindowSelectionDoesNotBounceBack() {
        let navigation = SettingsNavigation()
        let original = navigation.page
        let requested = SidebarItem.engine(.rules)
        navigation.select(requested)
        // 对方尚未显示时，选中项也必须保持用户刚点击的页；本地内容不变。
        XCTAssertEqual(navigation.sidebarItem, requested)
        XCTAssertEqual(navigation.page, original)
        navigation.didShow()
        XCTAssertEqual(navigation.sidebarItem, .proxi(original))
    }

    @MainActor
    func testLocalSelectionCancelsPendingHandoff() {
        let navigation = SettingsNavigation()
        navigation.select(.engine(.rules))
        navigation.select(.proxi(.about))
        XCTAssertEqual(navigation.page, .about)
        XCTAssertEqual(navigation.sidebarItem, .proxi(.about))
        XCTAssertNil(navigation.requestedSidebarItem)
    }
}
