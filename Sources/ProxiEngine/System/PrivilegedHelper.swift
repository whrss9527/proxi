import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// 特权助手：一个以 root 运行的 launchd 守护进程，替程序以 root 运行内核（虚拟网卡要 root），并开关 IP 转发（网关模式）。
// 装一次要输管理员密码，之后开关增强模式、网关模式都不用再输。
// 它只听安装它的那个用户的话，只运行自己那份 root 所有的内核（复制进来后、每次启动前都按 CorePin 里写死的 SHA-256 校验）；内核的目录也只有 root 能写，
// 配置和规则文件由它从用户的内核目录按名单复制过去，而且只复制属于这个用户的普通文件（不跟随符号链接）。

// MARK: - 位置和协议

/// 这些名字是改名前定下的，已经装好的助手按它们工作（程序生成的内核配置也要和它对得上），所以不跟着改。
enum HelperPaths {
    static let label = "com.whrss9527.proxyswitch.helper"
    static let toolsDirectory = "/Library/PrivilegedHelperTools"
    static var executable: String { "\(toolsDirectory)/\(label)" }
    static var core: String { "\(toolsDirectory)/com.whrss9527.proxyswitch.mihomo" }
    static var plist: String { "/Library/LaunchDaemons/\(label).plist" }
    static var socket: String { "/var/run/\(label).sock" }
    /// root 的数据目录：内核目录和 IP 转发改动前的值都在这里，只有 root 能写。
    static let dataDirectory = "/Library/Application Support/ProxySwitch"
    static var coreDirectory: String { dataDirectory + "/core" }
    static var coreConfig: String { coreDirectory + "/config.yaml" }
    static var coreLog: String { coreDirectory + "/core.log" }
    static var forwardingState: String { dataDirectory + "/forwarding.json" }
    static let log = "/Library/Logs/ProxySwitch-helper.log"
}

enum HelperProtocol {
    /// 程序和助手之间的协议版本。程序更新后发现助手的版本不同，会请用户重新安装助手。
    /// 2：内核目录只有 root 能读（里面的配置有控制接口的密钥和节点的密码），内核日志只给装助手的用户读。
    static let version = 2
}

/// 助手报告的状态。
struct HelperStatus: Equatable {
    var protocolVersion: Int
    /// 装助手时的程序版本。
    var appVersion: String
    /// 助手里那份内核的版本。
    var coreVersion: String
    var running: Bool
    var forwarding: Bool

    init(protocolVersion: Int, appVersion: String, coreVersion: String, running: Bool, forwarding: Bool) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.coreVersion = coreVersion
        self.running = running
        self.forwarding = forwarding
    }

    init(_ result: [String: Any]) {
        protocolVersion = (result["protocol"] as? Int) ?? 0
        appVersion = (result["version"] as? String) ?? ""
        coreVersion = (result["core"] as? String) ?? ""
        running = (result["running"] as? Bool) ?? false
        forwarding = (result["forwarding"] as? Bool) ?? false
    }

    var isCurrent: Bool { protocolVersion == HelperProtocol.version }
}

struct HelperError: LocalizedError {
    let message: String
    let diagnosticCode: String?
    init(_ message: String, diagnosticCode: String? = nil) {
        self.message = message
        self.diagnosticCode = diagnosticCode
    }
    var errorDescription: String? { message }
}

// MARK: - 文件

/// 从用户的内核目录复制文件到 root 的内核目录。
enum HelperFiles {
    static let maxFileSize = 64 << 20
    static let maxFiles = 4000

