import Foundation
import Combine

@MainActor
final class TrackerStore: ObservableObject {
    @Published private(set) var logs: [String: RunLog] = [:] {
        didSet { persist() }
    }

    /// ユーザーが明示的に取り消したヘルスケア由来の日。同期で復活させない
    @Published private(set) var suppressedAutoDays: Set<String> = [] {
        didSet { persist() }
    }

    /// 大会日から生成された実行中のプラン。大会未設定でもプレースホルダが入る(weeks を空にしないため)
    @Published private(set) var plan: TrainingPlan
    @Published private(set) var hasRaceSetting: Bool
    @Published private(set) var notificationSettings: NotificationSettings = .init() {
        didSet { persist() }
    }
    @Published private(set) var painChecks: [String: [BodyPart]] = [:] { didSet { persist() } }
    @Published var storageMessage: String?
    @Published private(set) var canUndoRestore = false
    private let repository: TrackerRepository
    private var raceSetting: RaceSetting?
    private var updating = true
    private var storageBlocked = false

    private static let storageKey = "mt-data"
    private static let corruptBackupKey = "mt-data-corrupt-backup"
    private static let suppressedKey = "mt-hk-suppressed"
    private static let planKey = "mt-plan"
    private static let notificationKey = "mt-notification-settings"

    init(repository: TrackerRepository = TrackerRepository(), defaults: UserDefaults = .standard) {
        self.repository = repository
        let setting = defaults.data(forKey: Self.planKey).flatMap { try? JSONDecoder().decode(RaceSetting.self, from: $0) }
        raceSetting = setting
        hasRaceSetting = setting != nil
        plan = TrainingPlan.make(setting ?? RaceSetting.placeholder())
        do {
            if let state = try repository.load() {
                apply(state)
                updating = false
                canUndoRestore = repository.canUndoRestore
                return
            }
        } catch {
            storageBlocked = true
            storageMessage = "保存データを読み込めませんでした。原本は保持しています。バックアップから復元してください。"
            updating = false
            return
        }
        suppressedAutoDays = Set(defaults.stringArray(forKey: Self.suppressedKey) ?? [])
        if let data = defaults.data(forKey: Self.notificationKey),
           let saved = try? JSONDecoder().decode(NotificationSettings.self, from: data) {
            notificationSettings = saved
        }
        if let data = defaults.data(forKey: Self.storageKey) {
            if let decoded = Self.decodeLogs(data) {
                logs = Self.migrateLegacyAutoLogs(decoded.logs)
                if decoded.wasPartiallyRecovered {
                    defaults.set(data, forKey: Self.corruptBackupKey)
                    storageMessage = "一部の記録を復旧しました。元の保存データも保持しています。"
                }
            } else {
                defaults.set(data, forKey: Self.corruptBackupKey)
                storageBlocked = true
                storageMessage = "記録を読み込めませんでした。元データを退避しました。バックアップから復元してください。"
            }
        }
        painChecks = logs.compactMapValues(\.pains)
        updating = false
        persist()
    }

    func setNotificationSettings(_ settings: NotificationSettings) {
        notificationSettings = settings
    }

    func exportBackupData() throws -> Data {
        try BackupCodec.validate(snapshot)
        return try JSONEncoder().encode(snapshot)
    }

    /// バックアップは現在の記録・大会設定・通知設定を丸ごと置き換える。
    func restoreBackupData(_ data: Data) throws {
        let backup = try BackupCodec.decode(data)
        // 保存が成功するまで画面上の状態も変更しない。
        try repository.save(backup, preservingCurrent: true)
        updating = true
        apply(backup)
        updating = false
        storageBlocked = false
        canUndoRestore = repository.canUndoRestore
    }

    func undoRestore() throws { try restoreBackupData(repository.previousData()) }

    private var snapshot: TrackerBackup {
        TrackerBackup(version: 2, raceSetting: raceSetting, logs: logs,
                      suppressedAutoDays: suppressedAutoDays, notificationSettings: notificationSettings,
                      painChecks: painChecks)
    }

    private func apply(_ state: TrackerBackup) {
        logs = Self.migrateLegacyAutoLogs(state.logs)
        suppressedAutoDays = state.suppressedAutoDays
        notificationSettings = state.notificationSettings
        painChecks = state.painChecks ?? logs.compactMapValues(\.pains)
        raceSetting = state.raceSetting
        hasRaceSetting = raceSetting != nil
        plan = TrainingPlan.make(raceSetting ?? RaceSetting.placeholder())
    }

    // MARK: - 大会設定

    /// 大会日を設定・変更する。ログには一切触れない。
    func setRace(name: String, date: Date) {
        let today = Plan.calendar.startOfDay(for: Date())
        let race = Plan.calendar.startOfDay(for: date)
        let start = hasRaceSetting && race == plan.race ? plan.start : TrainingPlan.resolveStart(race: race,
                                              existingStart: hasRaceSetting ? plan.start : nil,
                                              today: today)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let setting = RaceSetting(raceName: trimmed.isEmpty ? "フルマラソン" : trimmed,
                                  raceDateKey: Plan.key(for: race),
                                  startDateKey: Plan.key(for: start))
        raceSetting = setting
        plan = TrainingPlan.make(setting)
        hasRaceSetting = true
        persist()
    }

