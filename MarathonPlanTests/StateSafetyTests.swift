import XCTest
@testable import MarathonPlan

final class StateSafetyTests: XCTestCase {
    private let race = RaceSetting(raceName: "テスト大会", raceDateKey: "2026-11-08", startDateKey: "2026-07-06")

    private func backup(version: Int = 2, race: RaceSetting? = nil,
                        logs: [String: RunLog] = [:],
                        notifications: NotificationSettings = .init(),
                        painChecks: [String: [BodyPart]]? = nil) -> TrackerBackup {
        TrackerBackup(version: version, raceSetting: race ?? self.race, logs: logs,
                      suppressedAutoDays: [], notificationSettings: notifications,
                      painChecks: painChecks)
    }

    private func temporaryRepository() -> TrackerRepository {
        TrackerRepository(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("MarathonPlan-StateSafety-\(UUID().uuidString)", isDirectory: true))
    }

    @MainActor
    private func withStore(_ initial: TrackerBackup? = nil,
                           _ body: (TrackerStore, TrackerRepository) throws -> Void) throws {
        let repository = temporaryRepository()
        let suite = "MarathonPlan.StateSafety.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: repository.directory)
        }
        if let initial { try repository.save(initial) }
        let store = TrackerStore(repository: repository, defaults: defaults)
        try body(store, repository)
    }

    func testDecoderRejectsHugeFiniteDistancesInBothDistanceFields() throws {
        for log in [RunLog(type: .run, km: 1e308), RunLog(type: .run, autoKm: 1e308)] {
            let data = try JSONEncoder().encode(backup(logs: ["2026-07-07": log]))
            XCTAssertThrowsError(try BackupCodec.decode(data))
        }
        XCTAssertFalse(BackupCodec.validDistance(.infinity))
        XCTAssertFalse(BackupCodec.validDistance(.nan))
        XCTAssertEqual(Format.km(1e308), "—")
        XCTAssertEqual(Format.pace(.infinity), "—")
    }

    func testDecoderRejectsImpossibleAndNonCanonicalDays() throws {
        for key in ["2026-02-30", "2026-13-01", "2026-7-07", "1899-12-31", "2201-01-01"] {
            let data = try JSONEncoder().encode(backup(logs: [key: RunLog(type: .run)]))
            XCTAssertThrowsError(try BackupCodec.decode(data), key)
        }
        let invalidPain = backup(painChecks: ["2026-02-30": [.knee]])
        XCTAssertThrowsError(try BackupCodec.decode(JSONEncoder().encode(invalidPain)))
    }

    func testDecoderRejectsNonMondayStartAndOutOfRangePlans() throws {
        for start in ["2026-07-07", "2026-06-29", "2026-11-09"] {
            let setting = RaceSetting(raceName: "テスト大会", raceDateKey: "2026-11-08", startDateKey: start)
            XCTAssertThrowsError(try BackupCodec.decode(JSONEncoder().encode(backup(race: setting))), start)
        }
        XCTAssertNoThrow(try BackupCodec.decode(JSONEncoder().encode(backup())))
    }

    func testDecoderValidatesNotificationWeekdaysAndHours() throws {
        var settings = NotificationSettings()
        let invalid: [NotificationSettings] = [
            { settings.runWeekdays = [0, 3]; return settings }(),
            { settings = .init(); settings.runWeekdays = [8]; return settings }(),
            { settings = .init(); settings.morningHour = -1; return settings }(),
            { settings = .init(); settings.morningHour = 24; return settings }(),
            { settings = .init(); settings.eveningHour = -1; return settings }(),
            { settings = .init(); settings.eveningHour = 24; return settings }()
        ]
        for value in invalid {
            XCTAssertThrowsError(try BackupCodec.decode(JSONEncoder().encode(backup(notifications: value))))
        }
        let boundaries = NotificationSettings(enabled: true, runWeekdays: [], morningHour: 0,
                                               eveningEnabled: true, eveningHour: 23)
        XCTAssertNoThrow(try BackupCodec.decode(JSONEncoder().encode(backup(notifications: boundaries))))
    }

    func testVersionOneWithoutNewOptionalFieldsStillDecodes() throws {
        let data = Data("""
        {"version":1,"raceSetting":{"raceName":"旧データ","raceDateKey":"2026-11-08","startDateKey":"2026-07-06"},
         "logs":{"2026-07-07":{"type":"run","km":5,"pains":["knee"]}},
         "suppressedAutoDays":[],"notificationSettings":{"enabled":true,"runWeekdays":[3,5,7],
         "morningHour":7,"eveningEnabled":true,"eveningHour":20}}
        """.utf8)
        let decoded = try BackupCodec.decode(data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertNil(decoded.painChecks)
        XCTAssertNil(decoded.logs["2026-07-07"]?.sessionID)
        XCTAssertEqual(decoded.logs["2026-07-07"]?.km, 5)
    }

    func testRepositoryPreservesPriorSnapshotAndRejectsInvalidReplacement() throws {
        let repository = temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repository.directory) }
        let original = backup(logs: ["2026-07-07": RunLog(type: .run, km: 5)])
        let replacement = backup(logs: ["2026-07-09": RunLog(type: .mini)])
        try repository.save(original)
        XCTAssertFalse(repository.canUndoRestore)
        try repository.save(replacement, preservingCurrent: true)
        XCTAssertEqual(try repository.load()?.logs, replacement.logs)
        XCTAssertEqual(try BackupCodec.decode(repository.previousData()).logs, original.logs)
        let previous = try repository.previousData()

        let invalid = backup(logs: ["2026-07-10": RunLog(type: .run, km: -1)])
        XCTAssertThrowsError(try repository.save(invalid, preservingCurrent: true))
        XCTAssertEqual(try repository.load()?.logs, replacement.logs)
        XCTAssertEqual(try repository.previousData(), previous)

        try repository.save(BackupCodec.decode(previous))
        XCTAssertEqual(try repository.load()?.logs, original.logs)
    }

    @MainActor
    func testRestoreAndUndoRestoreAllStateInMemoryAndOnDisk() async throws {
        let original = backup(logs: ["2026-07-07": RunLog(type: .run, km: 5)],
                              painChecks: ["2026-07-07": [.knee]])
        try withStore(original) { store, repository in
            let replacementRace = RaceSetting(raceName: "別の大会", raceDateKey: "2026-10-18", startDateKey: "2026-07-06")
            let notifications = NotificationSettings(enabled: false, runWeekdays: [2], morningHour: 8,
                                                       eveningEnabled: false, eveningHour: 21)
            let replacement = TrackerBackup(version: 2, raceSetting: replacementRace,
                                             logs: ["2026-07-09": RunLog(type: .mini)],
                                             suppressedAutoDays: ["2026-07-10"],
                                             notificationSettings: notifications,
                                             painChecks: ["2026-07-09": []])
            try store.restoreBackupData(JSONEncoder().encode(replacement))
            XCTAssertEqual(store.logs, replacement.logs)
            XCTAssertEqual(store.suppressedAutoDays, replacement.suppressedAutoDays)
            XCTAssertEqual(store.notificationSettings, notifications)
            XCTAssertEqual(store.painChecks, replacement.painChecks)
            XCTAssertEqual(store.plan.raceName, replacementRace.raceName)
            XCTAssertTrue(store.canUndoRestore)
            try store.undoRestore()
            XCTAssertEqual(store.logs, original.logs)
            XCTAssertEqual(store.painChecks, original.painChecks)
            XCTAssertEqual(store.plan.raceName, race.raceName)
            XCTAssertEqual(store.notificationSettings, original.notificationSettings)
            XCTAssertTrue(store.suppressedAutoDays.isEmpty)
            XCTAssertEqual(try repository.load()?.logs, original.logs)
        }
    }

    @MainActor
    func testFailedRestoreDoesNotChangeMemoryDiskOrUndoSnapshot() async throws {
        try withStore(backup(logs: ["2026-07-07": RunLog(type: .run, km: 5)])) { store, repository in
            try store.restoreBackupData(JSONEncoder().encode(backup(logs: ["2026-07-09": RunLog(type: .mini)])))
            let before = try store.exportBackupData()
            let previous = try repository.previousData()
            let invalid = backup(logs: ["2026-02-30": RunLog(type: .run)])
            XCTAssertThrowsError(try store.restoreBackupData(JSONEncoder().encode(invalid)))
            let after = try BackupCodec.decode(store.exportBackupData())
            let expected = try BackupCodec.decode(before)
            XCTAssertEqual(after.logs, expected.logs)
            XCTAssertEqual(after.raceSetting, expected.raceSetting)
            XCTAssertEqual(after.notificationSettings, expected.notificationSettings)
            XCTAssertEqual(after.painChecks, expected.painChecks)
            XCTAssertEqual(try repository.load()?.logs, expected.logs)
            XCTAssertEqual(try repository.previousData(), previous)
        }
    }

    @MainActor
    func testUnknownPainChecksDoNotClearWarningButExplicitNoPainDoes() async throws {
        try withStore(backup()) { store, _ in
            store.record(RunLog(type: .run, pains: [.knee]), on: Plan.date(2026, 7, 7))
            store.record(RunLog(type: .run, pains: [.knee]), on: Plan.date(2026, 7, 9))
            XCTAssertEqual(store.painWarning(), PainWarning(part: .knee, count: 2))
            store.record(RunLog(type: .mini), on: Plan.date(2026, 7, 10))
            store.applyWorkouts([WorkoutDaySummary(date: Plan.date(2026, 7, 11), km: 3,
                                                   seconds: 1_200, workoutIDs: ["unknown-pain"])])
            XCTAssertNil(store.painChecks["2026-07-11"])
            XCTAssertEqual(store.painWarning(), PainWarning(part: .knee, count: 2))
            store.updatePains([], on: Plan.date(2026, 7, 12))
            XCTAssertNil(store.painWarning())
            XCTAssertEqual(store.painChecks["2026-07-12"], [])
            XCTAssertNil(store.log(on: Plan.date(2026, 7, 12)))
        }
    }

    @MainActor
    func testLegacyPainAnswersMigrateWithoutTreatingUnknownAsNoPain() async throws {
        let legacy = backup(version: 1, logs: [
            "2026-07-07": RunLog(type: .run, pains: [.shin]),
            "2026-07-09": RunLog(type: .run, pains: [.shin]),
            "2026-07-11": RunLog(type: .run, auto: true)
        ])
        try withStore(legacy) { store, _ in
            XCTAssertNil(store.painChecks["2026-07-11"])
            XCTAssertEqual(store.painWarning(), PainWarning(part: .shin, count: 2))
        }
    }

    @MainActor
    func testImportedAndFreeRunsAchieveActivityWithoutCompletingPlannedSessions() async throws {
        try withStore(backup()) { store, _ in
            store.applyWorkouts([WorkoutDaySummary(date: Plan.date(2026, 7, 7), km: 2,
                                                   seconds: 900, workoutIDs: ["workout"])])
            store.record(RunLog(type: .run, km: 1), on: Plan.date(2026, 7, 9))
            XCTAssertTrue(store.weekAchieved(0))
            XCTAssertTrue(store.menuProgress(week: 0).allSatisfy { !$0 })
            XCTAssertNil(store.log(on: Plan.date(2026, 7, 7))?.sessionID)
            let session = try XCTUnwrap(store.sessions(week: 0).first)
            store.confirmSession(session.id, on: Plan.date(2026, 7, 7))
            XCTAssertTrue(store.isSessionCompleted(session.id))
            store.applyWorkouts([WorkoutDaySummary(date: Plan.date(2026, 7, 7), km: 3,
                                                   seconds: 1_200, workoutIDs: ["workout", "second"])])
            XCTAssertTrue(store.isSessionCompleted(session.id))
            XCTAssertEqual(store.menuProgress(week: 0).filter { $0 }.count, 1)
        }
    }

    @MainActor
    func testNotificationChangeDoesNotRegeneratePlanOrLoseRecords() async throws {
        try withStore(backup(logs: ["2026-07-07": RunLog(type: .run, km: 5)])) { store, repository in
            let originalPlan = store.plan
            let originalLogs = store.logs
            let settings = NotificationSettings(enabled: false, runWeekdays: [2, 4], morningHour: 6,
                                                 eveningEnabled: false, eveningHour: 22)
            store.setNotificationSettings(settings)
            XCTAssertEqual(store.plan, originalPlan)
            XCTAssertEqual(store.logs, originalLogs)
            XCTAssertEqual(try repository.load()?.raceSetting, race)
            XCTAssertEqual(try repository.load()?.notificationSettings, settings)
        }
    }
}
