import AppKit
import SwiftUI

/// 独立工具窗口，不参与主程序与扩展的设置窗口交接。
@MainActor
final class NetworkMonitorWindowController: NSObject, NSWindowDelegate {
    static let shared = NetworkMonitorWindowController()
    let monitor = AppNetworkMonitor()
    private var window: NSWindow?
    var isShowing: Bool { window?.isVisible == true && window?.isMiniaturized == false }

    func show() {
        let newWindow = window == nil
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: NetworkMonitorView(monitor: monitor)))
            window.title = L("网络监控")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 510))
            window.contentMinSize = NSSize(width: 620, height: 380)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("ProxiNetworkMonitor")
            if !window.setFrameUsingName("ProxiNetworkMonitor") { window.center() }
            self.window = window
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if newWindow { monitor.resume() } else { monitor.start() }
    }

    func close() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        monitor.stop(clearSamples: true)
        window = nil
        if !NSApp.windows.contains(where: { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowDidMiniaturize(_ notification: Notification) { monitor.stop() }
    func windowDidDeminiaturize(_ notification: Notification) { monitor.start() }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        if window.isVisible && !window.isMiniaturized && !NSApp.isHidden && window.occlusionState.contains(.visible) { monitor.start() }
        else { monitor.stop() }
    }
}

@MainActor
struct NetworkMonitorView: View {
    @ObservedObject var monitor: AppNetworkMonitor
    @State private var search = ""
    @State private var activeOnly = true
    @State private var sort = Sort.total

    private enum Sort: String, CaseIterable, Identifiable {
        case total, download, upload
        var id: Self { self }
        var title: String {
            switch self {
            case .total: return L("总活动量")
            case .download: return L("下载")
            case .upload: return L("上传")
            }
        }
        func value(_ application: NetworkApplicationRate) -> Double {
            switch self {
            case .total: return application.total
            case .download: return application.download
            case .upload: return application.upload
            }
        }
    }

    private var applications: [NetworkApplicationRate] {
        monitor.applications.filter { $0.matches(search) && (!activeOnly || $0.total > 0) }.sorted {
            if sort.value($0) == sort.value($1) { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return sort.value($0) > sort.value($1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("网络监控")).font(.title2.weight(.semibold))
                    Text(L("查看哪些应用正在使用网络")).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    monitor.togglePause()
                } label: {
                    Label(monitor.isPaused ? L("继续") : L("暂停"), systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
                }
                .help(L("暂停后保留当前画面，继续时重新采样"))
            }
            HStack(spacing: 20) {
                metric(L("整机下载"), symbol: "arrow.down", rate: monitor.download)
                metric(L("整机上传"), symbol: "arrow.up", rate: monitor.upload)
                Spacer()
                if monitor.isPaused {
                    Text(L("已暂停")).foregroundStyle(.secondary)
                } else if !monitor.hasSample && monitor.error == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("正在采样…")).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                TextField(L("搜索应用、进程或 PID"), text: $search)
                    .textFieldStyle(.roundedBorder)
                Toggle(L("仅显示活动项"), isOn: $activeOnly)
                    .toggleStyle(.checkbox)
                Picker(L("排序"), selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 155)
            }
            if let error = monitor.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            Table(applications) {
                TableColumn(L("应用 / 进程")) { application in
                    HStack(spacing: 8) {
                        Image(nsImage: monitor.icon(for: application))
                            .resizable()
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(application.name).lineLimit(1)
                            Text(application.processes.map { String($0.pid) }.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                    .help(application.processes.map { "\($0.name) (PID \($0.pid))" }.joined(separator: "\n"))
                }
                .width(min: 220, ideal: 320)
                TableColumn(L("下载")) { Text(SpeedFormatter.full(bytesPerSecond: NetworkTrafficMath.displayBytes($0.download))).monospacedDigit() }
                    .width(min: 110, ideal: 125)
                TableColumn(L("上传")) { Text(SpeedFormatter.full(bytesPerSecond: NetworkTrafficMath.displayBytes($0.upload))).monospacedDigit() }
                    .width(min: 110, ideal: 125)
                TableColumn(L("进程数")) { Text(String($0.processes.count)).monospacedDigit() }
                    .width(65)
            }
            .overlay {
                if applications.isEmpty && monitor.hasSample && monitor.error == nil {
                    Text(search.isEmpty ? L("当前没有活动的网络进程") : L("没有匹配的应用或进程"))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("整机网速统计物理网卡；应用活动包含本机通信，代理转发时可能重复计数。"))
                Text(L("部分系统进程可能受权限限制；关闭或最小化窗口后停止采样。"))
                if let date = monitor.updatedAt {
                    Text(L("最近采样：%@", date.formatted(date: .omitted, time: .standard)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 380)
    }

    private func metric(_ title: String, symbol: String, rate: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(monitor.hasSample ? SpeedFormatter.full(bytesPerSecond: rate) : "—").font(.title2.monospacedDigit())
        }
        .frame(minWidth: 165, alignment: .leading)
    }
}
