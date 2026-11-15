import Foundation
import UserNotifications

/// 設定された曜日・時刻にメニュー通知、夜は未チェックなら確認通知。
/// アプリ起動時とチェックイン時に直近14日分を組み直す。
@MainActor
enum NotificationManager {
    @discardableResult
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    static func reschedule(store: TrackerStore) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        let cal = Plan.calendar
        let today = cal.startOfDay(for: Date())
        let plan = store.plan
        let settings = store.notificationSettings
        guard settings.enabled, store.hasRaceSetting, today <= plan.race else { return }

        let sessions = store.scheduledSessions

        for offset in 0..<14 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today), day <= plan.race else { continue }
            let session = sessions.first { cal.isDate($0.date, inSameDayAs: day) }
            if let session, !store.isSessionCompleted(session.id), session.isRace {
                schedule(center: center, id: "morning-\(store.key(for: day))", day: day, hour: settings.morningHour,
                         title: "本番当日", body: "ここまで積み上げた分を信じよう。楽しんで完走を！")
            } else if let session, !store.isSessionCompleted(session.id) {
                if let warning = store.painWarning() {
                    schedule(center: center, id: "morning-\(store.key(for: day))", day: day, hour: settings.morningHour,
                             title: "今日は休養推奨", body: "\(warning.part.label)の痛みが続いています。無理せず休むか短いジョグに")
                } else {
                    schedule(center: center, id: "morning-\(store.key(for: day))", day: day, hour: settings.morningHour,
                             title: "今日は走る日", body: "メニュー: \(session.title)。玄関のウェアを着るだけでOK")
                }
            }

            let eveningBody = day == plan.race
                ? "本番おつかれさま。今日はゆっくり休んで、まずは完走を祝おう"
                : "今日の体調と活動を振り返ろう。休養日なら無理せず休んでOK"
            if settings.eveningEnabled, store.log(on: day) == nil {
                schedule(center: center, id: "evening-\(store.key(for: day))", day: day, hour: settings.eveningHour,
                         title: "今日の確認", body: eveningBody)
            }
        }
    }

    private static func schedule(center: UNUserNotificationCenter, id: String, day: Date, hour: Int, title: String, body: String) {
        var comps = Plan.calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour
        guard let fireDate = Plan.calendar.date(from: comps), fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
