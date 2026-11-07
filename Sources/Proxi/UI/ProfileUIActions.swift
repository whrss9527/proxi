import Foundation

/// 配置界面的外部操作。默认使用生产实现，离线预览可替换网络和密码访问。
struct ProfileUIActions {
    var readPassword: @MainActor (UUID) -> String? = { ProxyKeychain.password(for: $0) }
    var savePassword: @MainActor (String, UUID) throws -> Void = { try ProxyKeychain.set($0, for: $1) }
    var deletePassword: @MainActor (UUID) -> Void = { ProxyKeychain.delete(for: $0) }
    var removeProfile: @MainActor (AppState, Profile) -> Void = { $0.remove($1) }
    var test: @MainActor (Profile, String, String) async -> TestResult = {
        await ProxyTester.test(profile: $0, password: $1, testURL: $2)
    }
    var detect: @MainActor (String) async -> [DetectedProxy] = { await LocalProxyDetector.detect(testURL: $0) }
}
