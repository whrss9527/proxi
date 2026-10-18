import AppKit
import Combine

/// 菜单栏上的实时网速：统计系统整体的网卡流量。
@MainActor
final class SpeedMeter: ObservableObject {
    @Published private(set) var upload = 0
    @Published private(set) var download = 0
    @Published private(set) var mode: SpeedDisplay = .none

    var onUpdate: (@MainActor () -> Void)?

    private var timer: Timer?
    private var lastSample: [String: InterfaceCounters.Sample] = [:]
    private var lastTime: Date?

    func setMode(_ mode: SpeedDisplay) {
        guard mode != self.mode || timer == nil else { return }
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
        }
        // 换了显示方式要重画菜单栏图标：网速本来就是 0 时 publish 不会通知，「不显示」以后还留着 0.00B。
        onUpdate?()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
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
}
