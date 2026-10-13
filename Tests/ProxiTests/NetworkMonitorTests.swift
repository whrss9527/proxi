import XCTest
import Network
@testable import Proxi

final class NetworkMonitorTests: XCTestCase {
    private func process(_ pid: Int32, received: UInt64, sent: UInt64 = 0, name: String = "Browser Helper") -> ProcessNetworkCounter {
        .init(pid: pid, name: name, received: received, sent: sent)
    }

    private func frame(_ uptime: Double, _ processes: [ProcessNetworkCounter], identities: [Int32: String] = [:], received: UInt32 = 0) -> NetworkMonitorFrame {
        NetworkMonitorFrame(uptime: uptime, date: Date(timeIntervalSince1970: uptime),
            interfaces: ["en0": .init(received: received, sent: 0)], processes: processes,
            facts: Dictionary(uniqueKeysWithValues: processes.map {
                ($0.pid, NetworkProcessFacts(identity: identities[$0.pid] ?? "\($0.pid):started", executablePaths: ["/Applications/Test Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Helper"]))
            }))
    }

    func testNettopParserWithoutTimeColumn() throws {
        let result = try NettopOutput.parse(",bytes_in,bytes_out,\nGoogle Chrome H.123,8192,1024,\ncom.example.agent.456,0,7,\n")
        XCTAssertEqual(result, [process(123, received: 8192, sent: 1024, name: "Google Chrome H"), process(456, received: 0, sent: 7, name: "com.example.agent")])
    }

    func testNettopParserUsesHeaderOrderAndQuotedNames() throws {
        let output = "time,,bytes_out,bytes_in,\n12:34:56,\"Browser, \"\"Helper\"\".321\",75,150,\n"
        XCTAssertEqual(try NettopOutput.parse(output), [process(321, received: 150, sent: 75, name: "Browser, \"Helper\"")])
    }

    func testNettopParserPreserves64BitCountersAndRejectsInvalidOutput() throws {
        let parsed = try NettopOutput.parse(",bytes_in,bytes_out,\nlarge.10,18446744073709551615,4294967297,\n")
        XCTAssertEqual(parsed.first?.received, UInt64.max)
        XCTAssertEqual(parsed.first?.sent, 4_294_967_297)
        XCTAssertThrowsError(try NettopOutput.parse("operation not permitted"))
        XCTAssertThrowsError(try NettopOutput.parse(",bytes_in,bytes_out,\nbroken.10,-1,2,\n"))
        XCTAssertEqual(try NettopOutput.parse(",bytes_in,bytes_out,\n"), [])
    }

    func testHelperAndMainProcessRatesAggregateToOuterApplication() throws {
        let previous = frame(10, [process(101, received: 1000, sent: 100), process(102, received: 2000, sent: 200)])
        let current = frame(12, [process(101, received: 2000, sent: 300), process(102, received: 6000, sent: 600)])
        let rate = try XCTUnwrap(NetworkTrafficMath.rates(from: previous, to: current).first)
        XCTAssertEqual(rate.name, "Test Browser")
        XCTAssertEqual(rate.bundlePath, "/Applications/Test Browser.app")
        XCTAssertEqual(rate.download, 2500)
        XCTAssertEqual(rate.upload, 300)
        XCTAssertEqual(rate.processes.count, 2)
    }

    func testPIDReuseNewProcessesAndCounterRollbackDoNotCreateSpikes() throws {
        let previous = frame(1, [process(101, received: 1000), process(102, received: 1000)])
        let current = frame(3, [process(101, received: 9_000_000), process(102, received: 2), process(103, received: 8_000_000)], identities: [101: "new process"])
        let rate = try XCTUnwrap(NetworkTrafficMath.rates(from: previous, to: current).first)
        XCTAssertEqual(rate.download, 0)
        XCTAssertEqual(rate.upload, 0)
    }

