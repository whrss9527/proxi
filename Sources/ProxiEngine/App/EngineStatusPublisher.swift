import Combine
import Foundation

/// 写给 Proxi 看的状态：数据目录里的 status.json。Proxi 按它在配置列表里放一条「代理引擎」（指向 mixedPort），
/// 开启那条配置前确认内核在运行。格式两边各定义一份，改的时候一起改（Proxi 那边是 ExtensionStatus）。
struct EngineStatusFile: Codable, Equatable {
    var version: String
    var pid: Int32
    var mixedPort: Int
    /// 内核在运行（可以接受连接了）。
    var coreRunning: Bool
    /// 内核已经下载并校验过。
    var coreReady: Bool
    /// 一句话的状态，Proxi 的扩展页里显示。
    var summary: String
    var updatedAt: Date

    static var url: URL { Store.directory.appendingPathComponent("status.json") }
}

@MainActor
final class EngineStatusPublisher {
    private weak var state: AppState?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var last: EngineStatusFile?

    func start(state: AppState) {
        self.state = state
        state.engine.$status
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.publish() } }
            .store(in: &cancellables)
        state.core.$phase
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.publish() } }
            .store(in: &cancellables)
        state.$config
            .map(\.engine.mixedPort)
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.publish() } }
            .store(in: &cancellables)
        state.$config
            .map(\.engine.wantsCore)
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.publish() } }
            .store(in: &cancellables)
        // 隔一会儿重写一次：Proxi 按更新时间和进程号判断代理引擎是不是还活着。
        // 放在 common 模式里：开着选择文件的对话框（导入、规则文件）时也照样写，不然超过 45 秒 Proxi 就当它停了。
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish(force: true) }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        publish()
    }

    func publish(force: Bool = false) {
        guard let state else { return }
        let file = EngineStatusFile(
            version: UpdateChecker.currentVersion,
            pid: ProcessInfo.processInfo.processIdentifier,
            mixedPort: state.config.engine.mixedPort,
            // 内核只为局域网共享、网关模式在跑时（没启用代理引擎或者没有节点）不开代理端口：这时不能算「在运行」，
            // 不然 Proxi 会把系统代理指向一个没人监听的端口。
            coreRunning: state.engine.isRunning && state.config.engine.wantsCore,
            coreReady: state.core.isReady,
            summary: state.engine.statusTitle,
            updatedAt: Date()
        )
        if !force, var previous = last {
            previous.updatedAt = file.updatedAt
            if previous == file { return }
        }
        last = file
        do {
            try FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: EngineStatusFile.url, options: .atomic)
        } catch {
            Log.error("写状态文件失败：\(error.localizedDescription)")
        }
    }

    func remove() {
        timer?.invalidate()
        try? FileManager.default.removeItem(at: EngineStatusFile.url)
    }
}
