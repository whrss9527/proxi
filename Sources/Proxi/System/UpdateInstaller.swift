import CryptoKit
import Foundation

/// shasum -a 256 输出的校验文件：每行「哈希  文件名」。
enum ProxiChecksums {
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            var name = parts[1...].joined(separator: " ")
            if name.hasPrefix("*") {
                name.removeFirst()
            }
            result[name] = hash
        }
        return result
    }

    /// 分块读文件算 SHA-256，返回小写十六进制。
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 系统的「App Translocation」：带隔离标记、又没在访达里挪过位置的程序（比如在下载文件夹里直接打开的），
/// 会从一个只读的临时位置运行。用 Security 框架的函数判断，并找回它原来的位置。
enum Translocation {
    private typealias IsTranslocatedURL = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> UInt8
    private typealias CreateOriginalPathForURL = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    private static let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }

    static var available: Bool {
        symbol("SecTranslocateIsTranslocatedURL") != nil && symbol("SecTranslocateCreateOriginalPathForURL") != nil
    }

    static func isTranslocated(_ url: URL) -> Bool {
        if url.path.contains("/AppTranslocation/") {
            return true
        }
        guard let pointer = symbol("SecTranslocateIsTranslocatedURL") else { return false }
        let function = unsafeBitCast(pointer, to: IsTranslocatedURL.self)
        var translocated = false
        _ = function(url as CFURL, &translocated, nil)
        return translocated
    }

    /// 被搬走之前的位置，例如 ~/Downloads/Proxi.app。
    static func originalURL(of url: URL) -> URL? {
        guard let pointer = symbol("SecTranslocateCreateOriginalPathForURL") else { return nil }
        let function = unsafeBitCast(pointer, to: CreateOriginalPathForURL.self)
        guard let original = function(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return (original as URL).standardizedFileURL
    }
}

/// 更新装到哪里。
struct InstallPlan: Equatable {
    /// 新版本放在这里，也从这里重新打开。
    var target: URL
    /// 装好后移到废纸篓的旧程序（从下载文件夹这类地方搬进「应用程序」时）。
    var trashAfter: URL?
    /// 从临时位置搬进「应用程序」，而不是原地替换。
    var relocating: Bool

    /// 按路径比较：同一个 .app 的 URL 可能带或不带结尾的 /（取决于它当时在不在磁盘上）。
    static func == (a: InstallPlan, b: InstallPlan) -> Bool {
        a.target.standardizedFileURL.path == b.target.standardizedFileURL.path
            && a.trashAfter?.standardizedFileURL.path == b.trashAfter?.standardizedFileURL.path
            && a.relocating == b.relocating
    }
}

/// 平时原地替换；从只读的临时位置运行时（系统搬走了、或者在只读的磁盘上），装进「应用程序」。
enum InstallLocation {
    static let appName = "Proxi.app"
    /// 测试用：当作从临时位置运行，原来的位置就是现在这个。
    static let testTranslocatedVariable = "PROXI_TEST_TRANSLOCATED"

    static var applicationsFolders: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    static func current(bundle: URL = Bundle.main.bundleURL) -> InstallPlan? {
        let testing = ProcessInfo.processInfo.environment[testTranslocatedVariable] == "1"
        let translocated = testing || Translocation.isTranslocated(bundle)
        let original = testing ? bundle.standardizedFileURL : (translocated ? Translocation.originalURL(of: bundle) : nil)
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return plan(bundle: bundle, translocated: translocated, original: original, readOnly: readOnly, folders: applicationsFolders, canWrite: canWrite)
    }