    func testExitedProcessesAreRemovedAndLongGapsResetBaseline() {
        let old = frame(1, [process(101, received: 1000)])
        XCTAssertEqual(NetworkTrafficMath.rates(from: old, to: frame(3, [])), [])
        XCTAssertEqual(NetworkTrafficMath.rates(from: old, to: frame(100, [process(101, received: 5_000_000)])), [])
        XCTAssertEqual(NetworkTrafficMath.rates(from: old, to: frame(0, [process(101, received: 5_000_000)])), [])
    }

    func testApplicationPathGroupingAndSearchIncludeProcessesAndPIDs() throws {
        XCTAssertNil(NetworkTrafficMath.applicationBundle(in: "/usr/bin/curl"))
        let rate = try XCTUnwrap(NetworkTrafficMath.rates(from: frame(1, [process(101, received: 0)]), to: frame(3, [process(101, received: 2)])).first)
        XCTAssertTrue(rate.matches("test browser"))
        XCTAssertTrue(rate.matches("HELPER"))
        XCTAssertTrue(rate.matches("101"))
        XCTAssertFalse(rate.matches("unrelated"))
    }

    func testLargeRatesCanBeFormattedWithoutIntegerOverflow() {
        XCTAssertEqual(NetworkTrafficMath.displayBytes(Double(UInt64.max)), Int.max)
        XCTAssertEqual(NetworkTrafficMath.displayBytes(.nan), 0)
        XCTAssertEqual(NetworkTrafficMath.displayBytes(-1), 0)
    }

    actor Feed {
        var frames: [NetworkMonitorFrame]
        var calls = 0
        init(_ frames: [NetworkMonitorFrame]) { self.frames = frames }
        func next() throws -> NetworkMonitorFrame {
            calls += 1
            guard !frames.isEmpty else { throw NetworkMonitorError.invalidOutput }
            return frames.removeFirst()
        }
        func count() -> Int { calls }
        func append(_ frames: [NetworkMonitorFrame]) { self.frames += frames }
    }

    actor Gate {
        var waiting: [CheckedContinuation<NetworkMonitorFrame, Never>] = []
        func next() async -> NetworkMonitorFrame { await withCheckedContinuation { waiting.append($0) } }
        func count() -> Int { waiting.count }
        func complete(_ frame: NetworkMonitorFrame) { waiting.removeFirst().resume(returning: frame) }
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待监控状态超时")
    }

    @MainActor
    func testMonitorDoesNotSampleUntilOpenedAndComputesDeviceSpeedSeparately() async throws {
        let feed = Feed([frame(1, [process(101, received: 100)], received: 1000), frame(3, [process(101, received: 20100)], received: 3000)])
        let monitor = AppNetworkMonitor(interval: .milliseconds(100), fetch: { try await feed.next() })
        XCTAssertFalse(monitor.isRunning)
        let initial = await feed.count(); XCTAssertEqual(initial, 0)
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil { monitor.hasSample }
        XCTAssertEqual(monitor.download, 1000)
        XCTAssertEqual(monitor.applications.first?.download, 10_000)
        monitor.stop(clearSamples: true)
        XCTAssertTrue(monitor.applications.isEmpty)
        XCTAssertFalse(monitor.hasSample)
        XCTAssertNil(monitor.updatedAt)
        XCTAssertEqual(monitor.download, 0)
    }

    @MainActor
    func testPauseFreezesViewAndResumeStartsFreshBaseline() async throws {
        let feed = Feed([frame(1, [process(101, received: 100)]), frame(3, [process(101, received: 300)])])
        let monitor = AppNetworkMonitor(interval: .milliseconds(100), fetch: { try await feed.next() })
        monitor.start(); defer { monitor.stop() }
        try await waitUntil { monitor.hasSample }
        monitor.togglePause()
        let frozen = monitor.applications
        let count = await feed.count()
        try await Task.sleep(for: .milliseconds(130))
        let pausedCount = await feed.count(); XCTAssertEqual(pausedCount, count)
        XCTAssertEqual(monitor.applications, frozen)
        await feed.append([frame(30, [process(101, received: 90_000)]), frame(32, [process(101, received: 90_200)])])
        monitor.togglePause()
        XCTAssertFalse(monitor.hasSample)
        try await waitUntil { monitor.hasSample }
        XCTAssertEqual(monitor.applications.first?.download, 100)
    }

