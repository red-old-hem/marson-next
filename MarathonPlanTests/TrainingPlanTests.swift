import XCTest
@testable import MarathonPlan

final class TrainingPlanTests: XCTestCase {
    func testMondayContainingUsesMondayAsWeekStart() {
        XCTAssertEqual(Plan.key(for: TrainingPlan.monday(containing: Plan.date(2026, 8, 9))), "2026-08-03")
        XCTAssertEqual(Plan.key(for: TrainingPlan.monday(containing: Plan.date(2026, 8, 10))), "2026-08-10")
    }

    func testOneWeekPlanContainsOnlyRaceMenu() {
        let weeks = Plan.compressedWeeks(count: 1, raceWeekdayOffset: 0)

        XCTAssertEqual(weeks.count, 1)
        XCTAssertEqual(weeks[0].runs, ["本番 42.195km!"])
        XCTAssertEqual(weeks[0].km, 5)
    }

    func testCompressedPlanKeepsTwoTaperWeeks() {
        let weeks = Plan.compressedWeeks(count: 8, raceWeekdayOffset: 6)

        XCTAssertEqual(weeks.count, 8)
        XCTAssertEqual(weeks.suffix(2).map(\.templateIndex), [16, 17])
        XCTAssertEqual(weeks.last?.runs.last, "本番 42.195km!")
    }

    func testResolveStartNeverFallsAfterRaceWeek() {
        let race = Plan.date(2026, 8, 12)
        let start = TrainingPlan.resolveStart(race: race, existingStart: nil, today: Plan.date(2026, 8, 20))

        XCTAssertEqual(start, TrainingPlan.monday(containing: race))
    }

    func testPaceRequiresUsableDistanceAndDuration() {
        XCTAssertNil(RunLog(type: .run, km: 0.4, autoSeconds: 600).paceSecPerKm)
        XCTAssertEqual(RunLog(type: .run, km: 5, autoSeconds: 1_800).paceSecPerKm, 360)
    }

    func testBackupRoundTripsAllStoredValues() throws {
        let backup = TrackerBackup(version: 1,
                                    raceSetting: RaceSetting(raceName: "テスト大会", raceDateKey: "2026-11-08", startDateKey: "2026-07-06"),
                                    logs: ["2026-07-06": RunLog(type: .run, km: 6.5)],
                                    suppressedAutoDays: ["2026-07-07"],
                                    notificationSettings: NotificationSettings(enabled: true, runWeekdays: [2, 4], morningHour: 6, eveningEnabled: false, eveningHour: 21))

        let restored = try JSONDecoder().decode(TrackerBackup.self, from: JSONEncoder().encode(backup))

        XCTAssertEqual(restored.raceSetting?.raceName, "テスト大会")
        XCTAssertEqual(restored.logs["2026-07-06"]?.km, 6.5)
        XCTAssertEqual(restored.suppressedAutoDays, ["2026-07-07"])
        XCTAssertEqual(restored.notificationSettings.runWeekdays, [2, 4])
        XCTAssertEqual(restored.notificationSettings.morningHour, 6)
        XCTAssertFalse(restored.notificationSettings.eveningEnabled)
    }
}
