import AppKit
import Combine

@MainActor
final class AppNetworkMonitor: ObservableObject {
    @Published private(set) var applications: [NetworkApplicationRate] = []
    @Published private(set) var download = 0
    @Published private(set) var upload = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var hasSample = false
    @Published private(set) var error: String?
    @Published private(set) var updatedAt: Date?

    private let fetch: @Sendable () async throws -> NetworkMonitorFrame
    private let interval: Duration
    private var worker: Task<Void, Never>?
    private var previous: NetworkMonitorFrame?
    private var generation = 0
    private var icons: [String: NSImage] = [:]
    private var names: [String: String] = [:]

    init(interval: Duration = .seconds(2), fetch: @escaping @Sendable () async throws -> NetworkMonitorFrame = { try await ProcessNetworkSampler.read() }) {
        self.interval = interval
        self.fetch = fetch
    }

    func start() {
        guard worker == nil, !isPaused else { return }
        previous = nil
        hasSample = false
        error = nil
        updatedAt = nil
        applications = []
        download = 0
        upload = 0
        isRunning = true
        generation += 1
        let generation = generation
        let fetch = fetch
        let interval = interval
        worker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await fetch()
                    guard let self, self.generation == generation, !Task.isCancelled else { return }
                    self.consume(frame)
                } catch {
                    guard let self, self.generation == generation, !Task.isCancelled else { return }
                    self.previous = nil
                    self.applications = []
                    self.download = 0
                    self.upload = 0
                    self.hasSample = false
                    self.error = Redact.secrets(error.localizedDescription)
                }
                do { try await Task.sleep(for: interval) }
                catch { return }
            }
        }
    }

    /// 暂停保留画面；隐藏/关闭取消进程，重新显示时从新基线采样。
    func stop() {
        generation += 1
        worker?.cancel()
        worker = nil
        previous = nil
        isRunning = false
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused { stop() } else { start() }
    }

    func resume() {
        isPaused = false
        start()
    }

    func icon(for application: NetworkApplicationRate) -> NSImage {
        if let icon = icons[application.id] { return icon }
        let icon = application.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage()
        icons[application.id] = icon
        return icon
    }

    private func consume(_ frame: NetworkMonitorFrame) {
        error = nil
        updatedAt = frame.date
        defer { previous = frame }
        guard let previous else { return }
        let seconds = frame.uptime - previous.uptime
        guard seconds.isFinite, seconds > 0.2, seconds < 15 else {
            applications = []
            download = 0
            upload = 0
            hasSample = false
            return
        }
        var rates = NetworkTrafficMath.rates(from: previous, to: frame)
        for index in rates.indices {
            guard let path = rates[index].bundlePath else { continue }
            if names[path] == nil {
                let bundle = Bundle(path: path)
                names[path] = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String) ?? rates[index].name
            }
            rates[index].name = names[path] ?? rates[index].name
        }
        applications = rates
        let delta = InterfaceCounters.delta(from: previous.interfaces, to: frame.interfaces)
        download = NetworkTrafficMath.displayBytes(Double(delta.received) / seconds)
        upload = NetworkTrafficMath.displayBytes(Double(delta.sent) / seconds)
        hasSample = true
        let present = Set(rates.map(\.id))
        icons = icons.filter { present.contains($0.key) }
        names = names.filter { present.contains($0.key) }
    }
}
