import Foundation

@MainActor
final class TrackerStore: ObservableObject {
    @Published private(set) var logs: [String: RunLog] = [:] {
        didSet { persist() }
    }

    /// ユーザーが明示的に取り消したヘルスケア由来の日。同期で復活させない
    @Published private(set) var suppressedAutoDays: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(suppressedAutoDays), forKey: Self.suppressedKey) }
    }

    /// 大会日から生成された実行中のプラン。大会未設定でもプレースホルダが入る(weeks を空にしないため)
    @Published private(set) var plan: TrainingPlan
    @Published private(set) var hasRaceSetting: Bool

    private static let storageKey = "mt-data"
    private static let suppressedKey = "mt-hk-suppressed"
    private static let planKey = "mt-plan"

    init() {
        let setting = Self.loadSetting()
        hasRaceSetting = setting != nil
        plan = TrainingPlan.make(setting ?? RaceSetting.placeholder())

        suppressedAutoDays = Set(UserDefaults.standard.stringArray(forKey: Self.suppressedKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: RunLog].self, from: data) {
            let migrated = Self.migrateLegacyAutoLogs(decoded)
            logs = migrated
            // init 内の代入では didSet が呼ばれないので明示的に保存する
            if migrated != decoded { persist() }
        }
    }

    // MARK: - 大会設定

    private static func loadSetting() -> RaceSetting? {
        guard let data = UserDefaults.standard.data(forKey: planKey) else { return nil }
        return try? JSONDecoder().decode(RaceSetting.self, from: data)
    }

    /// 大会日を設定・変更する。ログには一切触れない。
    func setRace(name: String, date: Date) {
        let today = Plan.calendar.startOfDay(for: Date())
        let race = Plan.calendar.startOfDay(for: date)
        let start = TrainingPlan.resolveStart(race: race,
                                              existingStart: hasRaceSetting ? plan.start : nil,
                                              today: today)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let setting = RaceSetting(raceName: trimmed.isEmpty ? "フルマラソン" : trimmed,
                                  raceDateKey: Plan.key(for: race),
                                  startDateKey: Plan.key(for: start))
        if let data = try? JSONEncoder().encode(setting) {
            UserDefaults.standard.set(data, forKey: Self.planKey)
        }
        plan = TrainingPlan.make(setting)
        hasRaceSetting = true
    }

    /// 週の割り当てが変わるか(確認ダイアログの出し分け用)
    func planWouldShift(date: Date) -> Bool {
        guard hasRaceSetting, !logs.isEmpty else { return false }
        let today = Plan.calendar.startOfDay(for: Date())
        let race = Plan.calendar.startOfDay(for: date)
        let newStart = TrainingPlan.resolveStart(race: race, existingStart: plan.start, today: today)
        return newStart != plan.start || race != plan.race
    }

    /// 旧sync が km に入れていたヘルスケア由来の距離を autoKm へ移す。
    /// 条件自体が冪等なのでバージョンフラグは不要
    private static func migrateLegacyAutoLogs(_ raw: [String: RunLog]) -> [String: RunLog] {
        var out = raw
        for (k, var log) in raw where log.auto == true && log.autoKm == nil && log.km != nil {
            log.autoKm = log.km
            log.km = nil
            out[k] = log
        }
        return out
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(logs) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func key(for date: Date) -> String { Plan.key(for: date) }

    func log(on date: Date) -> RunLog? { logs[key(for: date)] }

    func record(_ log: RunLog, on date: Date) {
        suppressedAutoDays.remove(key(for: date))
        logs[key(for: date)] = log
    }

    func remove(on date: Date) {
        let k = key(for: date)
        if let log = logs[k], log.auto == true || log.autoKm != nil {
            suppressedAutoDays.insert(k)
        }
        logs.removeValue(forKey: k)
    }

    /// ヘルスケアの日次集計を取り込む。手動入力(type / menu / km / pains / feel)は変更しない。
    /// 毎回ソースから日単位で再計算するので冪等。workoutIDs は無駄な書き込みを避ける変更検知に使う。
    /// ワークアウトが存在する日しか走査しないため、権限剥奪や削除で既存の autoKm が消えることはない。
    @discardableResult
    func applyWorkouts(_ summaries: [WorkoutDaySummary]) -> Bool {
        var next = logs
        var changed = false

        for summary in summaries.sorted(by: { $0.date < $1.date }) {
            let k = key(for: summary.date)
            if suppressedAutoDays.contains(k) { continue }
            let ids = summary.workoutIDs.sorted()

            if var existing = next[k] {
                if (existing.workoutIDs ?? []) == ids,
                   existing.autoKm == summary.km,
                   existing.autoSeconds == summary.seconds {
                    continue
                }
                // type / menu / km / pains / feel は触らない。.mini も .rest も
                // ユーザーの申告のまま残し、距離と時間だけが正しくなる。
                // nil への降格もしない(距離なしワークアウトで既存値を失わないため)
                existing.autoKm = summary.km ?? existing.autoKm
                existing.autoSeconds = summary.seconds ?? existing.autoSeconds
                existing.workoutIDs = ids
                next[k] = existing
            } else {
                next[k] = RunLog(
                    type: .run,
                    menu: nextMenu(on: summary.date, in: next),
                    auto: true,
                    autoKm: summary.km,
                    autoSeconds: summary.seconds,
                    workoutIDs: ids
                )
            }
            changed = true
        }

        // 代入は1回だけ = 永続化も1回
        if changed { logs = next }
        return changed
    }

    // MARK: - 週の計算

    func weekIndex(of date: Date) -> Int { plan.weekIndex(of: date) }

    func weekDates(_ week: Int) -> [Date] { plan.weekDates(week) }

    // 以下3組は applyWorkouts が作業中の辞書を渡せるようスナップショット版を持つ。
    // 同一バッチで複数日を新規作成するとき、logs はまだ更新されていないため
    // 作業中の辞書を見ないと全日に同じメニューが割り当たってしまう。
    private func weekLogs(_ week: Int, in source: [String: RunLog]) -> [RunLog] {
        weekDates(week).compactMap { source[key(for: $0)] }
    }

    func weekLogs(_ week: Int) -> [RunLog] { weekLogs(week, in: logs) }

    func weekAchieved(_ week: Int) -> Bool { weekLogs(week).count >= 2 }

    func weekKm(_ week: Int) -> Double {
        weekLogs(week).compactMap(\.distanceKm).reduce(0, +)
    }

    /// 同名メニューが週に複数ある場合に対応した消化数
    private func menuDoneCounts(week: Int, in source: [String: RunLog]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for log in weekLogs(week, in: source) where log.type == .run {
            if let menu = log.menu { counts[menu, default: 0] += 1 }
        }
        return counts
    }

    func menuDoneCounts(week: Int) -> [String: Int] { menuDoneCounts(week: week, in: logs) }

    /// 直近のラン記録から連続する痛みを検出(休養記録は数えず、途切れさせもしない)。
    /// 最新のランが痛みなしなら警告なし。
    func painWarning() -> PainWarning? {
        let recentRuns = logs.sorted { $0.key > $1.key }
            .map(\.value)
            .filter { $0.type == .run || $0.type == .mini }
        guard let latest = recentRuns.first,
              let latestPains = latest.pains, !latestPains.isEmpty else { return nil }

        var worst: PainWarning?
        for part in latestPains {
            var count = 0
            for log in recentRuns {
                if (log.pains ?? []).contains(part) { count += 1 } else { break }
            }
            if count >= 2 && count > (worst?.count ?? 0) {
                worst = PainWarning(part: part, count: count)
            }
        }
        return worst
    }

    /// 既存の記録に痛み情報を後から追記・編集する
    func updatePains(_ pains: [BodyPart], on date: Date) {
        guard var log = logs[key(for: date)] else { return }
        log.pains = pains.isEmpty ? nil : pains
        logs[key(for: date)] = log
    }

    /// その日が属する週の未消化メニューのうち先頭のもの。
    /// プラン範囲外の日は nil(HealthKit がプラン開始前の記録を作ったとき
    /// W1 のメニュー名が付いてしまうのを防ぐ)
    private func nextMenu(on date: Date, in source: [String: RunLog]) -> String? {
        let week = weekIndex(of: date)
        guard plan.contains(week: week) else { return nil }
        let counts = menuDoneCounts(week: week, in: source)
        var seen: [String: Int] = [:]
        for run in plan.week(week).runs {
            seen[run, default: 0] += 1
            if counts[run, default: 0] < seen[run]! { return run }
        }
        return nil
    }

    /// 週のメニュー消化状況。完全一致を優先し、どのメニューにも一致しなかった
    /// ラン記録(自由ランや、大会日変更で古くなったメニュー名)は
    /// 上から順に未消化スロットへ充当する。
    func menuProgress(week: Int) -> [Bool] {
        let runs = plan.week(week).runs
        let counts = menuDoneCounts(week: week)
        var seen: [String: Int] = [:]
        var flags = runs.map { run -> Bool in
            seen[run, default: 0] += 1
            return counts[run, default: 0] >= seen[run]!
        }
        let matched = flags.filter { $0 }.count
        let loggedRuns = weekLogs(week).filter { $0.type == .run }.count
        var spare = max(0, loggedRuns - matched)
        for i in flags.indices where !flags[i] && spare > 0 {
            flags[i] = true
            spare -= 1
        }
        return flags
    }

    func nextMenu(on date: Date) -> String? { nextMenu(on: date, in: logs) }

    func streak(today: Date) -> Int {
        let cur = weekIndex(of: today)
        guard cur >= 0 else { return 0 }
        var count = 0
        var w = min(cur, plan.weekCount - 1)
        while w >= 0 {
            if weekAchieved(w) {
                count += 1
            } else if w != cur {
                break
            }
            w -= 1
        }
        return count
    }

    var totalRuns: Int { logs.values.filter { $0.type != .rest }.count }
}

