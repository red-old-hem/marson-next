import Foundation

enum Meals {
    static func tips(on date: Date, plan: TrainingPlan) -> [String] {
        let cal = Plan.calendar
        let day = cal.startOfDay(for: date)
        let daysToRace = plan.daysToRace(from: day)
        let weekday = cal.component(.weekday, from: day)
        let weekPlan = plan.week(plan.weekIndex(of: day))
        let phase = weekPlan.phase

        if daysToRace < 0 {
            return ["完走おつかれさま。1〜2週間はしっかり食べてしっかり休む"]
        }
        if daysToRace == 0 {
            return ["スタート3時間前までに朝食(餅かおにぎり+バナナ)",
                    "スタート15分前にジェル1本",
                    "レース中は40〜45分ごとにジェル、給水は毎回取る"]
        }
        if daysToRace == 1 {
            return ["生もの・脂っこいもの・初めての店は避ける",
                    "消化の良い定番メニュー+主食多め",
                    "アルコールは我慢。水分をこまめに"]
        }
        if daysToRace <= 3 {
            return ["カーボローディング中: 主食を普段の1.5倍",
                    "脂質と食物繊維は控えめに",
                    "体重が1〜2kg増えるのは水分なので気にしない"]
        }

        var tips: [String] = []

        switch weekday {
        case 6 where phase >= 1: // 金: 翌日ロング走
            tips.append("明日のロング走に備えて夕食は主食多め")
        case 7: // 土: ロング走想定日
            if phase >= 1 {
                tips.append("ロング走2時間前におにぎり+バナナ")
                // 圧縮すると週番号の意味が変わるので、テンプレ上の位置で判定する
                if weekPlan.templateIndex >= 9 {
                    tips.append("走行中は45分ごとにジェル(本番と同じ銘柄で練習)")
                }
            }
            tips.append("練習後30分以内に牛乳+おにぎり")
        case 3, 5: // 火・木: 練習日
            tips.append("練習後30分以内に牛乳+おにぎり or バナナ+ヨーグルト")
        default:
            break
        }

        switch phase {
        case 0:
            tips.append("3食とも主食+タンパク質20g以上。朝食を抜かない")
        case 1:
            tips.append("鉄分を意識: 赤身肉・カツオ・レバー・小松菜")
            tips.append("3食とも主食+タンパク質20g以上")
        case 2:
            tips.append("走行量最大期。タンパク質と鉄分をしっかり、体重は落とそうとしない")
        default:
            tips.append("練習量が減る分、間食と脂質は控えめに。主食は減らさない")
        }

        // 季節の行は index 1 に差し込む。末尾に足すと prefix(3) で土曜に必ず消え、
        // 暑熱期の安全情報が最も要る日に出なくなる
        if let seasonal = Season.of(day).mealTip {
            tips.insert(seasonal, at: min(1, tips.count))
        }

        return Array(tips.prefix(3))
    }
}
