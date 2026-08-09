import Foundation

/// UserDefaults に保存する最小の設定。
/// Date ではなく "yyyy-MM-dd" 文字列で持つ: Date は絶対時刻で保存されるため
/// タイムゾーンが変わると startOfDay が1日ずれる。ログのキーとも表現が揃う。
struct RaceSetting: Codable, Equatable {
    var raceName: String
    var raceDateKey: String
    /// 必ず月曜
    var startDateKey: String

    /// 大会日未設定のときの見た目用。weeks が空にならないことだけが目的
    static func placeholder() -> RaceSetting {
        let today = Plan.calendar.startOfDay(for: Date())
        let monday = TrainingPlan.monday(containing: today)
        let race = Plan.calendar.date(byAdding: .day, value: 17 * 7 + 6, to: monday)!
        return RaceSetting(raceName: "フルマラソン",
                           raceDateKey: Plan.key(for: race),
                           startDateKey: Plan.key(for: monday))
    }
}

/// 大会日から生成される「実行中のプラン」。
/// 値型なので @Published に置くだけで SwiftUI の再描画が効く。
struct TrainingPlan: Equatable {
    let raceName: String
    /// startOfDay 済み
    let race: Date
    /// プラン第1週の月曜。startOfDay 済み
    let start: Date
    /// 圧縮後の週。必ず1要素以上
    let weeks: [WeekPlan]

    var weekCount: Int { weeks.count }
    var isCompressed: Bool { weeks.count < Plan.template.count }

    /// プラン開始前は負値
    func weekIndex(of date: Date) -> Int {
        let cal = Plan.calendar
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: start),
                                      to: cal.startOfDay(for: date)).day ?? 0
        return Int(floor(Double(days) / 7.0))
    }

    func contains(week: Int) -> Bool { week >= 0 && week < weeks.count }

    /// 範囲外を丸めた週番号。weeks は必ず1要素以上なので安全
    func clamped(_ week: Int) -> Int { min(max(week, 0), weeks.count - 1) }

    func week(_ w: Int) -> WeekPlan { weeks[clamped(w)] }

    func weekDates(_ w: Int) -> [Date] {
        let cal = Plan.calendar
        let monday = cal.date(byAdding: .day, value: w * 7, to: start)!
        return (0..<7).map { cal.date(byAdding: .day, value: $0, to: monday)! }
    }

    func daysToRace(from date: Date) -> Int {
        Plan.calendar.dateComponents([.day],
                                     from: Plan.calendar.startOfDay(for: date),
                                     to: race).day ?? 0
    }

    /// 圧縮しているときだけ、正直に伝える文言を返す
    var compressionNote: String? {
        guard isCompressed else { return nil }
        if weekCount <= 6 {
            return "大会まで\(weekCount)週。本来18週かけるプランを大きく圧縮しています。距離目標はあくまで目安。きついと感じたらロング走の時間を2〜3割減らして構いません。完走を最優先に"
        }
        return "大会まで\(weekCount)週。18週プランを\(weekCount)週に圧縮しています。回復週が減るぶん、疲れが残る日は迷わず削ってください"
    }

    // MARK: - 生成

    /// その日を含む週の月曜 (startOfDay)。
    /// Calendar.dateInterval(of: .weekOfYear) は firstWeekday がロケール依存
    /// (ja_JP は日曜始まり)なので使わない。component(.weekday) は常に日=1 で安全。
    static func monday(containing date: Date) -> Date {
        let cal = Plan.calendar
        let day = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: day)   // 日=1 ... 土=7
        return cal.date(byAdding: .day, value: -((weekday + 5) % 7), to: day)!
    }

    static func weeksBetween(_ a: Date, _ b: Date) -> Int {
        (Plan.calendar.dateComponents([.day], from: a, to: b).day ?? 0) / 7
    }

    /// 大会日の設定・変更時に start を決める。
    /// 毎日 weekCount を再計算するとプランが毎週1週ずつ縮むので、start は一度確定したら動かさない。
    static func resolveStart(race: Date, existingStart: Date?, today: Date) -> Date {
        let cal = Plan.calendar
        let raceMonday = monday(containing: race)
        let thisMonday = monday(containing: today)

        // 未開始のプラン(start が未来)は無かったことにして今週から引き直す
        var candidate = existingStart.map { min($0, thisMonday) } ?? thisMonday
        // 大会が start より前なら大会週まで詰める(weeks を空にしないため)
        if candidate > raceMonday { candidate = raceMonday }

        let n = weeksBetween(candidate, raceMonday) + 1
        if n > Plan.template.count {
            candidate = cal.date(byAdding: .day,
                                 value: -(Plan.template.count - 1) * 7,
                                 to: raceMonday)!
        }
        return candidate
    }

    static func make(_ setting: RaceSetting) -> TrainingPlan {
        let cal = Plan.calendar
        let race = Plan.date(fromKey: setting.raceDateKey) ?? cal.startOfDay(for: Date())
        let start = Plan.date(fromKey: setting.startDateKey) ?? monday(containing: race)
        let raceMonday = monday(containing: race)
        let n = max(1, min(weeksBetween(start, raceMonday) + 1, Plan.template.count))
        let offset = cal.dateComponents([.day], from: raceMonday, to: race).day ?? 6

        return TrainingPlan(raceName: setting.raceName,
                            race: race,
                            start: start,
                            weeks: Plan.compressedWeeks(count: n, raceWeekdayOffset: offset))
    }
}
