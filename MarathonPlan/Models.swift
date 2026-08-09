import Foundation

enum LogType: String, Codable {
    case run
    case mini
    /// 痛み警告中の休養。週の最低ラインにカウントする
    case rest
}

enum BodyPart: String, Codable, CaseIterable, Identifiable {
    case knee, shin, sole, ankle, hip, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .knee: return "膝"
        case .shin: return "すね"
        case .sole: return "足裏"
        case .ankle: return "足首"
        case .hip: return "股関節"
        case .other: return "その他"
        }
    }
}

enum Feel: String, Codable, CaseIterable {
    case light, normal, heavy

    var label: String {
        switch self {
        case .light: return "軽い"
        case .normal: return "普通"
        case .heavy: return "重い"
        }
    }
}

struct RunLog: Codable, Equatable {
    var type: LogType
    var menu: String? = nil
    /// 手入力の距離。ヘルスケア同期はこの値を書き換えない
    var km: Double? = nil
    /// ヘルスケアからの自動記録なら true(手動記録は nil)
    var auto: Bool? = nil
    var pains: [BodyPart]? = nil
    var feel: Feel? = nil

    // 以下は必ず Optional にし、必ず末尾に追加すること。
    // 合成 Codable は非Optional に decode を生成するためデフォルト値があっても
    // 旧JSONで throw し、TrackerStore.init の try? が全ログを nil にして保存データが消える。

    /// その日のヘルスケアのラン距離の合計 (km, 0.1刻み)
    var autoKm: Double? = nil
    /// 同・所要時間の合計(秒)。Double だと JSON に誤差が乗り Equatable 比較が不安定になる
    var autoSeconds: Int? = nil
    /// 取り込み済みワークアウトのUUID(昇順)。変更検知に使う
    var workoutIDs: [String]? = nil
}

extension RunLog {
    /// 表示・集計に使う距離。ヘルスケア実測を優先し、無ければ手入力値
    var distanceKm: Double? { autoKm ?? km }

    var durationSeconds: Int? { autoSeconds }

    /// 秒/km。極端に短い記録はノイズなので弾く
    var paceSecPerKm: Double? {
        guard let km = distanceKm, km >= 0.5,
              let sec = autoSeconds, sec >= 60 else { return nil }
        return Double(sec) / km
    }

    var hasHealthDistance: Bool { autoKm != nil }
}

/// 表示書式。ビューからも通知からも使うのでドメイン側に置く
enum Format {
    /// 384.3 → "6:24/km"
    static func pace(_ secPerKm: Double) -> String {
        let total = Int(secPerKm.rounded())
        return String(format: "%d:%02d/km", total / 60, total % 60)
    }

    /// 3212 → "53分" / 4520 → "1時間15分"
    static func duration(seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分" }
        return "\(minutes / 60)時間\(minutes % 60)分"
    }

    /// 6.0 → "6" / 6.5 → "6.5"
    static func km(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }
}

/// 参照用の目標ペース(秒/km)。42.195km 換算
enum PaceTarget {
    /// サブ4.5 = 4:30:00 → 6:24/km
    static let sub45: Double = 16200 / 42.195
    /// サブ4 = 4:00:00 → 5:41/km
    static let sub4: Double = 14400 / 42.195
}

/// ヘルスケアから取り込んだ1日分の集計(HealthKit非依存にして検証可能にする)
struct WorkoutDaySummary {
    let date: Date
    let km: Double?
    let seconds: Int?
    let workoutIDs: [String]
}

struct WeekStat: Identifiable {
    let week: Int
    let phase: Int
    /// プランの目標距離
    let targetKm: Double
    let actualKm: Double
    /// 距離と時間が両方揃ったログのみの合計(ペース算出用)
    let timedKm: Double
    let timedSeconds: Int

    var id: Int { week }
    var label: String { "W\(week + 1)" }

    /// 距離だけのログを混ぜると平均が壊れるので、揃っているログのみで算出
    var paceSecPerKm: Double? {
        guard timedKm >= 1, timedSeconds > 0 else { return nil }
        return Double(timedSeconds) / timedKm
    }
}

struct PainWarning: Equatable {
    let part: BodyPart
    let count: Int
    var severe: Bool { count >= 3 }
}