    /// 纯逻辑，便于测试。folders 按优先顺序，canWrite 判断能不能不用管理员密码写进去。
    static func plan(bundle: URL, translocated: Bool, original: URL?, readOnly: Bool, folders: [URL], canWrite: (URL) -> Bool) -> InstallPlan? {
        guard bundle.pathExtension == "app" else { return nil }
        guard translocated || readOnly else {
            return InstallPlan(target: bundle, trashAfter: nil, relocating: false)
        }
        if let original {
            let parent = original.deletingLastPathComponent().standardizedFileURL.path
            if folders.contains(where: { $0.standardizedFileURL.path == parent }) {
                // 本来就在「应用程序」里，只是带着隔离标记被系统搬到临时位置运行：原地替换。
                return InstallPlan(target: original, trashAfter: nil, relocating: false)
            }
        }
        guard let first = folders.first else { return nil }
        let folder = folders.first(where: canWrite) ?? first
        let target = folder.appendingPathComponent(appName, isDirectory: true).standardizedFileURL
        let trash = original.flatMap { $0.standardizedFileURL.path == target.path ? nil : $0 }
        return InstallPlan(target: target, trashAfter: trash, relocating: true)
    }

    /// 不用管理员密码能不能写：文件夹存在时看它本身，不存在时看能不能建出来。
    static func canWrite(_ folder: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue && fm.isWritableFile(atPath: folder.path)
        }
        return fm.isWritableFile(atPath: folder.deletingLastPathComponent().path)
    }

    /// 界面上怎么称呼这个文件夹。
    static func displayName(of folder: URL) -> String {
        let path = folder.standardizedFileURL.path
        if path == "/Applications" { return L("「应用程序」") }
        if path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL.path {
            return L("个人的「应用程序」（~/Applications）")
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

/// 改名前程序叫 ProxySwitch.app。旧版本的一键更新把新程序原地装在那里，新程序第一次启动时把自己改名为 Proxi.app 再重新打开。
enum BundleRename {
    static let legacyName = "ProxySwitch.app"
    /// 改名时登录项是开着的：从新位置启动后重新登记一次，让登录项指向新位置。
    static let loginItemKey = "rename.loginItem"

    /// 改到哪里（纯逻辑，便于测试）：名字是旧的、同一个文件夹里还没有 Proxi.app 时才改。
    static func target(for bundle: URL, exists: (URL) -> Bool) -> URL? {
        guard bundle.lastPathComponent == legacyName else { return nil }
        let target = bundle.deletingLastPathComponent().appendingPathComponent(InstallLocation.appName, isDirectory: true)
        return exists(target) ? nil : target
    }

    /// 改好了、已经安排好重新打开时返回 true，调用方接着退出。
    /// 改不了（被系统搬到临时位置运行、在只读的磁盘上、没有写权限）就照旧运行，只是名字还是旧的。
    static func renameIfNeeded(bundle: URL = Bundle.main.bundleURL, loginItemEnabled: () -> Bool) -> Bool {
        let fm = FileManager.default
        guard let target = target(for: bundle, exists: { fm.fileExists(atPath: $0.path) }),
              !Translocation.isTranslocated(bundle) else {
            return false
        }
        let wasLoginItem = loginItemEnabled()
        do {
            try fm.moveItem(at: bundle, to: target)
        } catch {
            Log.info("程序没能改名为 \(target.lastPathComponent)：\(error.localizedDescription)。照旧运行")
            return false
        }
        if wasLoginItem {
            UserDefaults.standard.set(true, forKey: loginItemKey)
        }
        Log.info("程序已改名：\(bundle.path) → \(target.path)，重新打开")
        UpdateInstaller.relaunch(target)
        return true
    }
}

/// 下载、校验、解压、替换、重新启动。除了 relaunch 都是异步的，不阻塞界面。
enum UpdateInstaller {
    static let dittoPath = "/usr/bin/ditto"
    static let xattrPath = "/usr/bin/xattr"
    static let codesignPath = "/usr/bin/codesign"

    /// 经 route 下载到 destination，progress 收到 0…1 的进度（总大小未知时是 nil）。
    static func download(_ url: URL, expectedSize: Int?, to destination: URL, route: NetworkRoute, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, expectedSize: expectedSize, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        // 30 秒没有任何数据才算超时；整个下载最长一小时（慢网络下几十 MB 也够）。
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        route.apply(to: configuration)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.completion = { result in continuation.resume(with: result) }
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// 下载校验文件（依次试各条线路）并比对压缩包的 SHA-256。
    static func verify(archive: URL, checksumsURL: URL, routes: [NetworkRoute]) async throws {
        var text: String?
        var lastError: Error = UpdateError.badResponse
        for route in routes {
            do {
                text = try await fetchText(checksumsURL, route: route)
                break
            } catch {
                Log.info("经\(route.title)下载校验文件失败：\(error.localizedDescription)")
                lastError = error
            }
        }
        guard let text else { throw lastError }
        let expected = ProxiChecksums.parse(text)
        guard let hash = expected[archive.lastPathComponent] else { throw UpdateError.checksumsMissing }
        let actual = try ProxiChecksums.sha256(of: archive)
        guard actual == hash else { throw UpdateError.checksumMismatch }
    }

    private static func fetchText(_ url: URL, route: NetworkRoute) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        route.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.server(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 解压到 directory，返回里面的 .app。
    static func extract(archive: URL, to directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await Shell.run(dittoPath, ["-x", "-k", archive.path, directory.path], timeout: 120)
        guard result.succeeded else { throw UpdateError.extract(result.trimmedOutput) }
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard let app = items.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.appNotFound }
        // 自己下载并校验过的更新，去掉隔离标记，否则换上去之后系统会再拦一次，还会被搬到临时位置运行。
        _ = try? await Shell.run(xattrPath, ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// 确认解压出来的确实是对应版本的 Proxi，签名完整；
    /// 当前版本是开发者签名的（requiredTeam 不是 nil）时，新版本也必须是同一个开发者签的。
    /// expectedIdentifier：要求的 bundle identifier，默认和自己的一样（扩展「代理引擎」用它自己的）。
    static func validate(app: URL, expectedVersion: String, expectedIdentifier: String? = Bundle.main.bundleIdentifier, requiredTeam: String? = CodeSignature.currentTeam) async throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateError.wrongApp(L("读不到 Info.plist"))
        }
        let identifier = plist["CFBundleIdentifier"] as? String ?? ""
        if let ours = expectedIdentifier, identifier != ours {
            throw UpdateError.wrongApp(L("bundle identifier 是 %@", identifier))
        }
        let version = plist["CFBundleShortVersionString"] as? String ?? ""
        guard version == expectedVersion else {
            throw UpdateError.wrongApp(L("版本是 %@，不是 %@", version, expectedVersion))
        }
        let result = try await Shell.run(codesignPath, ["--verify", "--deep", "--strict", app.path], timeout: 120)
        guard result.succeeded else { throw UpdateError.wrongApp(L("签名校验失败：%@", result.trimmedOutput)) }
        if let requiredTeam, !CodeSignature.isSigned(app, byTeam: requiredTeam) {
            let found = CodeSignature.teamIdentifier(of: app) ?? L("没有开发者签名")
            Log.error("新版本的签名不是 \(requiredTeam)（是 \(found)），不安装")
            throw UpdateError.wrongSigner(requiredTeam)
        }
    }

    /// 把 newApp 放到 target：先挪到同一个文件夹里的隐藏名字，旧的（有的话）挪开，再改名，失败就换回去。
    /// target 所在文件夹没有写权限（标准账户装在「应用程序」里）时，用系统的授权对话框以管理员身份做同样的事。
    static func install(newApp: URL, replacing target: URL) async throws {
        let parent = target.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".\(target.lastPathComponent).update")
        let backup = parent.appendingPathComponent(".\(target.lastPathComponent).previous")
        do {
            try swap(newApp: newApp, target: target, staged: staged, backup: backup)
        } catch let error as NSError where isBlockedBySystem(error) {
            Log.error("替换程序被系统拒绝：\(error.localizedDescription)")
            throw UpdateError.appManagement
        } catch let error as NSError where needsAdmin(error) {
            Log.info("替换程序需要管理员权限，改用授权对话框（\(error.localizedDescription)）")
            let source = FileManager.default.fileExists(atPath: staged.path) ? staged : newApp
            try await swapPrivileged(source: source, target: target, staged: staged, backup: backup)
        } catch {
            throw UpdateError.install(error.localizedDescription)
        }
    }

    private static func swap(newApp: URL, target: URL, staged: URL, backup: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: newApp, to: staged)
        let hadTarget = fm.fileExists(atPath: target.path)
        if hadTarget {
            try fm.moveItem(at: target, to: backup)
        }
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            if hadTarget {
                try? fm.moveItem(at: backup, to: target)
            }
            throw error
        }
        if hadTarget {
            try? fm.removeItem(at: backup)
        }
    }

    private static func swapPrivileged(source: URL, target: URL, staged: URL, backup: URL) async throws {
        let q = Shell.shellQuote
        let (s, t, b) = (q(staged.path), q(target.path), q(backup.path))
        let script = "rm -rf \(s) \(b) && mkdir -p \(q(target.deletingLastPathComponent().path)) && mv \(q(source.path)) \(s)"
            + " && { [ ! -e \(t) ] || mv \(t) \(b); }"
            + " && { mv \(s) \(t) || { [ ! -e \(b) ] || mv \(b) \(t); exit 1; }; }"
            + " && rm -rf \(b)"
        let appleScript = "do shell script " + Shell.appleScriptString(script) + " with administrator privileges"
        let result = try await Shell.run(SystemProxy.osascriptPath, ["-e", appleScript], timeout: 300)
        guard result.succeeded else {
            let text = result.trimmedOutput
            if text.contains("-128") {
                throw UpdateError.cancelledByUser
            }
            if text.localizedCaseInsensitiveContains("Operation not permitted") {
                throw UpdateError.appManagement
            }
            throw UpdateError.install(text)
        }
    }

    /// 错误里的 POSIX 错误码（FileManager 的错误通常包着一层）。
    static func posixCode(_ error: NSError) -> Int? {
        if error.domain == NSPOSIXErrorDomain {
            return error.code
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return posixCode(underlying)
        }
        return nil
    }

    /// 没有写权限（EACCES）：管理员身份可以做。
    static func needsAdmin(_ error: NSError) -> Bool {
        if let code = posixCode(error) {
            return code == Int(EACCES)
        }
        return error.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code)
    }

    /// 系统保护（EPERM，比如「App 管理」权限）：管理员身份也做不了。
    static func isBlockedBySystem(_ error: NSError) -> Bool {
        posixCode(error) == Int(EPERM)
    }

    /// 等当前进程退出后再打开新程序：起一个独立的 sh 等着，自己退出时它不受影响。
    static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "n=0; while /bin/kill -0 \(pid) 2>/dev/null && [ $n -lt 300 ]; do /bin/sleep 0.2; n=$((n+1)); done; /usr/bin/open \(Shell.shellQuote(app.path))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.error("启动重新打开程序的辅助进程失败：\(error)")
        }
    }
}

/// 把 URLSession 的下载回调接到 async 调用上，顺便报告进度。
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let expectedSize: Int?
    let progress: @Sendable (Double?) -> Void
    var completion: ((Result<Void, Error>) -> Void)?

    init(destination: URL, expectedSize: Int?, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }

    private func finish(_ result: Result<Void, Error>) {
        completion?(result)
        completion = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        var total = totalBytesExpectedToWrite
        if total <= 0, let expectedSize, expectedSize > 0 {
            total = Int64(expectedSize)
        }
        progress(total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateError.server(http.statusCode)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            finish(.failure(UpdateError.badResponse))
            return
        }
        if (error as? URLError)?.code == .cancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }
}