    /// 相对路径是否安全：不能是绝对路径，不能有空的部分、. 和 ..。
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count < 1024, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." || part == ".." { return false }
        }
        return true
    }

    /// 读用户目录里的一个文件：必须是属于 owner 的普通文件，最后一级不能是符号链接。
    /// 这样即使别的程序在用户目录里放了指向系统文件的链接，助手也不会把 root 才能读的东西复制出去。
    static func readFile(_ relative: String, from source: String, owner: UInt32) throws -> Data {
        guard isSafeRelativePath(relative) else { throw HelperError(L("文件名不对：%@", relative)) }
        let path = (source as NSString).appendingPathComponent(relative)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HelperError(L("读不了 %@：%@", relative, String(cString: strerror(errno)))) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw HelperError(L("读不了 %@", relative)) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw HelperError(L("%@ 不是普通文件", relative)) }
        guard UInt32(info.st_uid) == owner else { throw HelperError(L("%@ 不属于这个用户", relative)) }
        guard Int(info.st_size) <= maxFileSize else { throw HelperError(L("%@ 太大了", relative)) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw HelperError(L("读不了 %@", relative))
            }
            if count == 0 { break }
            data.append(contentsOf: chunk[0..<count])
            if data.count > maxFileSize { throw HelperError(L("%@ 太大了", relative)) }
        }
        return data
    }

    /// 写进 root 的目录：先写临时文件再改名，别人看到的总是完整的文件。只有 root 能读：
    /// 配置里有内核控制接口的密钥，节点文件里有服务器的密码。
    static func write(_ data: Data, to relative: String, in target: String) throws {
        guard isSafeRelativePath(relative) else { throw HelperError(L("文件名不对：%@", relative)) }
        let path = (target as NSString).appendingPathComponent(relative)
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = path + ".ps-tmp"
        unlink(temporary)
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw HelperError(L("写不了 %@", relative))
        }
        guard rename(temporary, path) == 0 else {
            unlink(temporary)
            throw HelperError(L("写不了 %@：%@", relative, String(cString: strerror(errno))))
        }
    }

    /// 按名单复制；名单要检查过（数量、路径）。
    static func copy(_ files: [String], from source: String, to target: String, owner: UInt32) throws {
        guard source.hasPrefix("/") else { throw HelperError(L("来源目录要是绝对路径")) }
        guard files.count <= maxFiles else { throw HelperError(L("文件太多了")) }
        for relative in files {
            let data = try readFile(relative, from: source, owner: owner)
            try write(data, to: relative, in: target)
        }
    }
}

// MARK: - IP 转发

/// 网关模式要打开 IP 转发；改之前的值记下来（也写到文件里，助手意外退出后下次启动时恢复）。
struct ForwardingState: Codable, Equatable {
    var ipv4: Int32
    var ipv6: Int32
}

enum Forwarding {
    static let ipv4Key = "net.inet.ip.forwarding"
    static let ipv6Key = "net.inet6.ip6.forwarding"

    static func read(_ name: String) -> Int32? {
        #if canImport(Darwin)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
        #else
        return nil
        #endif
    }

    @discardableResult
    static func write(_ name: String, _ value: Int32) -> Bool {
        #if canImport(Darwin)
        var copy = value
        return sysctlbyname(name, nil, nil, &copy, MemoryLayout<Int32>.size) == 0
        #else
        return false
        #endif
    }
}

// MARK: - 安装

enum HelperInstaller {
    /// launchd 的配置：开机就运行，退出了自动重启。
    static func plist(uid: UInt32, appVersion: String) throws -> Data {
        let dictionary: [String: Any] = [
            "Label": HelperPaths.label,
            "ProgramArguments": [HelperPaths.executable, "helper", "run", "--uid", String(uid), "--version", appVersion],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": HelperPaths.log,
            "StandardErrorPath": HelperPaths.log,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    /// 以 root 运行：复制程序和内核、准备 root 的目录、写 launchd 配置并加载。
    static func install(uid: UInt32, appVersion: String, executable: String, core: String) throws {
        guard geteuid() == 0 else { throw HelperError(L("要用管理员权限运行")) }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable) else { throw HelperError(L("找不到程序：%@", executable)) }
        guard fm.isExecutableFile(atPath: core) else { throw HelperError(L("找不到内核：%@", core)) }
        // 先查一遍来源（不动任何东西），复制到 root 的目录以后再查一遍。
        try verifyCore(core, removeIfWrong: false)
        // 先停掉旧的（更新助手时），再换文件。
        _ = try? Shell.runSync("/bin/launchctl", ["bootout", "system/\(HelperPaths.label)"], timeout: 30)
        if !fm.fileExists(atPath: HelperPaths.toolsDirectory) {
            try rootDirectory(HelperPaths.toolsDirectory)
        }
        try installFile(from: executable, to: HelperPaths.executable)
        try installFile(from: core, to: HelperPaths.core)
        // 内核是下载来的：复制到 root 的目录以后（用户改不了了）再校验，不是认可的版本就删掉、不装。
        try verifyCore(HelperPaths.core, removeIfWrong: true)
        // 程序文件离开了 app 包，重新做一个独立的签名。
        _ = try? Shell.runSync("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", HelperPaths.label, HelperPaths.executable], timeout: 120)
        try rootDirectory(HelperPaths.dataDirectory)
        // 内核目录别人只能穿过、不能列出和读里面的文件（内核日志单独给装助手的用户读，见 launchCoreLocked）。
        try rootDirectory(HelperPaths.coreDirectory, mode: 0o711)
        try plist(uid: uid, appVersion: appVersion).write(to: URL(fileURLWithPath: HelperPaths.plist), options: .atomic)
        try own(HelperPaths.plist, mode: 0o644)
        // 刚停掉的旧助手可能还没退干净，加载失败时稍等再试。
        var result = try Shell.runSync("/bin/launchctl", ["bootstrap", "system", HelperPaths.plist], timeout: 30)
        for _ in 0..<5 where !result.succeeded {
            Thread.sleep(forTimeInterval: 1)
            result = try Shell.runSync("/bin/launchctl", ["bootstrap", "system", HelperPaths.plist], timeout: 30)
        }
        guard result.succeeded else { throw HelperError(L("launchctl 加载失败：%@", result.trimmedOutput)) }
        // 开着 macOS 防火墙时，让网关设备能连到内核的 DNS。
        let firewall = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        if fm.isExecutableFile(atPath: firewall) {
            _ = try? Shell.runSync(firewall, ["--add", HelperPaths.core], timeout: 20)
            _ = try? Shell.runSync(firewall, ["--unblockapp", HelperPaths.core], timeout: 20)
        }
    }

