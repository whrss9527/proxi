import Darwin
import Foundation
import XCTest
import os
@testable import ProxiEngine

final class CoreLifecycleTests: XCTestCase {
    private struct Fixture: Sendable {
        let directory: URL
        let executable: URL
        let config: URL
        var ready: URL { URL(fileURLWithPath: config.path + ".ready") }
        var terminated: URL { URL(fileURLWithPath: config.path + ".term") }
        func configure(port: Int = 0, exit: Bool = false, logs: Bool = false) throws {
            try JSONSerialization.data(withJSONObject: ["port": port, "exit": exit, "logs": logs]).write(to: config, options: .atomic)
        }
    }

    private struct Ready: Decodable {
        let pid: Int32
        let port: Int
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("core lifecycle \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fixture")
        let script = """
        #!/usr/bin/python3
        import json, os, signal, socket, sys, time
        path = sys.argv[-1]
        options = json.load(open(path))
        listener = socket.socket()
        listener.bind(('127.0.0.1', options['port']))
        listener.listen(1)
        def terminated(*args):
            open(path + '.term', 'w').close()
        signal.signal(signal.SIGTERM, terminated)
        temporary = path + '.ready.tmp'
        with open(temporary, 'w') as output:
            json.dump({'pid':os.getpid(), 'port':listener.getsockname()[1]}, output)
        os.replace(temporary, path + '.ready')
        if options['exit']:
            sys.exit(7)
        while True:
            if options['logs']:
                print('fixture output ' * 512, flush=True)
            time.sleep(0.001 if options['logs'] else 1)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let fixture = Fixture(directory: directory, executable: executable, config: directory.appendingPathComponent("config.json"))
        try fixture.configure()
        return fixture
    }

    private func ready(_ fixture: Fixture, pid: Int32?) async throws -> Ready {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: fixture.ready), let ready = try? JSONDecoder().decode(Ready.self, from: data), ready.pid == pid { return ready }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "CoreLifecycleTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture did not become ready"])
    }

    private func cleanup(_ fixture: Fixture, runner: CoreRunner) {
        if let pid = runner.pid { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    @MainActor
    func testIgnoringTERMEscalatesWithoutBlockingMainActor() async throws {
        let fixture = try fixture()
        let runner = CoreRunner(grace: 0.2, killGrace: 1)
        defer { cleanup(fixture, runner: runner) }
        try await runner.start(executable: fixture.executable, directory: fixture.directory, config: fixture.config)
        let child = try await ready(fixture, pid: runner.pid)
        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { heartbeat.cancel() }
        let start = ContinuousClock.now
        try await runner.stop()
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertGreaterThan(ticks, 3)
        XCTAssertFalse(runner.isRunning)
        XCTAssertNil(CoreProcessIdentity.read(child.pid))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.terminated.path))
    }

    @MainActor
    func testRestartWaitsForPortReleaseAndSuppressesIntentionalExit() async throws {
        let fixture = try fixture()
        let runner = CoreRunner(grace: 0.1, killGrace: 1)
        defer { cleanup(fixture, runner: runner) }
        var exits = 0
        runner.onExit = { _ in exits += 1 }
        try await runner.start(executable: fixture.executable, directory: fixture.directory, config: fixture.config)
        let first = try await ready(fixture, pid: runner.pid)
        try fixture.configure(port: first.port)
        try await runner.start(executable: fixture.executable, directory: fixture.directory, config: fixture.config)
        let second = try await ready(fixture, pid: runner.pid)
        XCTAssertNotEqual(second.pid, first.pid)
        XCTAssertEqual(second.port, first.port)
        XCTAssertNil(CoreProcessIdentity.read(first.pid))
        try await runner.stop()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(exits, 0)
    }

    @MainActor
    func testConcurrentStartStopRequestsLeaveNoOwnedProcess() async throws {
        let fixture = try fixture()
        let runner = CoreRunner(grace: 0.05, killGrace: 1)
        defer { cleanup(fixture, runner: runner) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        try await runner.start(executable: fixture.executable, directory: fixture.directory, config: fixture.config)
                    } else {
                        try await runner.stop()
                    }
                }
            }
            try await group.waitForAll()
        }
        try await runner.stop()
        XCTAssertFalse(runner.isRunning)
        XCTAssertNil(runner.pid)
    }

    @MainActor
    func testStoppingDuringContinuousOutputClosesPipeAndAllowsRestart() async throws {
        let fixture = try fixture()
        try fixture.configure(logs: true)
        let runner = CoreRunner(grace: 0.1, killGrace: 1)
        defer { cleanup(fixture, runner: runner) }
        try await runner.start(executable: fixture.executable, directory: fixture.directory, config: fixture.config)
        _ = try await ready(fixture, pid: runner.pid)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !runner.logTail.contains("fixture output"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(runner.logTail.contains("fixture output"))
        try await runner.stop()
        try fixture.configure()
        try await runner.start(executable: fixture.executable, directory: fixture.directory, config: fixture.config)
        _ = try await ready(fixture, pid: runner.pid)
        try await runner.stop()
        XCTAssertNil(runner.pid)
    }

    @MainActor
    func testRemovalFinishesBeforeQueuedReconcileCanCheckExecutable() async throws {
        let fixture = try fixture()
        let runner = CoreRunner(grace: 0.2, killGrace: 1)
        defer { cleanup(fixture, runner: runner) }
        try await runner.start(executable: fixture.executable, directory: fixture.directory, config: fixture.config)
        let child = try await ready(fixture, pid: runner.pid)
        let engine = Engine(runner: runner)
        var config = AppConfig()
        config.engine.subscriptions = [Subscription(name: "fixture", url: "https://example.com/config")]
        engine.readConfig = { config }
        var observedExecutable: [Bool] = []
        engine.coreReady = {
            observedExecutable.append(FileManager.default.fileExists(atPath: fixture.executable.path))
            return false
        }
        let removal = Task { @MainActor in
            await engine.stopCore {
                XCTAssertNil(CoreProcessIdentity.read(child.pid))
                do { try FileManager.default.removeItem(at: fixture.executable) }
                catch { XCTFail("removal failed: \(error)") }
            }
        }
        // TERM 标记保证停止已开始，此时排入另一次配置更新。
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: fixture.terminated.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.terminated.path))
        await engine.reconcile()
        let removed = await removal.value
        XCTAssertTrue(removed)
        XCTAssertEqual(observedExecutable, [false])
        XCTAssertNil(runner.pid)
    }

    @MainActor
    func testChangedProcessIdentityRefusesSignalsAndReplacement() async throws {
        let fixture = try fixture()
        let changed = OSAllocatedUnfairLock(initialState: false)
        let runner = CoreRunner(grace: 0.1, readIdentity: { pid in
            guard let actual = CoreProcessIdentity.read(pid) else { return nil }
            return changed.withLock { $0 } ? CoreProcessIdentity(pid: pid, uid: actual.uid, seconds: actual.seconds + 1, microseconds: actual.microseconds) : actual
        })
        defer { cleanup(fixture, runner: runner) }
        try await runner.start(executable: fixture.executable, directory: fixture.directory, config: fixture.config)
        let child = try await ready(fixture, pid: runner.pid)
        changed.withLock { $0 = true }
        do {
            try await runner.start(executable: fixture.executable, directory: fixture.directory, config: fixture.config)
            XCTFail("changed identity must not be signalled or replaced")
        } catch {}
        XCTAssertEqual(runner.pid, child.pid)
        XCTAssertNotNil(CoreProcessIdentity.read(child.pid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.terminated.path))
        changed.withLock { $0 = false }
        try await runner.stop()
    }

    @MainActor
    func testNaturalExitIsDeliveredOnce() async throws {
        let fixture = try fixture()
        try fixture.configure(exit: true)
        let runner = CoreRunner()
        defer { cleanup(fixture, runner: runner) }
        var statuses: [Int32] = []
        runner.onExit = { statuses.append($0) }
        try await runner.start(executable: fixture.executable, directory: fixture.directory, config: fixture.config)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while statuses.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(statuses, [7])
        XCTAssertFalse(runner.isRunning)
        try await runner.stop()
        XCTAssertEqual(statuses, [7])
    }

    @MainActor
    func testStrayCleanupMatchesExecutableAndArgumentBoundaries() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = fixture.directory.appendingPathComponent("fixture.c")
        try """
        #include <signal.h>
        #include <stdio.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            signal(SIGTERM, SIG_IGN);
            char path[4096];
            snprintf(path, sizeof(path), "%s.ready", argv[argc-1]);
            FILE *f = fopen(path, "w");
            if (!f) return 2;
            fprintf(f, "%d", getpid()); fclose(f);
            for (;;) pause();
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let executable = fixture.directory.appendingPathComponent("mihomo")
        let built = try await Shell.run("/usr/bin/clang", [source.path, "-o", executable.path], timeout: 20)
        XCTAssertTrue(built.succeeded, built.output)
        var processes: [Process] = []
        defer { for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let other = fixture.directory.appendingPathComponent("another.json")
        for arguments in [["--note", fixture.config.path], ["-f", other.path], ["-f", fixture.config.path]] {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            processes.append(process)
            let ready = URL(fileURLWithPath: arguments.last! + ".ready")
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while (try? String(contentsOf: ready)) != String(process.processIdentifier), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(try String(contentsOf: ready), String(process.processIdentifier))
        }
        XCTAssertFalse(CoreProcessIdentity.isCore(processes[0].processIdentifier, configs: [fixture.config]))
        XCTAssertFalse(CoreProcessIdentity.isCore(processes[1].processIdentifier, configs: [fixture.config]))
        XCTAssertTrue(CoreProcessIdentity.isCore(processes[2].processIdentifier, configs: [fixture.config]))
        try await CoreRunner.killStrays(configs: [fixture.config])
        XCTAssertTrue(processes[0].isRunning)
        XCTAssertTrue(processes[1].isRunning)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while processes[2].isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(processes[2].isRunning)
    }
}
