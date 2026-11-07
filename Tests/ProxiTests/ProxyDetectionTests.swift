import XCTest
@testable import Proxi

final class ProxyDetectionTests: XCTestCase {
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    private actor Calls {
        private(set) var ports: [Int] = []
        private(set) var protocols: [String] = []
        func port(_ value: Int) { ports.append(value) }
        func check(port: Int, kind: String) { protocols.append("\(port):\(kind)") }
    }

    func testCancellationBeforeStartingDoesNotProbeAnyPort() async {
        let entry = Gate()
        let calls = Calls()
        let scan = Task {
            await entry.wait()
            return await LocalProxyDetector.detect(listeners: [], commonPorts: [1080, 8080], reachable: { port in
                await calls.port(port)
                return true
            }, test: { profile in
                await calls.check(port: profile.port, kind: profile.kind.rawValue)
                return TestResult(ok: true, latencyMs: 1, message: "fixture")
            })
        }
        scan.cancel()
        await entry.open()
        let found = await scan.value
        let ports = await calls.ports
        let checks = await calls.protocols
        XCTAssertTrue(found.isEmpty)
        XCTAssertTrue(ports.isEmpty)
        XCTAssertTrue(checks.isEmpty)
    }

    func testCancellationDuringPortProbeDoesNotStartTheNextPortOrProtocol() async {
        let gate = Gate()
        let calls = Calls()
        let started = expectation(description: "first port probe started")
        let scan = Task {
            await LocalProxyDetector.detect(listeners: [], commonPorts: [1080, 8080, 9090], reachable: { port in
                await calls.port(port)
                started.fulfill()
                await gate.wait()
                return true
            }, test: { profile in
                await calls.check(port: profile.port, kind: profile.kind.rawValue)
                return TestResult(ok: true, latencyMs: 1, message: "fixture")
            })
        }
        await fulfillment(of: [started], timeout: 2)
        scan.cancel()
        await gate.open()
        let found = await scan.value
        let ports = await calls.ports
        let checks = await calls.protocols
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(ports, [1080])
        XCTAssertTrue(checks.isEmpty)
    }

    func testCancellationDuringHTTPCheckDoesNotStartSOCKSCheck() async {
        let gate = Gate()
        let calls = Calls()
        let started = expectation(description: "HTTP check started")
        let scan = Task {
            await LocalProxyDetector.detect(listeners: [.init(port: 8888, process: "fixture")], commonPorts: [], reachable: { port in
                await calls.port(port)
                return true
            }, test: { profile in
                await calls.check(port: profile.port, kind: profile.kind.rawValue)
                started.fulfill()
                await gate.wait()
                return TestResult(ok: false, latencyMs: nil, message: "fixture")
            })
        }
        await fulfillment(of: [started], timeout: 2)
        scan.cancel()
        await gate.open()
        let found = await scan.value
        let checks = await calls.protocols
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(checks, ["8888:http"])
    }

    func testActiveScanKeepsListenersAndTriesSOCKSAfterHTTPFailure() async {
        let calls = Calls()
        let found = await LocalProxyDetector.detect(listeners: [.init(port: 8888, process: "fixture")], commonPorts: [8888, 1080], reachable: { port in
            await calls.port(port)
            return true
        }, test: { profile in
            await calls.check(port: profile.port, kind: profile.kind.rawValue)
            let ok = profile.port == 8888 ? profile.kind == .http : profile.kind == .socks5
            return TestResult(ok: ok, latencyMs: 1, message: "fixture")
        })
        let ports = await calls.ports
        let checks = await calls.protocols
        XCTAssertEqual(ports, [1080])
        XCTAssertEqual(found.map(\.port), [1080, 8888])
        XCTAssertEqual(found.map(\.kind), [.socks5, .http])
        XCTAssertEqual(found.map(\.process), ["", "fixture"])
        XCTAssertEqual(checks.filter { $0.hasPrefix("1080:") }, ["1080:http", "1080:socks5"])
    }
}
