import Foundation

public enum CommandBatches {
    /// 服务之间并行，单个服务内仍按顺序写入；全部完成后才允许授权重试。
    /// 收集全部错误后按输入顺序抛出，避免授权提示与尚未结束的普通写入重叠。
    public static func run(_ batches: [[[String]]], execute: @escaping @Sendable ([String]) async throws -> Void) async throws {
        let errors = await withTaskGroup(of: (Int, Error?).self) { group in
            for (index, commands) in batches.enumerated() {
                group.addTask {
                    do {
                        for command in commands {
                            try Task.checkCancellation()
                            try await execute(command)
                        }
                        return (index, nil)
                    } catch {
                        return (index, error)
                    }
                }
            }
            var errors: [(Int, Error)] = []
            for await (index, error) in group {
                if let error { errors.append((index, error)) }
            }
            return errors.sorted { $0.0 < $1.0 }
        }
        try Task.checkCancellation()
        if let error = errors.first?.1 { throw error }
    }
}
