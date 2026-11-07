import Darwin
import Foundation
import XCTest
@testable import ProxiEngine

final class HelperLogTailTests: XCTestCase {
    private func fixture(_ data: Data = Data()) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helper-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("core.log")
        try data.write(to: file)
        return file
    }

    private func previousTail(_ data: Data) -> String {
        String(decoding: data.suffix(64 * 1024), as: UTF8.self)
            .split(separator: "\n").suffix(200).joined(separator: "\n")
    }

    func testMissingEmptyAndDirectoryReturnEmpty() throws {
        let file = try fixture()
        XCTAssertEqual(HelperLogTail.read(path: file.path), "")
        XCTAssertEqual(HelperLogTail.read(path: file.deletingLastPathComponent().path), "")
        XCTAssertEqual(HelperLogTail.read(path: file.appendingPathExtension("missing").path), "")
    }

    func testBlankLinesAndRecentLineLimitKeepExistingOutput() throws {
        let data = Data(("\n\n" + (1...250).map { "line \($0)\n\n" }.joined()).utf8)
        let file = try fixture(data)
        XCTAssertEqual(HelperLogTail.read(path: file.path), previousTail(data))
        XCTAssertEqual(HelperLogTail.read(path: file.path).split(separator: "\n").count, 200)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testCRLFAndUnterminatedLastLineKeepExistingOutput() throws {
        let data = Data("first\r\n\r\nsecond\nlast".utf8)
        let file = try fixture(data)
        XCTAssertEqual(HelperLogTail.read(path: file.path), previousTail(data))
    }

    func testLongSingleLineIsLimitedByBytes() throws {
        let data = Data(repeating: 0x61, count: 3 * HelperLogTail.byteLimit)
        let file = try fixture(data)
        let tail = HelperLogTail.read(path: file.path)
        XCTAssertEqual(tail, previousTail(data))
        XCTAssertEqual(tail.utf8.count, HelperLogTail.byteLimit)
    }

    func testUTF8BoundariesAndInvalidBytesKeepReplacementDecoding() throws {
        for padding in 0..<4 {
            let data = Data("prefix\n".utf8) + Data(String(repeating: "日志🙂", count: 10_000).utf8)
                + Data(repeating: 0x61, count: padding)
                + Data([0xff, 0xfe]) + Data("\nlast".utf8)
            let file = try fixture(data)
            XCTAssertEqual(HelperLogTail.read(path: file.path), previousTail(data))
        }
    }

    func testAppendAfterSnapshotDoesNotExpandSmallRead() throws {
        let data = Data("before\n".utf8)
        let file = try fixture(data)
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        let end = try reader.seekToEnd()
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("after\n".utf8))
        XCTAssertEqual(try HelperLogTail.read(from: reader, endingAt: end), "before")
        XCTAssertEqual(try reader.offset(), end)
        XCTAssertEqual(HelperLogTail.read(path: file.path), "before\nafter")
    }

    func testConcurrentGrowthKeepsCapturedReadBound() throws {
        let data = Data(repeating: 0x61, count: 2 * HelperLogTail.byteLimit)
        let file = try fixture(data)
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        let end = try reader.seekToEnd()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                let writer = try FileHandle(forWritingTo: file)
                defer { try? writer.close() }
                try writer.seekToEnd()
                let chunk = Data(repeating: 0x62, count: 64 * 1024)
                for index in 0..<32 {
                    try writer.write(contentsOf: chunk)
                    if index == 0 { started.signal() }
                }
            } catch {
                XCTFail("fixture append failed: \(error)")
                started.signal()
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let tail = try HelperLogTail.read(from: reader, endingAt: end)
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(tail, String(repeating: "a", count: HelperLogTail.byteLimit))
        XCTAssertEqual(try reader.offset(), end)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value,
                       end + 32 * 64 * 1024)
    }

    func testTruncateAfterSnapshotReturnsNoStaleBytesAndNextReadRecovers() throws {
        let file = try fixture(Data(repeating: 0x61, count: 2 * HelperLogTail.byteLimit))
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        let end = try reader.seekToEnd()
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.truncate(atOffset: 0)
        try writer.write(contentsOf: Data("new\n".utf8))
        XCTAssertEqual(try HelperLogTail.read(from: reader, endingAt: end), "")
        XCTAssertEqual(HelperLogTail.read(path: file.path), "new")
    }

    func testReplacementKeepsOpenedFileAndNextReadUsesNewFile() throws {
        let file = try fixture(Data("old\n".utf8))
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        let end = try reader.seekToEnd()
        try Data("replacement\n".utf8).write(to: file, options: .atomic)
        XCTAssertEqual(try HelperLogTail.read(from: reader, endingAt: end), "old")
        XCTAssertEqual(HelperLogTail.read(path: file.path), "replacement")
    }

    func testUnlinkKeepsOpenedFileReadable() throws {
        let file = try fixture(Data("old\n".utf8))
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        let end = try reader.seekToEnd()
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try HelperLogTail.read(from: reader, endingAt: end), "old")
        XCTAssertEqual(HelperLogTail.read(path: file.path), "")
    }

    func testClosedDescriptorReportsReadFailure() throws {
        let file = try fixture(Data("old\n".utf8))
        let reader = try FileHandle(forReadingFrom: file)
        let end = try reader.seekToEnd()
        try reader.close()
        XCTAssertThrowsError(try HelperLogTail.read(from: reader, endingAt: end))
    }

    func testUnreadableFileReturnsEmpty() throws {
        try XCTSkipIf(geteuid() == 0, "root can read the permission-denied fixture")
        let data = Data("private\n".utf8)
        let file = try fixture(data)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertEqual(HelperLogTail.read(path: file.path), "")
    }

    func testReal64MiBLogReadsOnlyItsTailAndPreservesFile() throws {
        let file = try fixture()
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        let chunk = Data(repeating: 0x61, count: 1024 * 1024)
        for _ in 0..<64 { try writer.write(contentsOf: chunk) }
        let ending = Data("\nlast one\nlast two\n".utf8)
        try writer.seek(toOffset: 64 * 1024 * 1024 - UInt64(ending.count))
        try writer.write(contentsOf: ending)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let tail = HelperLogTail.read(path: file.path)
        XCTAssertTrue(tail.hasSuffix("last one\nlast two"))
        XCTAssertEqual(tail, String(repeating: "a", count: HelperLogTail.byteLimit - ending.count) + "\nlast one\nlast two")
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((after[.size] as? NSNumber)?.uint64Value, 64 * 1024 * 1024)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }
}