    /// 内核程序的 SHA-256 是不是认可的（CorePin 里写死的）；不是就删掉并报错。
    static func verifyCore(_ path: String, removeIfWrong: Bool) throws {
        let hash = (try? Checksums.sha256(of: URL(fileURLWithPath: path))) ?? ""
        guard CorePin.binarySHA256s.contains(hash) else {
            if removeIfWrong { unlink(path) }
            throw HelperError(L("内核的校验和不对（%@），没有安装", hash.isEmpty ? L("读不了") : String(hash.prefix(12))), diagnosticCode: "core_checksum")
        }
    }

    /// 以 root 运行：停掉并删除助手和它的文件。
    static func uninstall() throws {
        guard geteuid() == 0 else { throw HelperError(L("要用管理员权限运行")) }
        _ = try? Shell.runSync("/bin/launchctl", ["bootout", "system/\(HelperPaths.label)"], timeout: 30)
        let firewall = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        if FileManager.default.isExecutableFile(atPath: firewall) {
            _ = try? Shell.runSync(firewall, ["--remove", HelperPaths.core], timeout: 20)
        }
        // 助手被停掉时会自己恢复 IP 转发；万一没来得及，这里再恢复一次。
        if let data = FileManager.default.contents(atPath: HelperPaths.forwardingState), let saved = try? JSONDecoder().decode(ForwardingState.self, from: data) {
            Forwarding.write(Forwarding.ipv4Key, saved.ipv4)
            Forwarding.write(Forwarding.ipv6Key, saved.ipv6)
        }
        for path in [HelperPaths.plist, HelperPaths.executable, HelperPaths.core, HelperPaths.socket, HelperPaths.log] {
            unlink(path)
        }
        try? FileManager.default.removeItem(atPath: HelperPaths.dataDirectory)
    }

