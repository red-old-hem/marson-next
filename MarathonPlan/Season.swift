import Foundation

/// 日本(北半球)前提の季節区分。プランのフェーズとは完全に独立。
/// 大会日が可変になると「基礎期 = 夏」が成り立たなくなるため、
/// 気候の助言は実際の暦月から出す。
enum Season {
    case hot, cold, mild

    static func of(_ date: Date) -> Season {
        switch Plan.calendar.component(.month, from: date) {
        case 6, 7, 8, 9: return .hot
        case 12, 1, 2:   return .cold
        default:         return .mild
        }
    }

    /// 週メニューに添える気候メモ。標準期は nil = 何も出さない
    var trainingNote: String? {
        switch self {
        case .hot:  return "暑い時期。早朝か夜に走る。ペースは落として構わない。給水は我慢しない"
        case .cold: return "寒い時期。最初の5分は歩くくらいゆっくり。手袋と耳当てがあるだけで続く"
        case .mild: return nil
        }
    }

    /// 食事アドバイスに1行足す。標準期は nil
    var mealTip: String? {
        switch self {
        case .hot:  return "水分に加えて塩分も(スポーツドリンクか塩タブレット)"
        case .cold: return "喉が渇かなくても脱水する。走る前後にコップ1杯"
        case .mild: return nil
        }
    }
}
