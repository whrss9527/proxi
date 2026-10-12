import Combine
import Foundation
import ProxiWidgets
import WidgetKit

@MainActor
final class WidgetPublisher {
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var last: ProxyWidgetSnapshot?
    private var reloadAt = Date.distantPast

    func start(state: AppState) {
        Publishers.MergeMany(state.$config.map { _ in () }.eraseToAnyPublisher(),
                             state.$snapshot.map { _ in () }.eraseToAnyPublisher(),
                             state.$persisted.map { _ in () }.eraseToAnyPublisher(),
                             state.$health.map { _ in () }.eraseToAnyPublisher(),
                             state.$busy.map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main)
            .sink { [weak self, weak state] _ in if let state { self?.publish(state: state) } }
            .store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self, weak state] _ in
            MainActor.assumeIsolated { if let state { self?.publish(state: state) } }
        }
        publish(state: state)
    }

    func stop(state: AppState) {
        timer?.invalidate(); timer = nil
        subscriptions.removeAll()
        publish(state: state, running: false)
    }

    private func publish(state: AppState, running: Bool = true) {
        let directory: URL?
        if let path = ProcessInfo.processInfo.environment["PROXI_WIDGET_DIR"] {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ProxyWidgetSnapshot.group)
        }
        guard let directory else { return }
        let mode: ProxyWidgetSnapshot.Mode
        switch state.status { case .on: mode = .on; case .off: mode = .off; case .external: mode = .external }
        let health: ProxyWidgetSnapshot.Health
        switch state.health { case .ok: health = .ok; case .down: health = .down; case .unknown: health = .unknown }
        let now = Date()
        let value = ProxyWidgetSnapshot(now: now, mode: mode, health: health, healthCheckedAt: state.widgetHealthCheckedAt,
                                        selectedName: state.selectedProfile?.name,
                                        profiles: state.config.profiles.map { WidgetProfile(id: $0.id.uuidString, name: $0.name) },
                                        busy: state.busy, partial: state.isPartiallyApplied, appRunning: running)
        do {
            try value.write(in: directory)
            if value.profiles != last?.profiles || now.timeIntervalSince(reloadAt) >= 300 || !running {
                WidgetCenter.shared.reloadTimelines(ofKind: "ProxiStatus")
                reloadAt = now
            }
            last = value
        } catch { Log.info("小组件快照写入失败：\(error.localizedDescription)") }
    }
}
