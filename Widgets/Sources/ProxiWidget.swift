import AppIntents
import Foundation
import ProxiWidgets
import SwiftUI
import WidgetKit

private func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

private func snapshot() -> ProxyWidgetSnapshot? {
    guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ProxyWidgetSnapshot.group) else { return nil }
    return ProxyWidgetSnapshot.read(in: directory)
}

struct SavedProxy: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "代理配置") // l10n-ignore
    static let defaultQuery = SavedProxyQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}

struct SavedProxyQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SavedProxy] {
        let profiles = snapshot()?.profiles ?? []
        return identifiers.compactMap { id in profiles.first { $0.id == id } }.map { SavedProxy(id: $0.id, name: $0.name) }
    }
    func suggestedEntities() async throws -> [SavedProxy] {
        (snapshot()?.profiles ?? []).map { SavedProxy(id: $0.id, name: $0.name) }
    }
}

struct ProxyConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "代理小组件" // l10n-ignore
    @Parameter(title: "代理配置") var profiles: [SavedProxy]? // l10n-ignore
}

struct ProxyEntry: TimelineEntry {
    let date: Date
    let snapshot: ProxyWidgetSnapshot?
    let ids: [String]
}

struct ProxyProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ProxyEntry { ProxyEntry(date: Date(), snapshot: nil, ids: []) }
    func snapshot(for configuration: ProxyConfiguration, in context: Context) async -> ProxyEntry {
        ProxyEntry(date: Date(), snapshot: ProxiWidget.snapshotValue(), ids: configuration.profiles?.map(\.id) ?? [])
    }
    func timeline(for configuration: ProxyConfiguration, in context: Context) async -> Timeline<ProxyEntry> {
        let entry = await snapshot(for: configuration, in: context)
        let next = entry.date.addingTimeInterval(901)
        return Timeline(entries: [entry, ProxyEntry(date: next, snapshot: entry.snapshot, ids: entry.ids)], policy: .after(next))
    }
}

struct ProxyWidgetView: View {
    let entry: ProxyEntry
    private var profiles: [WidgetProfile] {
        let values = entry.snapshot?.profiles ?? []
        if entry.ids.isEmpty { return Array(values.prefix(2)) }
        return Array(entry.ids.compactMap { id in values.first { $0.id == id } }.prefix(2))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Proxi", systemImage: "network").font(.headline)
                Spacer()
                if let value = entry.snapshot, value.isStale(at: entry.date) {
                    Text(L("缓存状态")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let value = entry.snapshot {
                HStack {
                    Text(state(value)).font(.caption.bold())
                    if let name = value.selectedName { Text(verbatim: name).font(.caption).lineLimit(1) }
                }
                HStack(spacing: 4) {
                    Text(health(value)).font(.caption2)
                    if let date = value.healthCheckedAt { Text(date, style: .time).font(.caption2) }
                }.foregroundStyle(.secondary)
            } else {
                Text(L("打开 Proxi 读取配置")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Link(L("开启代理"), destination: URL(string: "proxi://on")!)
                Spacer()
                Link(L("关闭代理"), destination: URL(string: "proxi://off")!)
            }.font(.caption)
            HStack {
                ForEach(profiles) { profile in
                    Link(destination: profile.link) {
                        Text(verbatim: profile.name).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let value = entry.snapshot {
                HStack(spacing: 3) {
                    Text(L("记录时间"))
                    Text(value.recordedAt, style: .date)
                    Text(value.recordedAt, style: .time)
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "proxi://panel"))
    }
    private func state(_ value: ProxyWidgetSnapshot) -> String {
        if value.busy { return L("操作中") }
        if value.partial { return L("部分范围未生效") }
        switch value.mode { case .on: return L("已开启"); case .off: return L("已关闭"); case .external: return L("其他程序设置的代理") }
    }
    private func health(_ value: ProxyWidgetSnapshot) -> String {
        switch value.health { case .ok: return L("连接正常"); case .down: return L("连接失败"); case .unknown: return L("尚未检测连接") }
    }
}

@main
struct ProxiWidget: Widget {
    static func snapshotValue() -> ProxyWidgetSnapshot? { snapshot() }
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ProxiStatus", intent: ProxyConfiguration.self, provider: ProxyProvider()) { ProxyWidgetView(entry: $0) }
            .configurationDisplayName(L("代理小组件"))
            .description(L("查看最近确认的状态，点击开关或切换配置。"))
            .supportedFamilies([.systemMedium])
    }
}
