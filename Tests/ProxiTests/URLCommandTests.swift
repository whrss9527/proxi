import XCTest
@testable import Proxi

final class URLCommandTests: XCTestCase {
    func testCommands() {
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://network-monitor")!), .networkMonitor)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://network-monitor?action=close")!), .closeNetworkMonitor)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://run?tool=test_profiles&profile=%E5%85%AC%E5%8F%B8")!), .tool(name: "test_profiles", params: ["profile": "公司"]))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://settings?page=automation")!), .settings(.automation))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://settings?page=general")!), .settings(.general))
        // 以前版本的页面已经没有了：打开设置的默认页。
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://settings?page=advanced")!), .settings(nil))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://use?name=%E5%85%AC%E5%8F%B8%E4%BB%A3%E7%90%86")!), .use("公司代理"))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://use/Charles")!), .use("Charles"))
    }

    /// 以前版本才有的命令不再认。
    func testRemovedCommands() {
        for text in ["proxi://gateway/off", "proxi://share/on", "proxi://mode?value=global", "proxi://import?url=https%3A%2F%2Fexample.com%2Fc.yaml", "proxi://diagnose?url=https://example.com"] {
            XCTAssertNil(URLCommand.parse(URL(string: text)!), text)
        }
    }
}
