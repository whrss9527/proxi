import AppKit
import Combine

/// 菜单栏上的实时网速：按设置统计系统整体的网卡流量，或者只算代理引擎（内核的 /traffic 流）。
@MainActor
final class SpeedMeter: ObservableObject {
    @Published private(set) var upload = 0
    @Published private(set) var download = 0
    @Published private(set) var mode: SpeedDisplay = .none

    /// 内核的流量流；内核没在跑时返回 nil。
    var coreTraffic: (() async throws -> URLSession.AsyncBytes?)?
    var onUpdate: (@MainActor () -> Void)?

    private var timer: Timer?
    private var lastSample: [String: InterfaceCounters.Sample] = [:]
    private var lastTime: Date?
    private var coreTask: Task<Void, Never>?

    func setMode(_ mode: SpeedDisplay) {
        guard mode != self.mode || (timer == nil && coreTask == nil) else { return }
        stop()
        self.mode = mode
        switch mode {
        case .none:
            publish(upload: 0, download: 0)
        case .system:
            lastSample = InterfaceCounters.read()
            lastTime = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sampleSystem() }
            }
            timer?.tolerance = 0.2
        case .engine:
            coreTask = Task { @MainActor [weak self] in await self?.consumeCore() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        coreTask?.cancel()
        coreTask = nil
    }

    private func publish(upload: Int, download: Int) {
        if upload != self.upload || download != self.download {
            self.upload = upload
            self.download = download
            onUpdate?()
        }
    }

    private func sampleSystem() {
        let now = Date()
        let sample = InterfaceCounters.read()
        defer {
            lastSample = sample
            lastTime = now
        }
        guard let lastTime else { return }
        let seconds = now.timeIntervalSince(lastTime)
        guard seconds > 0.2 else { return }
        let delta = InterfaceCounters.delta(from: lastSample, to: sample)
        publish(upload: Int(Double(delta.sent) / seconds), download: Int(Double(delta.received) / seconds))
    }

    /// 内核每秒推一行 {"up":字节数,"down":字节数}；内核没跑或者断了就显示 0，稍后重连。
    private func consumeCore() async {
        while !Task.isCancelled {
            guard let bytes = try? await coreTraffic?() ?? nil else {
                publish(upload: 0, download: 0)
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            do {
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard let data = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    publish(upload: (json["up"] as? Int) ?? 0, download: (json["down"] as? Int) ?? 0)
                }
            } catch {
                // 连接断了（内核重启或停止），下面重连。
            }
            publish(upload: 0, download: 0)
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
