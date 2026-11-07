#if PROXI_UI_FIXTURE
import AppKit
import SwiftUI

/// 专用编译入口，不创建真实 AppDelegate，也不调用 AppState.start。
@MainActor
final class ProxiUIFixture: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    @Published var testCount = 0
    @Published var detectionCount = 0
    @Published var cancelledTests = 0
    @Published var cancelledDetections = 0
    @Published var event = "Fixture ready"
    private var tests: [UUID: (Int, CheckedContinuation<TestResult, Never>)] = [:]
    private var detections: [UUID: CheckedContinuation<[DetectedProxy], Never>] = [:]
    private var controlWindow: NSWindow?
    private var editorWindow: NSWindow?
    private var state: AppState?
    private let navigation = SettingsNavigation()

    static func run() {
        precondition(Bundle.main.bundleIdentifier == "org.codex.fixture.proxi")
        let app = NSApplication.shared
        let delegate = ProxiUIFixture()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var config = AppConfig()
        config.profiles = [
            Profile(name: "Work proxy with a very long configuration name — 工作代理配置", color: "#5B8DEF", host: "proxy.example.invalid", port: 8080), // l10n-ignore: bilingual fixture data
            Profile(name: "Fixture SOCKS / 工作室", color: "#F59E0B", kind: .socks5, host: "localhost.invalid", port: 1080) // l10n-ignore: bilingual fixture data
        ]
        config.healthCheck = false
        config.autoCheckUpdates = false
        config.speedDisplay = .none
        config.testURL = "https://fixture.invalid/check"
        state = AppState(config: config, persisted: PersistedState(), backend: FixtureBackend(), persists: false,
                         reachability: { _, _ in false }, passwordAccess: .init(read: { _, _ in nil }, prompt: { _ in nil }, save: { _, _ in }),
                         operationLog: { _, _ in })
        navigation.selectedProfileID = config.profiles.first?.id
        installMenu()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 860, height: 190),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Proxi Fixture Controls — fake network gates"
        window.contentView = NSHostingView(rootView: FixtureControls(fixture: self))
        window.isReleasedWhenClosed = false
        controlWindow = window
        window.makeKeyAndOrderFront(nil)
        openEditor()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openEditor() {
        guard let state else { return }
        if let editorWindow { editorWindow.makeKeyAndOrderFront(nil); return }
        var actions = ProfileUIActions()
        actions.readPassword = { _ in nil }
        actions.savePassword = { _, _ in }
        actions.deletePassword = { _ in }
        actions.removeProfile = { state, profile in state.config.profiles.removeAll { $0.id == profile.id } }
        actions.test = { [weak self] profile, _, _ in
            guard let self else { return TestResult(ok: false, message: "Fixture closed") }
            return await self.waitForTest(profile)
        }
        actions.detect = { [weak self] _ in await self?.waitForDetection() ?? [] }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Proxi UI Fixture — production ProfilesPage"
        window.contentView = NSHostingView(rootView: ProfilesPage(state: state, navigation: navigation, actions: actions))
        window.minSize = NSSize(width: 800, height: 570)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        editorWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func showControls(_ sender: Any?) { controlWindow?.makeKeyAndOrderFront(nil) }
    @objc private func showEditor(_ sender: Any?) { openEditor() }

    func closeEditor() { editorWindow?.close() }

    func resizeEditor(minimum: Bool) {
        openEditor()
        guard let window = editorWindow else { return }
        let size = minimum ? NSSize(width: 800, height: 570) : NSSize(width: 1120, height: 760)
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        window.setFrame(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), display: true)
        event = "Window \(Int(window.frame.width))×\(Int(window.frame.height)) · content \(Int(window.contentLayoutRect.width))×\(Int(window.contentLayoutRect.height))"
    }

    func addManyProfiles() {
        guard let state else { return }
        guard state.config.profiles.count < 14 else { return }
        for index in state.config.profiles.count..<14 {
            state.config.profiles.append(Profile(name: "Long work profile \(index) — 工作代理配置", color: ProfilePalette.color(at: index), host: "fixture-\(index).invalid", port: 8000 + index)) // l10n-ignore: bilingual fixture data
        }
        event = "14 synthetic profiles; no persistence"
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === editorWindow else { return }
        window.contentView = nil
        editorWindow = nil
    }

    private func waitForTest(_ profile: Profile) async -> TestResult {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                tests[id] = (profile.port, continuation)
                testCount = tests.count
                event = "Test waiting: port \(profile.port)"
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let (_, continuation) = self.tests.removeValue(forKey: id) else { return }
                self.cancelledTests += 1
                self.testCount = self.tests.count
                self.event = "Test cancelled"
                continuation.resume(returning: TestResult(ok: false, message: "Fixture cancelled"))
            }
        }
    }

    private func waitForDetection() async -> [DetectedProxy] {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                detections[id] = continuation
                detectionCount = detections.count
                event = "Detection waiting"
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let continuation = self.detections.removeValue(forKey: id) else { return }
                self.cancelledDetections += 1
                self.detectionCount = self.detections.count
                self.event = "Detection cancelled"
                continuation.resume(returning: [])
            }
        }
    }

    func finishTests(ok: Bool) {
        let pending = tests.values
        tests = [:]; testCount = 0
        for (port, continuation) in pending {
            continuation.resume(returning: TestResult(ok: ok, latencyMs: 73, message: "Fixture port \(port): HTTP \(ok ? 200 : 503)"))
        }
        event = ok ? "Released test success" : "Released HTTP 503"
    }

    func finishDetections() {
        let pending = detections.values
        detections = [:]; detectionCount = 0
        for continuation in pending {
            continuation.resume(returning: [DetectedProxy(host: "127.0.0.1", port: 9090, kind: .http, process: "Fixture Proxy", latencyMs: 12)])
        }
        event = "Released synthetic detection"
    }

    func language(_ code: String) {
        let process = Process(); process.executableURL = Bundle.main.executableURL
        process.arguments = ["-AppleLanguages", "(\(code))"]
        do { try process.run(); NSApp.terminate(nil) } catch { event = error.localizedDescription }
    }

    private func installMenu() {
        let menu = NSMenu(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                                     ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editItem = NSMenuItem(); editItem.submenu = edit; menu.addItem(editItem)
        let windows = NSMenu(title: "Window")
        let controls = windows.addItem(withTitle: "Show Controls", action: #selector(showControls(_:)), keyEquivalent: "0")
        controls.target = self; controls.keyEquivalentModifierMask = [.command, .option]
        let editor = windows.addItem(withTitle: "Show Editor", action: #selector(showEditor(_:)), keyEquivalent: "1")
        editor.target = self; editor.keyEquivalentModifierMask = [.command, .option]
        let windowItem = NSMenuItem(); windowItem.submenu = windows; menu.addItem(windowItem)
        NSApp.mainMenu = menu; NSApp.windowsMenu = windows
    }
}

private struct FixtureControls: View {
    @ObservedObject var fixture: ProxiUIFixture
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Production ProfilesPage / ProfileEditor / DetectSheet — no real network, keychain, persistence or AppState.start")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(action: { fixture.openEditor() }) { Text(verbatim: "Open editor") }
                Button(action: { fixture.closeEditor() }) { Text(verbatim: "Close editor") }
                Button(action: { fixture.finishTests(ok: true) }) { Text(verbatim: "Complete test") }
                Button(action: { fixture.finishTests(ok: false) }) { Text(verbatim: "Return HTTP 503") }
                Button(action: { fixture.finishDetections() }) { Text(verbatim: "Complete detection") }
            }
            HStack {
                Button(action: { fixture.resizeEditor(minimum: true) }) { Text(verbatim: "Minimum 800×570") }
                Button(action: { fixture.resizeEditor(minimum: false) }) { Text(verbatim: "Regular 1120×760") }
                Button(action: { fixture.addManyProfiles() }) { Text(verbatim: "14 long profiles") }
            }
            HStack {
                Button(action: { NSApp.appearance = NSAppearance(named: .aqua) }) { Text(verbatim: "Light") }
                Button(action: { NSApp.appearance = NSAppearance(named: .darkAqua) }) { Text(verbatim: "Dark") }
                Button(action: { fixture.language("en") }) { Text(verbatim: "English ↻") }
                Button(action: { fixture.language("zh-Hans") }) { Text(verbatim: "中文 ↻") } // l10n-ignore: fixture control
                Text(verbatim: "Pending test/detect: \(fixture.testCount)/\(fixture.detectionCount) · Cancelled: \(fixture.cancelledTests)/\(fixture.cancelledDetections)")
                    .font(.caption).monospacedDigit()
            }
            Text(fixture.event).font(.caption).textSelection(.enabled)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// 不访问系统服务；所有外部写入都是空操作。
private struct FixtureBackend: ProxyBackend {
    func currentSystemProxy() -> ProxySnapshot { ProxySnapshot() }
    func applySystemProxy(_ desired: DesiredProxy, also services: [String]) async throws -> [String] { [] }
    func setEnvironment(proxyURL: String, noProxy: String) async throws {}
    func clearEnvironment() async throws {}
    func setGit(proxyURL: String) async throws {}
    func clearGit() async throws {}
    func setNpm(proxyURL: String, noProxy: String) throws {}
    func clearNpm() throws {}
    func captureProxySettings(for target: ProxyTarget) async throws -> ProxyScopeSnapshot.Values { [:] }
    func restoreProxySettings(_ values: ProxyScopeSnapshot.Values, for target: ProxyTarget) async throws {}
}
#endif
