import SwiftUI

/// 大会名と大会日の設定。初回起動時はオンボーディングとして全画面で出す。
struct RaceSettingSheet: View {
    @EnvironmentObject private var store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    let isOnboarding: Bool

    @State private var name = ""
    @State private var date = Date()
    @State private var confirming = false

    private var today: Date { Plan.calendar.startOfDay(for: Date()) }

    /// 保存前のプレビュー。setRace と同じ resolveStart を通すので表示と結果が必ず一致する
    private var draft: TrainingPlan {
        let race = Plan.calendar.startOfDay(for: date)
        let start = TrainingPlan.resolveStart(
            race: race,
            existingStart: store.hasRaceSetting ? store.plan.start : nil,
            today: today)
        return TrainingPlan.make(RaceSetting(raceName: name,
                                             raceDateKey: Plan.key(for: race),
                                             startDateKey: Plan.key(for: start)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if isOnboarding {
                        VStack(spacing: 6) {
                            Text("出る大会を教えてください").font(.title3.bold())
                            Text("大会日から逆算して、最大18週のトレーニングプランを組みます")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 8)
                    }

                    card {
                        Text("大会名").font(.caption).foregroundStyle(.secondary)
                        TextField("フルマラソン", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)

                        Text("大会日").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        DatePicker("", selection: $date, in: today..., displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            // 端末が和暦設定でも元号ピッカーにならないよう明示
                            .environment(\.calendar, Plan.calendar)
                            .environment(\.locale, Locale(identifier: "ja_JP"))
                    }

                    card { planSummary }

                    if let note = draft.compressionNote {
                        Text(note)
                            .font(.caption)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isOnboarding {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("やめる") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isOnboarding ? "はじめる" : "保存") { attemptSave() }.bold()
                }
            }
            .interactiveDismissDisabled(isOnboarding)
        }
        .onAppear {
            name = store.hasRaceSetting ? store.plan.raceName : ""
            date = store.hasRaceSetting ? store.plan.race : defaultRaceDate()
        }
        .alert("週の区切りが変わります", isPresented: $confirming) {
            Button("変更する") { save() }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("これまでの記録は消えません。ただし各週のメニューの割り当てが変わり、チェックの付き方が変わることがあります。")
        }
    }

    @ViewBuilder private var planSummary: some View {
        let p = draft
        let counts = (0..<Plan.phases.count).map { ph in p.weeks.filter { $0.phase == ph }.count }
        let f: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.calendar = Plan.calendar
            f.dateFormat = "M/d(E)"
            return f
        }()

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(p.weekCount)週間プラン").font(.subheadline.bold())
                Spacer()
                Text(p.start <= today ? "今週から" : "\(f.string(from: p.start))開始")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                ForEach(Array(p.weeks.enumerated()), id: \.offset) { _, w in
                    Capsule().fill(phaseColor(w.phase)).frame(height: 6)
                }
            }
            Text(zip(Plan.phases, counts).filter { $0.1 > 0 }
                    .map { "\($0.0)\($0.1)週" }.joined(separator: " / "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 既存カードと同じ見た目
    @ViewBuilder private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// 既定値は18週後の日曜(いちばん自然なプラン長になる位置)
    private func defaultRaceDate() -> Date {
        let monday = TrainingPlan.monday(containing: today)
        return Plan.calendar.date(byAdding: .day, value: 17 * 7 + 6, to: monday)!
    }

    private func attemptSave() {
        if store.planWouldShift(date: date) { confirming = true } else { save() }
    }

    private func save() {
        store.setRace(name: name, date: date)
        NotificationManager.reschedule(store: store)
        dismiss()
    }
}
