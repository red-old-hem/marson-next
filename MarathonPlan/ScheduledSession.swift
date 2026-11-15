import Foundation

struct ScheduledSession: Identifiable, Equatable {
    let id: String
    let date: Date
    let title: String
    let isRace: Bool
}

/// Shared calendar for screens and notifications. Identity follows the original
/// template slot, so changing weekdays does not erase completion.
enum TrainingSchedule {
    static func sessions(plan: TrainingPlan, weekdays: Set<Int>) -> [ScheduledSession] {
        let calendar = Plan.calendar
        let validWeekdays = weekdays.intersection(1...7)
        return plan.weeks.enumerated().flatMap { weekIndex, week in
            let isRaceWeek = week.templateIndex == Plan.template.count - 1
            let candidates = plan.weekDates(weekIndex).filter { date in
                validWeekdays.contains(calendar.component(.weekday, from: date)) &&
                (calendar.dateComponents([.day], from: date, to: plan.race).day ?? 0) >= 2
            }
            let templateRuns = Plan.template[week.templateIndex].runs
            // Short race weeks remove leading practice menus, but preserve IDs.
            let slotOffset = isRaceWeek ? templateRuns.count - week.runs.count : 0
            let practiceRuns = isRaceWeek ? Array(week.runs.dropLast()) : week.runs
            let count = min(candidates.count, practiceRuns.count)
            let selectedRuns = isRaceWeek
                ? Array(practiceRuns.enumerated().suffix(count))
                : Array(practiceRuns.enumerated().prefix(count))
            let dates = spread(candidates, count: count)
            var result = zip(selectedRuns, dates).map { run, date in
                ScheduledSession(id: id(plan: plan, week: week, slot: slotOffset + run.offset),
                                 date: date, title: run.element, isRace: false)
            }
            if isRaceWeek, let title = week.runs.last {
                result.append(ScheduledSession(id: id(plan: plan, week: week, slot: templateRuns.count - 1),
                                               date: plan.race, title: title, isRace: true))
            }
            return result
        }.sorted { $0.date < $1.date }
    }

    private static func id(plan: TrainingPlan, week: WeekPlan, slot: Int) -> String {
        "\(Plan.key(for: plan.race))/\(week.templateIndex)/\(slot)"
    }

    /// Keep the menu count bounded and spread it over the available weekdays.
    private static func spread(_ dates: [Date], count: Int) -> [Date] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [dates[0]] }
        return (0..<count).map { index in
            dates[Int((Double(index) * Double(dates.count - 1) / Double(count - 1)).rounded())]
        }
    }
}
