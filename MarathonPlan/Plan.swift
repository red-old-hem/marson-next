import Foundation

struct WeekPlan: Equatable {
    let phase: Int
    let km: Double
    let runs: [String]
    let tip: String
    /// 圧縮前テンプレでの位置 (0..<18)。圧縮後も「何週目相当か」を判定できるようにする
    let templateIndex: Int
}

/// 大会日に依存しない不変のテンプレートとユーティリティ。
/// 大会日から決まる可変部分は TrainingPlan が持つ。
enum Plan {
    static let phases = ["基礎期", "走り込み期", "実戦期", "調整期"]

    /// 端末が和暦・仏暦設定でも計算が狂わないようグレゴリオ暦固定
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "ja_JP")
        return cal
    }()

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - 日付キー ("yyyy-MM-dd")

    static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String { keyFormatter.string(from: date) }

    static func date(fromKey key: String) -> Date? {
        keyFormatter.date(from: key).map { calendar.startOfDay(for: $0) }
    }

    // MARK: - 18週テンプレート

    /// (phase, km, runs, tip)。templateIndex は enumerated で後付けする(手書きすると事故る)
    private static let rawTemplate: [(Int, Double, [String], String)] = [
        (0, 16, ["イージー40分", "イージー40分", "イージー50分"], "ペースは気にしない。7:00〜7:30/kmで会話できる速さで通せばいい"),
        (0, 18, ["イージー40分", "イージー40分", "イージー60分"], "前夜にウェアと靴を玄関へ。朝の意思決定をゼロにする"),
        (0, 20, ["イージー40分", "イージー50分", "イージー60分"], "練習後30分以内に牛乳+おにぎり。回復が翌日のやる気になる"),
        (0, 15, ["イージー40分", "イージー40分", "イージー40分"], "回復週。少なく感じてOK、それが正解"),
        (0, 22, ["イージー40分", "イージー50分", "イージー70分"], "距離が伸びてくる週。給水は我慢しない。走る前後で体重が1kg以上減らないように"),
        (1, 25, ["イージー40分", "イージー50分", "ロング走90分"], "ロング走は距離でなく時間で管理。きつければ途中で歩いてOK"),
        (1, 27, ["イージー40分", "イージー50分", "ロング走100分"], "鉄分を意識。赤身肉・カツオ・小松菜"),
        (1, 20, ["イージー40分", "イージー40分", "イージー60分"], "回復週。疲労を抜くのも練習のうち"),
        (1, 30, ["イージー40分", "ペース走20分 (5:45〜6:00/km)", "ロング走110分"], "ペース走はアップ・ダウン各10分ジョグ込みで"),
        (1, 32, ["イージー50分", "レースペース走8km (6:00〜6:20/km)", "ロング走120分"], "ロング走でジェル補給の練習開始。本番と同じ銘柄で"),
        (1, 24, ["イージー40分", "イージー50分", "イージー70分"], "回復週。よく寝ること"),
        (2, 34, ["イージー50分", "レースペース走10km", "ロング走120分"], "ここから実戦期。ペースを意識する練習が増える。1本1本の質を上げていく"),
        (2, 36, ["イージー50分", "ペース走20分", "30km走 (6:30〜7:00/km)"], "30km走1回目。ジェル持参、抑えて入って後半崩れないこと優先"),
        (2, 28, ["イージー40分", "レースペース走8km", "ロング走90分"], "つなぎ週。疲労が残っていたら遠慮なく削る"),
        (2, 42, ["イージー50分", "ペース走20分", "30km走 (6:20/kmで余裕を確認)"], "30km走2回目。ここでサブ4か4.5かを最終判断する"),
        (2, 32, ["イージー40分", "レースペース走10km", "ロング走90分"], "ここから徐々に量を落とす。追い込みたくなるのを我慢"),
        (3, 22, ["イージー40分", "レースペース走5km", "イージー60分"], "物足りないくらいが正解。本番3日前からカーボローディング(主食1.5倍・脂質控えめ)"),
        (3, 12, ["イージー30分", "2kmジョグ+流し3本", "本番 42.195km!"], "前日は生もの禁止。当日はスタート3時間前に朝食、15分前にジェル、レース中は40分ごとに補給"),
    ]

    static let template: [WeekPlan] = rawTemplate.enumerated().map {
        WeekPlan(phase: $1.0, km: $1.1, runs: $1.2, tip: $1.3, templateIndex: $0)
    }

    // MARK: - 圧縮

    /// M(= 調整期2週を除いた週数) → [基礎期, 走り込み期, 実戦期] の週数。
    /// 5:6:5 の最大剰余法(各1週下限)の計算結果を固定表にしたもの。
    /// M<=2 は「時間がないときは強度より継続」を優先した手当て。
    static let phaseQuota: [[Int]] = [
        /* 0 */ [0, 0, 0], /* 1 */ [1, 0, 0], /* 2 */ [1, 1, 0],
        /* 3 */ [1, 1, 1], /* 4 */ [1, 2, 1], /* 5 */ [2, 2, 1],
        /* 6 */ [2, 2, 2], /* 7 */ [2, 3, 2], /* 8 */ [3, 3, 2],
        /* 9 */ [3, 3, 3], /*10 */ [3, 4, 3], /*11 */ [4, 4, 3],
        /*12 */ [4, 4, 4], /*13 */ [4, 5, 4], /*14 */ [5, 5, 4],
        /*15 */ [5, 5, 5], /*16 */ [5, 6, 5],
    ]

    /// フェーズごとの「削るときに後まで残す順」。先頭ほど残る。
    /// 回復週・つなぎ週から先に削り、30km走とロング走の柱を最後まで守る。
    static let keepPriority: [[Int]] = [
        [0, 4, 2, 1, 3],       // 基礎期: 導入W1 → 最大量W5 → W3 → W2 → 回復週W4
        [5, 9, 8, 6, 10, 7],   // 走り込み: W6 → W10 → W9 → W7 → 回復W11 → 回復W8
        [12, 14, 11, 15, 13],  // 実戦期: 30km走1回目W13 → 2回目W15 → W12 → W16 → つなぎW14
    ]

    static let taperIndices = [16, 17]

    /// テンプレを count 週に圧縮する。調整期(最後の2週)は圧縮しない。
    /// - Parameter raceWeekdayOffset: 本番の月曜からのオフセット (0=月 ... 6=日)
    /// - Returns: 必ず1要素以上。空だと TrainingPlan.clamped が -1 でクラッシュする
    static func compressedWeeks(count: Int, raceWeekdayOffset d: Int) -> [WeekPlan] {
        let n = max(1, min(count, template.count))
        var picked: [Int]
        if n == 1 {
            picked = [17]                   // 本番週だけ
        } else {
            let quota = phaseQuota[n - 2]   // n=2 → M=0 → [0,0,0]
            picked = (0..<3).flatMap { Array(keepPriority[$0].prefix(quota[$0])) }
            picked += taperIndices
        }
        picked.sort()
        return picked.map { i in
            i == 17 ? raceWeek(template[17], weekdayOffset: d) : template[i]
        }
    }

    /// 本番週。本番までに入る日数が少ない場合、刺激入れを削って前日を必ず空ける。
    private static func raceWeek(_ w: WeekPlan, weekdayOffset d: Int) -> WeekPlan {
        guard d < 3 else { return w }        // 木〜日はテンプレそのまま(3本)
        let race = w.runs.last!              // "本番 42.195km!"
        let shakeouts = w.runs.dropLast()
        //  d=0(月)/d=1(火): [] → 本番のみ
        //  d=2(水): ["2kmジョグ+流し3本"] → 月曜刺激入れ、火曜休養、水曜本番
        let keep = Array(shakeouts.suffix(max(0, d - 1)))
        return WeekPlan(phase: w.phase,
                        km: keep.isEmpty ? 5 : 8,
                        runs: keep + [race],
                        tip: w.tip,
                        templateIndex: 17)
    }
}