// MARK: - 距離の集計

extension TrackerStore {
    func stat(week: Int) -> WeekStat {
        let weekPlan = plan.week(week)
        var actual = 0.0
        var timedKm = 0.0
        var timedSeconds = 0
        for log in weekLogs(week) {
            if let km = log.distanceKm { actual += km }
            // 時間の無いログを混ぜるとペースが壊れるので、揃っているものだけ足す
            if log.paceSecPerKm != nil, let km = log.distanceKm, let sec = log.durationSeconds {
                timedKm += km
                timedSeconds += sec
            }
        }
        return WeekStat(week: week, phase: weekPlan.phase, targetKm: weekPlan.km,
                        actualKm: (actual * 10).rounded() / 10,
                        timedKm: timedKm, timedSeconds: timedSeconds)
    }

    var weekStats: [WeekStat] { (0..<plan.weekCount).map { stat(week: $0) } }

    var totalKm: Double {
        (logs.values.compactMap(\.distanceKm).reduce(0, +) * 10).rounded() / 10
    }

    /// 全期間の平均ペース。距離と時間が揃ったログのみ
    var averagePaceSecPerKm: Double? {
        let timed = logs.values.compactMap { log -> (Double, Int)? in
            guard log.paceSecPerKm != nil,
                  let km = log.distanceKm, let sec = log.durationSeconds else { return nil }
            return (km, sec)
        }
        let km = timed.reduce(0.0) { $0 + $1.0 }
        let sec = timed.reduce(0) { $0 + $1.1 }
        guard km >= 1 else { return nil }
        return Double(sec) / km
    }
}
