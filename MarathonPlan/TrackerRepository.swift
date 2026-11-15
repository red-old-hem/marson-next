import Foundation

enum BackupCodec {
    static let maximumBytes = 20 * 1024 * 1024

    static func decode(_ data: Data) throws -> TrackerBackup {
        guard data.count <= maximumBytes else { throw ValidationError.invalid }
        let state = try JSONDecoder().decode(TrackerBackup.self, from: data)
        try validate(state)
        return state
    }

    static func validate(_ state: TrackerBackup) throws {
        guard (1...2).contains(state.version) else { throw ValidationError.version }
        if let race = state.raceSetting {
            guard validDay(race.raceDateKey), validDay(race.startDateKey),
                  let start = Plan.date(fromKey: race.startDateKey),
                  let end = Plan.date(fromKey: race.raceDateKey),
                  TrainingPlan.monday(containing: start) == start,
                  start <= end,
                  TrainingPlan.weeksBetween(start, TrainingPlan.monday(containing: end)) < 18,
                  race.raceName.count <= 200 else { throw ValidationError.invalid }
        }
        let settings = state.notificationSettings
        guard settings.runWeekdays.isSubset(of: Set(1...7)),
              (0...23).contains(settings.morningHour), (0...23).contains(settings.eveningHour),
              state.logs.count <= 100_000,
              state.suppressedAutoDays.allSatisfy(validDay) else { throw ValidationError.invalid }
        for (day, log) in state.logs {
            guard validDay(day), validDistance(log.km), validDistance(log.autoKm),
                  log.autoSeconds.map({ (0...604_800).contains($0) }) ?? true,
                  (log.menu?.count ?? 0) <= 1_000,
                  (log.sessionID?.count ?? 0) <= 300 else { throw ValidationError.invalid }
        }
        guard (state.painChecks ?? [:]).keys.allSatisfy(validDay) else { throw ValidationError.invalid }
    }

    static func validDay(_ key: String) -> Bool {
        guard key.count == 10, let date = Plan.date(fromKey: key), Plan.key(for: date) == key else { return false }
        return (1900...2200).contains(Plan.calendar.component(.year, from: date))
    }

    static func validDistance(_ km: Double?) -> Bool {
        guard let km else { return true }
        return km.isFinite && (0...1_000).contains(km)
    }

    enum ValidationError: LocalizedError {
        case version, invalid
        var errorDescription: String? {
            switch self {
            case .version: return "このバックアップのバージョンには対応していません。"
            case .invalid: return "日付・距離・時刻などに不正な値があります。データは変更していません。"
            }
        }
    }
}

/// 状態全体を1ファイルへ原子的に保存する。復元前の状態は別ファイルへ退避。
final class TrackerRepository {
    let directory: URL
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var previousURL: URL { directory.appendingPathComponent("before-restore.json") }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MarathonPlan", isDirectory: true)) {
        self.directory = directory
    }

    func load() throws -> TrackerBackup? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try BackupCodec.decode(Data(contentsOf: stateURL))
    }

    func save(_ state: TrackerBackup, preservingCurrent: Bool = false) throws {
        try BackupCodec.validate(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if preservingCurrent, FileManager.default.fileExists(atPath: stateURL.path) {
            try Data(contentsOf: stateURL).write(to: previousURL, options: .atomic)
        }
        try data.write(to: stateURL, options: .atomic)
    }

    func previousData() throws -> Data { try Data(contentsOf: previousURL) }
    var canUndoRestore: Bool { FileManager.default.fileExists(atPath: previousURL.path) }
}
