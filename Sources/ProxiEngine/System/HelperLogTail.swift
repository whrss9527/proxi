import Foundation

/// 助手日志只读文件尾部，避免历史日志大小影响诊断时的内存占用。
enum HelperLogTail {
    static let byteLimit = 64 * 1024

    static func read(path: String) -> String {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd(),
              let text = try? read(from: file, endingAt: end) else { return "" }
        return text
    }

    /// 使用打开的同一文件及捕获的末尾；增长不扩大读入量，替换不混入另一文件。
    static func read(from file: FileHandle, endingAt end: UInt64) throws -> String {
        let count = Int(min(end, UInt64(byteLimit)))
        try file.seek(toOffset: end - UInt64(count))
        let data = try file.read(upToCount: count) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").suffix(200).joined(separator: "\n")
    }
}