    /// 週の割り当てが変わるか(確認ダイアログの出し分け用)
    func planWouldShift(date: Date) -> Bool {
        guard hasRaceSetting, !logs.isEmpty else { return false }
        if Plan.calendar.isDate(date, inSameDayAs: plan.race) { return false }
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

    /// 旧形式は辞書全体を一括でデコードしていたため、1件の壊れたログで全履歴を失っていた。
    /// まず通常デコードを試し、失敗時だけ JSON の各値を個別に復旧する。
    private static func decodeLogs(_ data: Data) -> (logs: [String: RunLog], wasPartiallyRecovered: Bool)? {
        if let logs = try? JSONDecoder().decode([String: RunLog].self, from: data) {
            return (logs, false)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let rawLogs = object as? [String: Any] else { return nil }

        var recovered: [String: RunLog] = [:]
        var discarded = 0
        for (key, value) in rawLogs {
            guard JSONSerialization.isValidJSONObject(value),
                  let entryData = try? JSONSerialization.data(withJSONObject: value),
                  let log = try? JSONDecoder().decode(RunLog.self, from: entryData) else {
                discarded += 1
                continue
            }
            recovered[key] = log
        }
        guard !recovered.isEmpty else { return nil }
        return (recovered, true)
    }

    private func persist() {
        guard !updating, !storageBlocked else { return }
        do { try repository.save(snapshot) }
        catch { storageMessage = "データを保存できませんでした: \(error.localizedDescription)" }
    }

    func key(for date: Date) -> String { Plan.key(for: date) }

    func log(on date: Date) -> RunLog? { logs[key(for: date)] }

    func record(_ log: RunLog, on date: Date) {
        guard BackupCodec.validDistance(log.km), BackupCodec.validDistance(log.autoKm) else { return }
        updating = true
        suppressedAutoDays.remove(key(for: date))
        logs[key(for: date)] = log
        if let pains = log.pains { painChecks[key(for: date)] = pains }
        updating = false
        persist()
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
            guard BackupCodec.validDistance(summary.km),
                  summary.seconds.map({ (0...604_800).contains($0) }) ?? true else { continue }
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

    func weekLogs(_ week: Int) -> [RunLog] {
        weekDates(week).compactMap { logs[key(for: $0)] }
    }

    func weekAchieved(_ week: Int) -> Bool { weekLogs(week).count >= 2 }

    func weekKm(_ week: Int) -> Double {
        weekLogs(week).compactMap(\.distanceKm).reduce(0, +)
    }

    /// 回答済みの体調だけを判定する。未回答は警告を解除しない。
    func painWarning() -> PainWarning? {
        let recentChecks = painChecks.sorted { $0.key > $1.key }.map(\.value)
        guard let latestPains = recentChecks.first, !latestPains.isEmpty else { return nil }

        var worst: PainWarning?
        for part in latestPains {
            var count = 0
            for pains in recentChecks {
                if pains.contains(part) { count += 1 } else { break }
            }
            if count >= 2 && count > (worst?.count ?? 0) {
                worst = PainWarning(part: part, count: count)
            }
        }
        return worst
    }

    /// 運動記録がなくても体調を保存できる。空配列は明示的な「痛みなし」。
    func updatePains(_ pains: [BodyPart], on date: Date) {
        updating = true
        painChecks[key(for: date)] = pains
        if var log = logs[key(for: date)] {
            log.pains = pains
            logs[key(for: date)] = log
        }
        updating = false
        persist()
    }

    /// ユーザーが予定IDに対応付けた実績だけを完了とする。
    func menuProgress(week: Int) -> [Bool] {
        sessions(week: week).map { isSessionCompleted($0.id) }
    }

    var scheduledSessions: [ScheduledSession] {
        TrainingSchedule.sessions(plan: plan, weekdays: notificationSettings.runWeekdays)
    }

    func sessions(week: Int) -> [ScheduledSession] {
        scheduledSessions.filter { plan.weekIndex(of: $0.date) == week }
    }

    func isSessionCompleted(_ id: String) -> Bool {
        logs.values.contains { $0.type == .run && $0.sessionID == id }
    }

    func confirmSession(_ id: String?, on date: Date) {
        guard var log = log(on: date), log.type == .run else { return }
        if let id {
            guard let session = scheduledSessions.first(where: { $0.id == id }),
                  !session.isRace || Plan.calendar.isDate(date, inSameDayAs: plan.race),
                  plan.weekIndex(of: date) == plan.weekIndex(of: session.date),
                  !logs.contains(where: { $0.key != key(for: date) && $0.value.sessionID == id }) else { return }
            log.menu = session.title
        } else { log.menu = nil }
        log.sessionID = id
        logs[key(for: date)] = log
    }

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