    /// root 所有、别人不能写的目录；原来是符号链接或者别人的就换掉。
    private static func rootDirectory(_ path: String, mode: mode_t = 0o755) throws {
        var info = stat()
        if lstat(path, &info) == 0 && (info.st_mode & S_IFMT) != S_IFDIR {
            try FileManager.default.removeItem(atPath: path)
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try own(path, mode: mode)
    }

    private static func installFile(from source: String, to target: String) throws {
        var info = stat()
        if lstat(target, &info) == 0 {
            try FileManager.default.removeItem(atPath: target)
        }
        try FileManager.default.copyItem(atPath: source, toPath: target)
        try own(target, mode: 0o755)
        #if canImport(Darwin)
        // 下载来的程序带着隔离标记，复制出来的也会有；守护进程用不着它。
        removexattr(target, "com.apple.quarantine", XATTR_NOFOLLOW)
        #endif
    }

    private static func own(_ path: String, mode: mode_t) throws {
        guard chown(path, 0, 0) == 0, chmod(path, mode) == 0 else {
            throw HelperError(L("设置 %@ 的权限失败：%@", path, String(cString: strerror(errno))))
        }
    }
}

// MARK: - 守护进程

/// 以 root 运行的那一端。每个连接一个线程，一行请求一行回应：
/// - status：版本和状态；
/// - start {source, files}：复制文件、启动内核。回应之后这个连接就是「租约」：断开（程序退出或崩溃）就停掉内核、恢复 IP 转发；
///   内核自己退出时在租约上发一行 {"event":"exit","status":N}；
/// - sync {source, files}：只复制文件（程序改了配置，接着让内核重新加载）；
/// - stop：停掉内核，等它退出再回应；
/// - forwarding {enabled}：开关 IP 转发。
final class HelperDaemon: @unchecked Sendable {
    let allowedUID: UInt32
    let appVersion: String
    private let lock = NSLock()
    private var process: Process?
    private var lease: Lease?
    private var savedForwarding: ForwardingState?
    private var coreVersion = ""
    private var signalSources: [DispatchSourceSignal] = []

    private final class Lease {
        let fd: Int32
        /// 租约线程已经结束（马上会关掉 fd）：别的线程不能再碰这个 fd。
        var finished = false
        init(fd: Int32) { self.fd = fd }
    }

