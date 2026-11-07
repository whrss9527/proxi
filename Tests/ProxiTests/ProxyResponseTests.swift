import Foundation
import XCTest
@testable import Proxi

final class ProxyResponseTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let process: Process
        let port: Int

        func stop() async {
            if process.isRunning { process.terminate() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(process.isRunning, "The loopback fixture did not stop before its deadline")
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-response-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server.py")
        try """
        import http.server, pathlib, select, sys, time
        root = pathlib.Path(sys.argv[1])
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.endswith('/redirect'):
                    self.send_response(302)
                    self.send_header('Location', '/success')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                status = 503 if self.path.endswith('/failure') else 200
                self.send_response(status)
                self.send_header('Content-Length', str(64 * 1024 * 1024))
                self.end_headers()
                self.wfile.write(b'x' * (64 * 1024))
                self.wfile.flush()
                (root / 'headers').write_text(str(status))
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    readable, _, _ = select.select([self.connection], [], [], 0.05)
                    if readable and not self.connection.recv(1):
                        (root / 'closed').write_text('closed')
                        return
            def log_message(self, *args): pass
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        (root / 'port').write_text(str(server.server_address[1]))
        server.serve_forever()
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, directory.path]
        try process.run()
        let portFile = directory.appendingPathComponent("port")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: portFile), let port = Int(text) {
                return Fixture(directory: directory, process: process, port: port)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await Fixture(directory: directory, process: process, port: 0).stop()
        throw URLError(.timedOut)
    }

    private func result(_ path: String) async throws -> (TestResult, Fixture) {
        let server = try await fixture()
        let profile = Profile(name: "fixture", color: "", kind: .http, host: "127.0.0.1", port: server.port)
        let result = await ProxyTester.test(profile: profile, testURL: "http://127.0.0.1:\(server.port)/\(path)", timeout: 1)
        return (result, server)
    }

    func testSuccessUsesResponseBeforeTheBodyCompletesAndClosesConnection() async throws {
        let (result, server) = try await result("success")
        addTeardownBlock { await server.stop() }
        XCTAssertTrue(result.ok, result.message)
        XCTAssertNotNil(result.latencyMs, result.message)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: server.directory.appendingPathComponent("closed").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.directory.appendingPathComponent("closed").path))
    }

    func testHTTPFailureUsesItsStatusWithoutWaitingForTheBody() async throws {
        let (result, server) = try await result("failure")
        addTeardownBlock { await server.stop() }
        XCTAssertFalse(result.ok)
        XCTAssertNotNil(result.latencyMs, result.message)
        XCTAssertTrue(result.message.contains("503"), result.message)
    }

    func testRedirectStillFollowsTheGETRequest() async throws {
        let (result, server) = try await result("redirect")
        addTeardownBlock { await server.stop() }
        XCTAssertTrue(result.ok, result.message)
        XCTAssertNotNil(result.latencyMs, result.message)
    }
}
