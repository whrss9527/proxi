import XCTest
@testable import Proxi

final class ConfigFormatTests: XCTestCase {
    private func config(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    private func object(_ config: AppConfig) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
    }

    func testLegacyConfigUpgradesAndUnknownTargetsRoundTrip() throws {
        let legacy = try config(#"{"profiles":[{"name":"旧配置"}]}"#)
        XCTAssertEqual(legacy.format, 2)
        XCTAssertEqual(legacy.profiles[0].targets, [.system])
        XCTAssertEqual(try object(legacy)["format"] as? Int, 2)
        let mixed = try config(#"{"profiles":[{"targets":["git","docker"]},{"targets":["docker"]},{"targets":[]}]}"#)
        XCTAssertEqual(mixed.profiles[0].targets, [.git])
        XCTAssertFalse(mixed.profiles[0].isUnsupported)
        XCTAssertEqual(mixed.profiles[1].unknownTargets, ["docker"])
        XCTAssertTrue(mixed.profiles[1].isUnsupported)
        XCTAssertNotNil(mixed.profiles[1].validate())
        XCTAssertTrue(mixed.profiles[2].targets.isEmpty)
        let reloaded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(mixed))
        XCTAssertEqual(reloaded, mixed)
    }

    func testFutureFieldsSurviveEditsReorderingAndDeletion() throws {
        let a = UUID(), b = UUID()
        var value = try config("""
        {"format":2,"future":{"null":null,"unsigned":18446744073709551615},"automation":{"futureRule":true},
         "profiles":[{"id":"\(a.uuidString)","name":"a","extra":{"deep":7}},
                     {"id":"\(b.uuidString)","name":"b","extra":[1,2]}]}
        """)
        value.profiles.reverse()
        value.profiles[1].name = "edited"
        var encoded = try object(value)
        let future = try XCTUnwrap(encoded["future"] as? [String: Any])
        XCTAssertTrue(future["null"] is NSNull)
        XCTAssertEqual((future["unsigned"] as? NSNumber)?.uint64Value, UInt64.max)
        XCTAssertEqual((encoded["automation"] as? [String: Any])?["futureRule"] as? Bool, true)
        var profiles = try XCTUnwrap(encoded["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles[0]["extra"] as? [Int], [1,2])
        XCTAssertEqual(profiles[1]["name"] as? String, "edited")
        XCTAssertEqual((profiles[1]["extra"] as? [String: Int])?["deep"], 7)
        value.profiles.removeLast()
        encoded = try object(value)
        profiles = try XCTUnwrap(encoded["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0]["id"] as? String, b.uuidString)
        let reloaded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(try object(reloaded)["future"] as? NSDictionary, future as NSDictionary)
    }

    func testGeneratedIdentitiesKeepFieldsWithoutDuplicatingProfiles() throws {
        var value = try config(#"{"profiles":[{"name":"missing","extra":1},"opaque",{"id":"broken","name":"invalid","extra":2},{"engine":true,"extra":3}]}"#)
        XCTAssertEqual(value.profiles.count, 2)
        value.profiles.reverse()
        let rows = try XCTUnwrap(try object(value)["profiles"] as? [Any])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual((rows[0] as? [String: Any])?["extra"] as? Int, 2)
        XCTAssertEqual(rows[1] as? String, "opaque")
        XCTAssertEqual((rows[2] as? [String: Any])?["extra"] as? Int, 1)
        let reloaded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(reloaded.profiles.map(\.id), value.profiles.map(\.id))
    }

    func testCloudMergeKeepsFutureFieldsFromBothMachines() throws {
        let a = UUID(), b = UUID()
        let local = try config("{\"format\":2,\"localFuture\":true,\"profiles\":[{\"id\":\"\(a.uuidString)\",\"name\":\"local\",\"localExtra\":1}]}")
        let cloud = try config("{\"format\":2,\"cloudFuture\":true,\"profiles\":[{\"id\":\"\(b.uuidString)\",\"name\":\"cloud\",\"cloudExtra\":2}]}")
        let merged = try object(local.merging(cloud: cloud))
        XCTAssertEqual(merged["localFuture"] as? Bool, true)
        XCTAssertEqual(merged["cloudFuture"] as? Bool, true)
        let rows = try XCTUnwrap(merged["profiles"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["cloudExtra"] as? Int, 2)
        XCTAssertEqual(rows[1]["localExtra"] as? Int, 1)
        // 不支持的配置都显示相同摘要，不能据此吞掉不同身份的条目。
        let unknownLocal = try config(#"{"profiles":[{"name":"future","host":"local","targets":["docker"]}]}"#)
        let unknownCloud = try config(#"{"profiles":[{"name":"future","host":"cloud","targets":["gradle"]}]}"#)
        XCTAssertEqual(unknownLocal.merging(cloud: unknownCloud).profiles.count, 2)
    }

    @MainActor
    func testSyncShowsFutureFormatErrorAndDoesNotApplyOrOverwrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(CloudFile.fileName)
        let future = Data(#"{"format":3,"config":{}}"#.utf8)
        try future.write(to: url)
        let sync = CloudSync(folder: folder)
        var applied = false
        sync.applyRemote = { _ in applied = true }
        defer { sync.disable() }
        await sync.enable()
        guard case .error(let message) = sync.status else { return XCTFail("未提示格式更新") }
        XCTAssertTrue(message.contains("Proxi"))
        XCTAssertFalse(sync.enabled)
        XCTAssertFalse(applied)
        XCTAssertEqual(try Data(contentsOf: url), future)
        sync.start(enabled: true)
        await sync.syncNow()
        XCTAssertFalse(applied)
        XCTAssertEqual(try Data(contentsOf: url), future)
        guard case .error = sync.status else { return XCTFail("同步覆盖了格式错误") }
    }

    func testFutureCloudFormatsAreRejectedBeforeContentAndNeverOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.json")
        for json in [#"{"format":3,"config":"unknown future layout"}"#,
                     #"{"format":2,"config":{"format":3}}"#] {
            let bytes = Data(json.utf8)
            try bytes.write(to: url)
            XCTAssertThrowsError(try CloudFile.read(at: url)) { error in
                guard case CloudFileError.newerFormat(3) = error else { return XCTFail("\(error)") }
            }
            let current = SyncedConfig(updatedAt: Date(), device: "test", config: AppConfig())
            XCTAssertThrowsError(try CloudFile.write(current, to: url))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        try CloudFile.requireSupportedFormat(Data(#"{"format":1,"config":{}}"#.utf8))
        try FileManager.default.removeItem(at: url)
        let current = SyncedConfig(updatedAt: Date(timeIntervalSince1970: 1), device: "test", config: AppConfig())
        try CloudFile.write(current, to: url)
        XCTAssertEqual(try CloudFile.read(at: url), current)
        let old = Data(#"{"updatedAt":"1970-01-01T00:00:01Z","device":"old","config":{}}"#.utf8)
        let decoded = try CloudFile.decoder.decode(SyncedConfig.self, from: old)
        XCTAssertEqual(decoded.format, 1)
        XCTAssertEqual(decoded.config.format, 2)
    }

    func testLegacyMigrationCannotReplaceFutureCloudConfig() throws {
        guard ProcessInfo.processInfo.environment[CloudFile.overrideVariable] == nil else {
            throw XCTSkip("测试环境覆盖了云端目录")
        }
        let drive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: drive) }
        let target = drive.appendingPathComponent(CloudFile.folderName).appendingPathComponent(CloudFile.fileName)
        let legacy = drive.appendingPathComponent(CloudFile.legacyFolderName).appendingPathComponent(CloudFile.fileName)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = Data(#"{"format":3,"config":{}}"#.utf8)
        try future.write(to: target)
        try CloudFile.write(SyncedConfig(updatedAt: Date(), device: "old", config: AppConfig()), to: legacy)
        XCTAssertFalse(CloudFile.migrateLegacyFolder(drive: drive))
        XCTAssertEqual(try Data(contentsOf: target), future)
    }

    func testFutureFieldsDoNotTriggerLegacyCleanup() throws {
        let bytes = Data(#"{"format":2,"futureSetting":true}"#.utf8)
        XCTAssertFalse(LegacyCleanup.inspect(configData: bytes, stateData: nil).hadLegacySettings)
        XCTAssertEqual(Set(try object(AppConfig()).keys), LegacyCleanup.knownConfigKeys)
    }

    @MainActor
    func testUnsupportedProfileCannotTouchBackendOrRequestPassword() throws {
        var profile = try config(#"{"profiles":[{"targets":["docker"]}]}"#).profiles[0]
        profile.hasPassword = true
        profile.username = "requires password"
        var value = AppConfig()
        value.profiles = [profile]
        value.notifyLevel = .none
        value.healthCheck = false
        let backend = AppliedTargetsTests.Backend()
        let state = AppState(config: value, persisted: PersistedState(), backend: backend, persists: false)
        state.turnOn(profile)
        XCTAssertFalse(state.busy)
        XCTAssertFalse(state.status.isOn)
        XCTAssertEqual(state.lastError, profile.validate())
        XCTAssertTrue(backend.calls.isEmpty)
    }
}