    init(uid: UInt32, appVersion: String) {
        allowedUID = uid
        self.appVersion = appVersion
    }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        // 内核（root）自己建的文件（缓存、下载的订阅和规则）也只给 root 读。
        umask(0o077)
        Self.tightenCoreDirectory(userID: allowedUID)
        restoreLeftoverForwarding()
        coreVersion = Self.readCoreVersion()
        installSignalHandlers()
        let listener: Int32
        do {
            listener = try openListener()
        } catch {
            Self.log("开不了套接字：\(error.localizedDescription)")
            Thread.sleep(forTimeInterval: 10)
            exit(1)
        }
        Self.log("特权助手已启动，只接受用户 \(allowedUID)，内核 \(coreVersion)")
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno != EINTR { Thread.sleep(forTimeInterval: 0.1) }
                continue
            }
            guard let peer = Self.peerUID(client), peer == allowedUID || peer == 0 else {
                close(client)
                continue
            }
            Thread.detachNewThread { [self] in
                serve(client)
            }
        }
    }

    // MARK: 连接

    private func openListener() throws -> Int32 {
        let path = HelperPaths.socket
        unlink(path)
        let fd = UnixSocket.makeSocket()
        guard fd >= 0 else { throw HelperError(L("建不了套接字")) }
        var (address, length) = try UnixSocket.address(path)
        let oldMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        umask(oldMask)
        guard bound == 0 else {
            close(fd)
            throw HelperError(L("绑定失败：%@", String(cString: strerror(errno))))
        }
        // 只有安装助手的用户（和 root）能连。
        guard chown(path, allowedUID, UInt32.max) == 0, chmod(path, 0o600) == 0 else {
            close(fd)
            throw HelperError(L("设置套接字权限失败"))
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw HelperError(L("监听失败"))
        }
        return fd
    }

    private func serve(_ client: Int32) {
        UnixSocket.disableSigpipe(client)
        UnixSocket.setTimeout(client, seconds: 120)
        var buffer = Data()
        while let line = UnixSocket.readLine(client, buffer: &buffer, limit: 4 << 20) {
            if line.isEmpty { continue }
            guard let request = JSONRPC.decode(line), let method = request["method"] as? String else {
                reply(client, JSONRPC.error(id: nil, code: JSONRPC.parseError, message: L("读不懂的请求")))
                continue
            }
            let id = request["id"]
            let params = (request["params"] as? [String: Any]) ?? [:]
            if method == "start" {
                do {
                    let lease = try start(params, id: id, client: client)
                    hold(lease)
                    return
                } catch {
                    reply(client, JSONRPC.error(id: id, code: JSONRPC.internalError, message: error.localizedDescription))
                    continue
                }
            }
            do {
                reply(client, JSONRPC.result(id: id, try handle(method, params)))
            } catch {
                reply(client, JSONRPC.error(id: id, code: JSONRPC.internalError, message: error.localizedDescription))
            }
        }
        close(client)
    }

    private func reply(_ client: Int32, _ object: [String: Any]) {
        var data = JSONRPC.encode(object)
        data.append(0x0A)
        _ = UnixSocket.writeAll(client, data)
    }

    private func handle(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "status":
            lock.lock()
            defer { lock.unlock() }
            return [
                "protocol": HelperProtocol.version,
                "version": appVersion,
                "core": coreVersion,
                "running": process?.isRunning ?? false,
                "forwarding": savedForwarding != nil,
            ]
        case "sync":
            let (source, files) = try fileList(params)
            lock.lock()
            defer { lock.unlock() }
            try HelperFiles.copy(files, from: source, to: HelperPaths.coreDirectory, owner: allowedUID)
            return ["copied": files.count]
        case "stop":
            lock.lock()
            defer { lock.unlock() }
            stopCoreLocked()
            endLeaseLocked()
            return ["running": false]
        case "forwarding":
            guard let enabled = params["enabled"] as? Bool else { throw HelperError(L("enabled 要写 true 或 false")) }
            lock.lock()
            defer { lock.unlock() }
            if enabled {
                guard process?.isRunning == true else { throw HelperError(L("内核没在运行")) }
                try enableForwardingLocked()
            } else {
                restoreForwardingLocked()
            }
            return ["forwarding": savedForwarding != nil]
        default:
            throw HelperError(L("不认识的请求：%@", method))
        }
    }

    private func fileList(_ params: [String: Any]) throws -> (String, [String]) {
        guard let source = params["source"] as? String, source.hasPrefix("/") else { throw HelperError(L("少了来源目录")) }
        let files = (params["files"] as? [String]) ?? []
        guard files.allSatisfy(HelperFiles.isSafeRelativePath) else { throw HelperError(L("文件名不对")) }
        return (source, files)
    }

    // MARK: 内核

    /// 复制文件、启动内核、回应，把这个连接登记成租约。回应在锁里写，内核马上退出时的事件一定排在回应后面。
    private func start(_ params: [String: Any], id: Any?, client: Int32) throws -> Lease {
        let (source, files) = try fileList(params)
        guard files.contains("config.yaml") else { throw HelperError(L("少了 config.yaml")) }
        lock.lock()
        defer { lock.unlock() }
        stopCoreLocked()
        endLeaseLocked()
        try HelperFiles.copy(files, from: source, to: HelperPaths.coreDirectory, owner: allowedUID)
        try launchCoreLocked()
        let lease = Lease(fd: client)
        self.lease = lease
        reply(client, JSONRPC.result(id: id, ["pid": Int(process?.processIdentifier ?? 0), "core": coreVersion]))
        return lease
    }

    /// 租约：一直读到对方断开。断开时它还是当前的租约，就停掉内核。
    private func hold(_ lease: Lease) {
        UnixSocket.setTimeout(lease.fd, seconds: 0)
        var buffer = Data()
        while UnixSocket.readLine(lease.fd, buffer: &buffer, limit: 1 << 16) != nil {}
        lock.lock()
        if self.lease === lease {
            self.lease = nil
            stopCoreLocked()
        }
        lease.finished = true
        lock.unlock()
        close(lease.fd)
    }

    /// 让当前的租约结束：对方那头会读到断开。
    private func endLeaseLocked() {
        guard let lease else { return }
        self.lease = nil
        if !lease.finished {
            shutdown(lease.fd, Int32(SHUT_RDWR))
        }
    }

    private func launchCoreLocked() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: HelperPaths.core) else { throw HelperError(L("助手里没有内核，请重新安装助手")) }
        // 每次启动前都校验：只运行认可的内核。
        let hash = (try? Checksums.sha256(of: URL(fileURLWithPath: HelperPaths.core))) ?? ""
        guard CorePin.binarySHA256s.contains(hash) else {
            Self.log("内核的校验和不对（\(hash)），不启动")
            throw HelperError(L("助手里的内核校验和不对，请重新安装助手"))
        }
        unlink(HelperPaths.coreLog)
        // 内核日志里有访问过的网址：只给装助手的用户读（程序的「内核」页显示它）。
        guard fm.createFile(atPath: HelperPaths.coreLog, contents: nil, attributes: [.posixPermissions: 0o600]),
              chown(HelperPaths.coreLog, allowedUID, 0) == 0,
              let log = FileHandle(forWritingAtPath: HelperPaths.coreLog) else {
            throw HelperError(L("写不了内核日志"))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: HelperPaths.core)
        process.arguments = ["-d", HelperPaths.coreDirectory, "-f", HelperPaths.coreConfig]
        process.currentDirectoryURL = URL(fileURLWithPath: HelperPaths.coreDirectory)
        process.environment = ["HOME": "/var/root", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            self?.coreExited(finished)
        }
        do {
            try process.run()
        } catch {
            throw HelperError(L("内核启动失败：%@", error.localizedDescription))
        }
        self.process = process
        Self.log("内核已启动（\(process.processIdentifier)）")
    }

    private func coreExited(_ finished: Process) {
        lock.lock()
        defer { lock.unlock() }
        guard process === finished else { return }
        process = nil
        restoreForwardingLocked()
        let status = Int(finished.terminationStatus)
        Self.log("内核退出了，状态 \(status)")
        if let lease, !lease.finished {
            var event = JSONRPC.encode(["event": "exit", "status": status])
            event.append(0x0A)
            _ = UnixSocket.writeAll(lease.fd, event)
        }
    }

    private func stopCoreLocked() {
        restoreForwardingLocked()
        guard let process else { return }
        self.process = nil
        process.terminationHandler = nil
        guard process.isRunning else { return }
        // 先让内核自己退出（它会拆掉路由和虚拟网卡），等不及再强制结束。
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        Self.log("内核已停止")
    }

    // MARK: IP 转发

    private func enableForwardingLocked() throws {
        if savedForwarding == nil {
            let saved = ForwardingState(ipv4: Forwarding.read(Forwarding.ipv4Key) ?? 0, ipv6: Forwarding.read(Forwarding.ipv6Key) ?? 0)
            if let data = try? JSONEncoder().encode(saved) {
                FileManager.default.createFile(atPath: HelperPaths.forwardingState, contents: data, attributes: [.posixPermissions: 0o644])
            }
            savedForwarding = saved
        }
        guard Forwarding.write(Forwarding.ipv4Key, 1) else { throw HelperError(L("打不开 IP 转发")) }
        Forwarding.write(Forwarding.ipv6Key, 1)
    }

    private func restoreForwardingLocked() {
        guard let saved = savedForwarding else { return }
        Forwarding.write(Forwarding.ipv4Key, saved.ipv4)
        Forwarding.write(Forwarding.ipv6Key, saved.ipv6)
        savedForwarding = nil
        unlink(HelperPaths.forwardingState)
    }

    /// 上次意外退出时没恢复的 IP 转发。
    private func restoreLeftoverForwarding() {
        guard let data = FileManager.default.contents(atPath: HelperPaths.forwardingState), let saved = try? JSONDecoder().decode(ForwardingState.self, from: data) else { return }
        Forwarding.write(Forwarding.ipv4Key, saved.ipv4)
        Forwarding.write(Forwarding.ipv6Key, saved.ipv6)
        unlink(HelperPaths.forwardingState)
        Self.log("恢复了上次没恢复的 IP 转发设置")
    }

    // MARK: 其他

    /// launchd 停掉助手（卸载、关机）时：停内核、恢复 IP 转发再退出。
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { exit(0) }
                self.lock.lock()
                self.stopCoreLocked()
                self.endLeaseLocked()
                self.lock.unlock()
                unlink(HelperPaths.socket)
                Self.log("特权助手退出")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    static func peerUID(_ fd: Int32) -> UInt32? {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
        #else
        return nil
        #endif
    }

    static func readCoreVersion() -> String {
        // 和每次启动内核前一样，先核对校验和再运行它。
        guard (try? HelperInstaller.verifyCore(HelperPaths.core, removeIfWrong: false)) != nil,
              let result = try? Shell.runSync(HelperPaths.core, ["-v"], timeout: 10) else { return "" }
        return coreVersion(from: result.output) ?? ""
    }

    /// 以前的版本建的内核目录别人能读（里面的配置有控制接口的密钥、节点文件有服务器的密码）：
    /// 启动时收紧成目录只能穿过、文件只有 root 能读，内核日志给装助手的用户。
    static func tightenCoreDirectory(userID: UInt32) {
        let directory = HelperPaths.coreDirectory
        var info = stat()
        guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0 else { return }
        chmod(directory, 0o711)
        guard let items = FileManager.default.enumerator(atPath: directory) else { return }
        for case let relative as String in items {
            let path = (directory as NSString).appendingPathComponent(relative)
            guard lstat(path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                chmod(path, 0o700)
            case S_IFREG:
                if path == HelperPaths.coreLog {
                    chown(path, userID, 0)
                }
                chmod(path, 0o600)
            default:
                continue
            }
        }
    }

    /// 「Mihomo Meta v1.19.31 darwin arm64 …」里的版本号。
    static func coreVersion(from output: String) -> String? {
        guard let range = output.range(of: #"v\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    static func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        FileHandle.standardError.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8))
    }
}

