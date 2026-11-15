import XCTest
@testable import MarathonPlan

final class ScheduleTests: XCTestCase {
    private func plan(race: String = "2026-11-08") -> TrainingPlan {
        TrainingPlan.make(RaceSetting(raceName: "テスト", raceDateKey: race, startDateKey: "2026-07-06"))
    }

    func testSundayRaceIsNotScheduledOnSaturday() {
        let plan = plan()
        let sessions = TrainingSchedule.sessions(plan: plan, weekdays: [3, 5, 7])
        XCTAssertEqual(sessions.filter(\.isRace).map(\.date), [plan.race])
        XCTAssertFalse(sessions.contains { Plan.key(for: $0.date) == "2026-11-07" })
        XCTAssertEqual(sessions.suffix(3).map(\.title), plan.weeks.last?.runs)
    }

    func testRaceAndRestDayAreRespectedForEveryRaceWeekday() {
        for offset in 0..<7 {
            let race = Plan.calendar.date(byAdding: .day, value: offset, to: Plan.date(2026, 11, 2))!
            let plan = plan(race: Plan.key(for: race))
            let sessions = TrainingSchedule.sessions(plan: plan, weekdays: Set(1...7))
            XCTAssertEqual(sessions.filter(\.isRace).map(\.date), [race])
            let previousDay = Plan.calendar.date(byAdding: .day, value: -1, to: race)!
            // For Monday races the preceding Sunday belongs to the previous
            // week; the rest-day promise applies across that boundary too.
            XCTAssertFalse(sessions.contains { $0.date == previousDay })
            XCTAssertFalse(sessions.contains { $0.date > race })
        }
    }

    func testEveryWeekdayDoesNotMultiplyTrainingLoad() {
        let plan = plan()
        let sessions = TrainingSchedule.sessions(plan: plan, weekdays: Set(1...7))
        for week in plan.weeks.indices {
            XCTAssertLessThanOrEqual(sessions.filter { plan.weekIndex(of: $0.date) == week }.count, plan.weeks[week].runs.count)
        }
        XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count)
    }

    func testNoTrainingWeekdaysStillIncludesRace() {
        let sessions = TrainingSchedule.sessions(plan: plan(), weekdays: [])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].isRace)
    }

    func testChangingWeekdaysKeepsOriginalMenuIdentity() {
        let plan = plan()
        let original = TrainingSchedule.sessions(plan: plan, weekdays: [3, 5, 7])
        let changed = TrainingSchedule.sessions(plan: plan, weekdays: [2, 4, 6])
        XCTAssertEqual(Set(original.filter { !$0.isRace }.map(\.id)), Set(changed.filter { !$0.isRace }.map(\.id)))
        XCTAssertNotEqual(original.first?.date, changed.first?.date)
    }

    func testWednesdayRaceWithOnlyTuesdayAvailableDropsPractice() {
        let plan = plan(race: "2026-11-04")
        let raceWeek = TrainingSchedule.sessions(plan: plan, weekdays: [3]).filter { plan.weekIndex(of: $0.date) == plan.weeks.count - 1 }
        XCTAssertEqual(raceWeek.count, 1)
        XCTAssertTrue(raceWeek[0].isRace)
    }
}