    @MainActor
    func testCancelledSampleCannotPublishIntoReopenedWindow() async throws {
        let gate = Gate()
        let monitor = AppNetworkMonitor(interval: .seconds(60), fetch: { await gate.next() })
        monitor.start(); defer { monitor.stop() }
        try await waitUntil { await gate.count() == 1 }
        monitor.stop(); monitor.start()
        try await waitUntil { await gate.count() == 2 }
        await gate.complete(frame(1, [process(101, received: 100)]))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(monitor.updatedAt)
        await gate.complete(frame(10, [process(101, received: 1000)]))
        try await waitUntil { monitor.updatedAt != nil }
        XCTAssertEqual(monitor.updatedAt, Date(timeIntervalSince1970: 10))
        XCTAssertFalse(monitor.hasSample)
    }

    @MainActor
    func testFailureDiscardsStaleRatesAndStoppingCancelsRetry() async throws {
        let feed = Feed([frame(1, [process(101, received: 100)]), frame(3, [process(101, received: 300)])])
        let monitor = AppNetworkMonitor(interval: .milliseconds(100), fetch: { try await feed.next() })
        monitor.start()
        try await waitUntil { monitor.error != nil }
        XCTAssertTrue(monitor.applications.isEmpty)
        XCTAssertFalse(monitor.hasSample)
        monitor.stop()
        let before = await feed.count()
        try await Task.sleep(for: .milliseconds(130))
        let after = await feed.count(); XCTAssertEqual(after, before)
    }

    /// 真实工具检查覆盖参数和系统 CSV 契约，不依赖测试机器正在下载文件。
    func testNativeNettopOutputCanBeReadWithoutAdministratorAuthorization() async throws {
        let sample = try await ProcessNetworkSampler.read()
        XCTAssertTrue(sample.uptime > 0)
        XCTAssertEqual(Set(sample.processes.map(\.pid)).count, sample.processes.count)
    }

    final class ConnectionHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: NWConnection?
        func keep(_ connection: NWConnection) { lock.lock(); self.connection = connection; lock.unlock() }
        func close() { lock.lock(); defer { lock.unlock() }; connection?.cancel() }
    }

    /// 保持 TCP 连接存活，验证两次真实 nettop 读数能观测到本进程的流量增长。
    func testNativeNettopCountersObserveLocalTCPTransfer() async throws {
        let queue = DispatchQueue(label: "ProxiTests.network-monitor")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let holder = ConnectionHolder()
        let ready = expectation(description: "本机监听就绪")
        let connected = expectation(description: "客户端连接就绪")
        let received = expectation(description: "收到测试流量")
        let sent = expectation(description: "发出测试流量")
        let size = 1024 * 1024
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            holder.keep(connection)
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: size, maximumLength: size) { data, _, _, error in
                XCTAssertNil(error)
                XCTAssertEqual(data?.count, size)
                received.fulfill()
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel(); holder.close() }
        await fulfillment(of: [ready], timeout: 5)
        let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: .tcp)
        client.stateUpdateHandler = { if case .ready = $0 { connected.fulfill() } }
        client.start(queue: queue)
        defer { client.cancel() }
        await fulfillment(of: [connected], timeout: 5)
        let pid = ProcessInfo.processInfo.processIdentifier
        let beforeSample = try await ProcessNetworkSampler.read()
        let before = try XCTUnwrap(beforeSample.processes.first { $0.pid == pid })
        client.send(content: Data(repeating: 1, count: size), completion: .contentProcessed { error in
            XCTAssertNil(error)
            sent.fulfill()
        })
        await fulfillment(of: [sent, received], timeout: 5)
        let afterSample = try await ProcessNetworkSampler.read()
        let after = try XCTUnwrap(afterSample.processes.first { $0.pid == pid })
        XCTAssertTrue(after.received > before.received || after.sent > before.sent, "真实进程网络计数没有增长")
    }
}