// MARK: - 程序这一端

enum HelperClient {
    /// 装了助手（launchd 配置和程序文件都在）。
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HelperPaths.plist) && FileManager.default.fileExists(atPath: HelperPaths.executable)
    }

    static func openConnection(timeout: TimeInterval) throws -> Int32 {
        let fd = UnixSocket.makeSocket()
        guard fd >= 0 else { throw HelperError(L("建不了套接字")) }
        UnixSocket.disableSigpipe(fd)
        var (address, length) = try UnixSocket.address(HelperPaths.socket)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connected == 0 else {
            close(fd)
            throw HelperError(isInstalled ? L("特权助手没有在运行（可能在「系统设置 → 通用 → 登录项」里被关掉了）") : L("还没有安装特权助手"))
        }
        UnixSocket.setTimeout(fd, seconds: timeout)
        return fd
    }

    /// 发一条请求、等一行回应；fd 给了就用它（租约），否则新开一个连接用完就关。
    static func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 20, on existing: Int32? = nil) throws -> [String: Any] {
        let fd = try existing ?? openConnection(timeout: timeout)
        defer { if existing == nil { close(fd) } }
        var line = JSONRPC.encode(JSONRPC.request(id: 1, method: method, params: params))
        line.append(0x0A)
        guard UnixSocket.writeAll(fd, line) else { throw HelperError(L("发不出请求")) }
        var buffer = Data()
        guard let data = UnixSocket.readLine(fd, buffer: &buffer), let response = JSONRPC.decode(data) else {
            throw HelperError(L("特权助手没有回应"))
        }
        if let error = response["error"] as? [String: Any] {
            throw HelperError((error["message"] as? String) ?? L("特权助手出错了"))
        }
        return (response["result"] as? [String: Any]) ?? [:]
    }

    static func status(timeout: TimeInterval = 3) throws -> HelperStatus {
        HelperStatus(try request("status", timeout: timeout))
    }
}

