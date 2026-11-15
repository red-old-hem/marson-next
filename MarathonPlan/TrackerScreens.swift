import SwiftUI

struct SettingsHome: View {
    @State private var section: SettingsSection?
    var body: some View {
        NavigationStack {
            List {
                Button("大会・プラン") { section = .race }
                Button("練習曜日・通知") { section = .notifications }
                Button("バックアップ・復元") { section = .backup }
            }
            .navigationTitle("設定")
            .sheet(item: $section) { section in
                RaceSettingSheet(isOnboarding: false, section: section)
            }
        }
    }
}

enum SettingsSection: String, Identifiable {
    case race, notifications, backup
    var id: String { rawValue }
}

struct TodayScheduleCard: View {
    @EnvironmentObject private var store: TrackerStore
    var body: some View {
        let today = Plan.calendar.startOfDay(for: Date())
        let sessions = store.scheduledSessions.filter { $0.date == today }
        VStack(alignment: .leading, spacing: 8) {
            Text("今日の予定").font(.headline)
            if sessions.isEmpty {
                Text("今日は練習予定がありません。体調に合わせて過ごしましょう。")
            }
            ForEach(sessions) { session in
                Label(session.title, systemImage: store.isSessionCompleted(session.id) ? "checkmark.circle.fill" : "circle")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 運動をしなかった日にも回答できる。空配列だけが明示的な「痛みなし」。
struct DailyPainCard: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var selection: Set<BodyPart> = []
    var body: some View {
        let today = Plan.calendar.startOfDay(for: Date())
        let answer = store.painChecks[Plan.key(for: today)]
        VStack(alignment: .leading, spacing: 10) {
            Text("今日の体調").font(.headline)
            Text(answer.map { $0.isEmpty ? "痛みなしと回答済み" : "痛み: \($0.map(\.label).joined(separator: "・"))" } ?? "痛みは未回答です")
                .font(.caption).foregroundStyle(.secondary)
            PainChips(selection: $selection)
            HStack {
                Button("痛みなし") { save([], on: today) }
                Button("選んだ部位を記録") { save(Array(selection), on: today) }
                    .disabled(selection.isEmpty)
            }.buttonStyle(.bordered)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .onAppear { selection = Set(answer ?? []) }
    }
    private func save(_ parts: [BodyPart], on day: Date) {
        selection = Set(parts)
        store.updatePains(parts, on: day)
        NotificationManager.reschedule(store: store)
    }
}

struct HistoryList: View {
    @EnvironmentObject private var store: TrackerStore
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if store.logs.isEmpty { Text("まだ記録がありません") }
            ForEach(store.logs.keys.sorted(by: >), id: \.self) { key in
                if let log = store.logs[key], let day = Plan.date(fromKey: key) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(key).font(.headline)
                        Text(log.type == .rest ? "休養" : "ラン \(log.distanceKm.map(Format.km) ?? "—")km")
                        if log.type == .run {
                            Picker("実施メニュー", selection: Binding(get: { log.sessionID ?? "" }, set: { id in
                                store.confirmSession(id.isEmpty ? nil : id, on: day)
                                NotificationManager.reschedule(store: store)
                            })) {
                                Text("自由ラン・未確認").tag("")
                                if let id = log.sessionID, !store.scheduledSessions.contains(where: { $0.id == id }) {
                                    Text("以前のプラン: \(log.menu ?? "確認済み")").tag(id)
                                }
                                ForEach(store.sessions(week: store.weekIndex(of: day)).filter {
                                    (!$0.isRace || Plan.calendar.isDate(day, inSameDayAs: store.plan.race)) &&
                                    (!store.isSessionCompleted($0.id) || log.sessionID == $0.id)
                                }) { session in Text(session.title).tag(session.id) }
                            }
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}
