import Foundation

/// 特权助手的安装状态和安装、卸载（设置页、命令行和自动化都经它）。
@MainActor
final class HelperManager: ObservableObject {
    enum State: Equatable {
        case unknown
        case notInstalled
        /// 装了但连不上：被关掉了（系统设置的登录项里），或者还没起来。
        case notRunning(String)
        /// 装的助手和这个程序的协议版本不同，要重新安装。
        case outdated(HelperStatus)
        case ready(HelperStatus)
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var busy = false
    @Published var lastError: String?
    private var timer: Timer?
    /// 要不要定时检查（开了增强模式或网关模式时）：助手被关掉、重新打开都能跟上。
    var wanted: () -> Bool = { false }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var status: HelperStatus? {
        switch state {
        case .ready(let status), .outdated(let status): return status
        default: return nil
        }
    }

    /// 给用户看的一句话。
    var summary: String {
        switch state {
        case .unknown: return L("正在检查特权助手…")
        case .notInstalled: return L("还没有安装特权助手")
        case .notRunning(let message): return message
        case .outdated(let status): return L("特权助手是 %@ 装的，需要重新安装", status.appVersion.isEmpty ? L("旧版本") : status.appVersion)
        case .ready(let status):
            var text = L("特权助手在运行，内核 %@", status.coreVersion)
            if !status.appVersion.isEmpty && status.appVersion != UpdateChecker.currentVersion {
                text += L("（%@ 装的，重新安装可以用上新的内核）", status.appVersion)
            }
            return text
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wanted() else { return }
                await self.refresh()
            }
        }
        timer?.tolerance = 6
        Task { await refresh() }
    }

    func refresh() async {
        guard HelperClient.isInstalled else {
            set(.notInstalled)
            return
        }
        let result = await Task.detached(priority: .utility) { () -> Result<HelperStatus, Error> in
            Result { try HelperClient.status() }
        }.value
        switch result {
        case .success(let status):
            set(status.isCurrent ? .ready(status) : .outdated(status))
        case .failure(let error):
            set(.notRunning(error.localizedDescription))
        }
    }

    private func set(_ state: State) {
        if state != self.state {
            self.state = state
        }
    }

    /// 装上（或者更新）特权助手：系统会要求输入管理员密码。成功返回 true。
    @discardableResult
    func install() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        lastError = nil
        guard let core = CoreBinary.installedPath else {
            lastError = L("还没有下载内核，到「内核」页下载")
            return false
        }
        let command = "\(Shell.shellQuote(AdminCommand.executablePath)) helper install --uid \(getuid()) --core \(Shell.shellQuote(core))"
        do {
            try await AdminCommand.run(command, failure: L("特权助手没有装上"))
        } catch {
            lastError = (error as? ControlError)?.message ?? error.localizedDescription
            await refresh()
            return false
        }
        // 刚加载的守护进程要一小会儿才能连上。
        for _ in 0..<20 {
            await refresh()
            if isReady { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if isReady {
            Log.info("特权助手已安装")
            return true
        }
        lastError = summary
        return false
    }

    /// 卸载特权助手（增强模式和网关模式跟着停掉）。成功返回 true。
    @discardableResult
    func uninstall() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        lastError = nil
        let command = "\(Shell.shellQuote(AdminCommand.executablePath)) helper uninstall"
        do {
            try await AdminCommand.run(command, failure: L("特权助手没有卸载"))
        } catch {
            lastError = (error as? ControlError)?.message ?? error.localizedDescription
            return false
        }
        await refresh()
        Log.info("特权助手已卸载")
        return true
    }
}

/// 以管理员身份运行一条命令（系统会弹出输入密码的窗口）。
enum AdminCommand {
    /// 这个程序的二进制：装特权助手时复制它。
    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    static func run(_ command: String, failure: String) async throws {
        let script = "do shell script \(Shell.appleScriptString(command)) with administrator privileges"
        let result = try await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 180)
        guard result.succeeded else {
            let output = result.trimmedOutput
            throw ControlError.failed(output.contains("-128") ? L("取消了") : L("%@：%@", failure, output))
        }
    }
}