/// 经助手运行的内核：和本机进程的 CoreRunner 用法一样。启动、停止、同步会阻塞，要放在后台线程调用。
final class HelperCoreRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: Lease?

    private final class Lease {
        let fd: Int32
        var finished = false
        init(fd: Int32) { self.fd = fd }
    }

    /// 内核自己退出了，或者和助手断开了（主线程）。
    var onExit: (@MainActor (Int32) -> Void)?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lease != nil
    }

    /// 请助手复制文件并启动内核；回应之后这个连接一直开着，断开就等于让助手停掉内核。
    func start(source: String, files: [String]) throws {
        stop()
        let fd = try HelperClient.openConnection(timeout: 60)
        do {
            _ = try HelperClient.request("start", params: ["source": source, "files": files], on: fd)
        } catch {
            close(fd)
            throw error
        }
        UnixSocket.setTimeout(fd, seconds: 0)
        let lease = Lease(fd: fd)
        lock.lock()
        self.lease = lease
        lock.unlock()
        Thread.detachNewThread { [weak self] in
            self?.watch(lease)
        }
    }

    private func watch(_ lease: Lease) {
        var buffer = Data()
        var status: Int32 = -1
        while let line = UnixSocket.readLine(lease.fd, buffer: &buffer, limit: 1 << 16) {
            if let event = JSONRPC.decode(line), event["event"] as? String == "exit" {
                status = Int32((event["status"] as? Int) ?? -1)
                break
            }
        }
        lock.lock()
        let current = self.lease === lease
        if current { self.lease = nil }
        lease.finished = true
        lock.unlock()
        close(lease.fd)
        if current {
            Task { @MainActor [weak self] in self?.onExit?(status) }
        }
    }

    /// 停掉内核：请助手停（它等内核真的退出才回应，端口这时已经空出来了），再结束租约。
    func stop() {
        lock.lock()
        let lease = self.lease
        self.lease = nil
        lock.unlock()
        guard let lease else { return }
        _ = try? HelperClient.request("stop", timeout: 15)
        lock.lock()
        if !lease.finished {
            shutdown(lease.fd, Int32(SHUT_RDWR))
        }
        lock.unlock()
    }

    func sync(source: String, files: [String]) throws {
        _ = try HelperClient.request("sync", params: ["source": source, "files": files], timeout: 60)
    }

    func setForwarding(_ enabled: Bool) throws {
        _ = try HelperClient.request("forwarding", params: ["enabled": enabled], timeout: 10)
    }

    /// 内核日志的最后几行（助手写的日志别人也能读）。
    var logTail: String {
        guard let data = FileManager.default.contents(atPath: HelperPaths.coreLog) else { return "" }
        let text = String(decoding: data.suffix(64 * 1024), as: UTF8.self)
        return text.split(separator: "\n").suffix(200).joined(separator: "\n")
    }
}

