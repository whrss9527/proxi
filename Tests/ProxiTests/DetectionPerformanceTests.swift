import XCTest
@testable import Proxi

final class DetectionPerformanceTests: XCTestCase {
    func testOldAndNewNetstatColumnsAndDuplicateFamilies() {
        let old = """
        Proto Recv-Q Send-Q Local Address Foreign Address (state) rhiwat shiwat pid epid state options
        tcp4 0 0 *.8888 *.* LISTEN 131072 131072 512 0 0x0 0x6
        tcp6 0 0 ::1.8888 *.* LISTEN 131072 131072 512 0 0x0 0x6
        tcp4 0 0 127.0.0.1.9000 127.0.0.1.1234 ESTABLISHED 1 1 42 0 0x0 0x6
        tcp4 0 0 *.0 *.* LISTEN 1 1 512 0 0x0 0x6
        """
        XCTAssertEqual(LocalProxyDetector.parseNetstat(old, processName: { "process-\($0)" }), [.init(port: 8888, process: "process-512")])
        let modern = """
        Proto Recv-Q Send-Q Local Address Foreign Address (state) rxbytes txbytes rhiwat shiwat process:pid state options gencnt
        tcp46 0 0 *.9090 *.* LISTEN 0 0 131072 131072 Python:123 0x0 0x6 1
        tcp6 0 0 fe80::1%lo0.3000 *.* LISTEN 0 0 131072 131072 node:0 0x0 0x6 1
        tcp4 0 0 *.70000 *.* LISTEN 0 0 131072 131072 bad:1 0x0 0x6 1
        tcp4 malformed
        """
        XCTAssertEqual(LocalProxyDetector.parseNetstat(modern, processName: { "process-\($0)" }), [.init(port: 9090, process: "process-123"), .init(port: 3000, process: "")])
        XCTAssertTrue(LocalProxyDetector.parseNetstat("permission denied").isEmpty)
    }

    func testFallbackPortsAndProtocolsRunConcurrentlyAndPreferHTTP() async {
        let started = ProcessInfo.processInfo.systemUptime
        let results = await LocalProxyDetector.detect(testURL: "http://example.invalid", listeners: {
            [.init(port: 8888, process: "fixture")]
        }, reachable: { port, timeout in
            XCTAssertLessThanOrEqual(timeout, 0.2)
            try? await Task.sleep(nanoseconds: 100_000_000)
            return port == 1080
        }, probe: { profile, _, timeout in
            XCTAssertLessThanOrEqual(timeout, 2)
            try? await Task.sleep(nanoseconds: 100_000_000)
            return .init(ok: profile.port == 8888 || profile.kind == .socks5, latencyMs: 100, message: "")
        })
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.8)
        XCTAssertEqual(results.map(\.port), [1080, 8888])
        XCTAssertEqual(results.map(\.kind), [.socks5, .http])
        XCTAssertEqual(results.map(\.process), ["", "fixture"])
    }

    func testSlowListenerQuerySkipsProbesAfterDeadline() async {
        let results = await LocalProxyDetector.detect(testURL: "http://example.invalid", listeners: {
            try? await Task.sleep(nanoseconds: 2_750_000_000)
            return [.init(port: 8888, process: "fixture")]
        }, reachable: { _, _ in XCTFail("截止后不补查"); return false },
        probe: { _, _, _ in XCTFail("截止后不探测"); return .init(ok: false, latencyMs: nil, message: "") })
        XCTAssertTrue(results.isEmpty)
    }

    func testCIDetectionFindsFixtureUnderThreeSeconds() async throws {
        guard let port = ProcessInfo.processInfo.environment["PROXI_DETECTION_FIXTURE_PORT"].flatMap(Int.init) else {
            throw XCTSkip("真实端口检测仅在独立 CI fixture 中运行")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let results = await LocalProxyDetector.detect(testURL: "http://proxy-fixture.example.invalid/health")
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print(String(format: "PROXI_DETECTION elapsed=%.3f seconds", elapsed))
        XCTAssertLessThan(elapsed, 3)
        XCTAssertEqual(results.first(where: { $0.port == port })?.kind, .http)
    }
}
