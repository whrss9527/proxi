import Combine
import Foundation

/// 测试结果只属于启动请求时的配置、密码和测速地址。
struct ProfileTestInput: Equatable {
    var profile: Profile
    var password: String
    var testURL: String
}

@MainActor
final class ProfileTestState: ObservableObject {
    @Published private(set) var testing = false
    @Published private(set) var result: TestResult?
    private var input: ProfileTestInput?
    private var generation: UInt = 0
    private var task: Task<Void, Never>?
    private let run: @MainActor (ProfileTestInput) async -> TestResult

    init(run: @escaping @MainActor (ProfileTestInput) async -> TestResult) { self.run = run }
    deinit { task?.cancel() }

    @discardableResult
    func start(_ input: ProfileTestInput) -> Task<Void, Never> {
        cancel()
        self.input = input
        testing = true
        let request = generation
        let run = self.run
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let response = await run(input)
            guard !Task.isCancelled, let self, self.generation == request, self.input == input else { return }
            self.result = response
            self.testing = false
            self.task = nil
        }
        self.task = task
        return task
    }

    func inputChanged(_ current: ProfileTestInput) {
        guard input != current else { return }
        cancel()
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        input = nil
        result = nil
        testing = false
    }
}