// MARK: - 命令行

/// `Proxi helper install|uninstall|run|status`：安装、卸载要 root（程序里经管理员授权运行，也可以 sudo），
/// run 是 launchd 启动守护进程用的。
enum HelperCommand {
    static func run(_ arguments: [String], appVersion: String, executable: String, bundledCore: String?) -> Int32 {
        guard let action = arguments.first else {
            print(usage)
            return 2
        }
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        do {
            switch action {
            case "install":
                guard let uid = option("--uid").flatMap(UInt32.init) ?? ProcessInfo.processInfo.environment["SUDO_UID"].flatMap(UInt32.init) else {
                    fail(L("不知道给哪个用户装：加上 --uid <用户 id>，或者用 sudo 运行"))
                    return 2
                }
                guard let core = option("--core") ?? bundledCore else {
                    fail(L("找不到内核（mihomo）"))
                    return 1
                }
                try HelperInstaller.install(uid: uid, appVersion: appVersion, executable: executable, core: core)
                print(L("特权助手已安装，只接受用户 %@ 的请求", uid))
                return 0
            case "uninstall":
                try HelperInstaller.uninstall()
                print(L("特权助手已卸载"))
                return 0
            case "run":
                guard geteuid() == 0 else {
                    fail(L("要以 root 运行"))
                    return 3
                }
                guard let uid = option("--uid").flatMap(UInt32.init) else {
                    fail(L("少了 --uid"))
                    return 2
                }
                HelperDaemon(uid: uid, appVersion: option("--version") ?? "").run()
            case "status":
                let status = try HelperClient.status()
                print(L("特权助手在运行：程序版本 %@，内核 %@，协议 %@", status.appVersion, status.coreVersion, status.protocolVersion) + (status.isCurrent ? "" : L("（和这个程序不一致，需要重新安装）")))
                print(status.running ? L("内核在运行") + (status.forwarding ? L("，IP 转发已打开") : "") : L("内核没在运行"))
                return status.isCurrent ? 0 : 1
            default:
                print(usage)
                return 2
            }
        } catch {
            // 专用 CI 账户需要确认拒绝的原因，不按会翻译或改写的错误文案判断。
            if ProcessInfo.processInfo.environment["PROXI_CI_DIAGNOSTICS"] == "1",
               let code = (error as? HelperError)?.diagnosticCode {
                FileHandle.standardError.write(Data("event=helper.reject reason=\(code)\n".utf8))
            }
            fail(error.localizedDescription)
            return 1
        }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data((L("proxi helper：") + message + "\n").utf8))
    }

    static var usage: String { AppLanguage.isEnglish ? usageEnglish : usageChinese }

    // l10n-ignore：中文界面的用法，英文的在 usageEnglish。
    static let usageChinese = """
    用法：
      sudo proxi helper install     安装特权助手（增强模式、网关模式要用）
      sudo proxi helper uninstall   卸载特权助手
      proxi helper status           查看特权助手的状态
    """

    static let usageEnglish = """
    Usage:
      sudo proxi helper install     Install the privileged helper (needed for enhanced mode and gateway mode)
      sudo proxi helper uninstall   Uninstall the privileged helper
      proxi helper status           Show the privileged helper's status
    """
}
