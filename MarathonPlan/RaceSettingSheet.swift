import SwiftUI
import UniformTypeIdentifiers

/// 大会名と大会日の設定。初回起動時はオンボーディングとして全画面で出す。
struct RaceSettingSheet: View {
    @EnvironmentObject private var store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    let isOnboarding: Bool
    var section: SettingsSection = .race

    @State private var name = ""
    @State private var date = Date()
    @State private var confirming = false
    @State private var notificationSettings = NotificationSettings()
    @State private var showingImporter = false
    @State private var showingRestoreConfirmation = false
    @State private var pendingBackupData: Data?
    @State private var backupDocument: BackupDocument?
    @State private var message: String?
    @State private var restoreSummary = ""
    @State private var saving = false

    private var today: Date { Plan.calendar.startOfDay(for: Date()) }

    /// 保存前のプレビュー。setRace と同じ resolveStart を通すので表示と結果が必ず一致する
    private var draft: TrainingPlan {
        let race = Plan.calendar.startOfDay(for: date)
        let start = store.hasRaceSetting && race == store.plan.race ? store.plan.start : TrainingPlan.resolveStart(
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

                    if isOnboarding || section == .race { card {
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
                    } }

                    if isOnboarding || section == .race { card { planSummary } }

                    if isOnboarding || section == .notifications { card { notificationControls } }
                    if section == .backup || isOnboarding { card { backupControls } }

                    if (isOnboarding || section == .race), let note = draft.compressionNote {
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
                    Button(isOnboarding ? "はじめる" : (section == .backup ? "閉じる" : "保存")) { attemptSave() }.bold().disabled(saving)
                }
            }
            .interactiveDismissDisabled(isOnboarding)
        }
        .onAppear {
            name = store.hasRaceSetting ? store.plan.raceName : ""
            date = store.hasRaceSetting ? store.plan.race : defaultRaceDate()
            notificationSettings = store.notificationSettings
        }
        .alert("週の区切りが変わります", isPresented: $confirming) {
            Button("変更する") { save() }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("これまでの記録は消えません。ただし各週のメニューの割り当てが変わり、チェックの付き方が変わることがあります。")
        }
        .fileExporter(isPresented: Binding(get: { backupDocument != nil }, set: { if !$0 { backupDocument = nil } }),
                      document: backupDocument,
                      contentType: .json,
                      defaultFilename: "marathon-plan-backup-\(Plan.key(for: Date()))") { result in
            if case .failure = result { message = "バックアップを書き出せませんでした。" }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            guard case let .success(url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= BackupCodec.maximumBytes else {
                    throw BackupCodec.ValidationError.invalid
                }
                let data = try Data(contentsOf: url)
                let backup = try BackupCodec.decode(data)
                restoreSummary = "大会: \(backup.raceSetting?.raceName ?? "未設定")\n記録: \(backup.logs.count)件\n現在の大会・記録・通知設定を置き換えます。置換前の状態へ戻すこともできます。"
                pendingBackupData = data
                showingRestoreConfirmation = true
            } catch {
                message = "復元できません: \(error.localizedDescription)"
            }
        }
        .alert("バックアップを復元しますか？", isPresented: $showingRestoreConfirmation) {
            Button("復元する", role: .destructive) { restoreBackup() }
            Button("やめる", role: .cancel) { pendingBackupData = nil }
        } message: {
            Text(restoreSummary)
        }
        .alert("お知らせ", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder private var notificationControls: some View {
        Text("通知").font(.subheadline.bold())
        Text("練習する曜日（通知をオフにしてもプランに反映されます）").font(.caption)
        HStack(spacing: 6) {
            ForEach(Array(1...7), id: \.self) { weekday in
                let selected = notificationSettings.runWeekdays.contains(weekday)
                Button(weekdayLabel(weekday)) {
                    if selected { notificationSettings.runWeekdays.remove(weekday) }
                    else { notificationSettings.runWeekdays.insert(weekday) }
                }
                .font(.caption.bold()).frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.bordered).tint(selected ? .green : .gray)
                .accessibilityLabel("\(weekdayLabel(weekday))曜日 \(selected ? "選択済み" : "未選択")")
            }
        }
        Toggle("通知を受け取る", isOn: $notificationSettings.enabled)
        if notificationSettings.enabled {
            Picker("朝の時刻", selection: $notificationSettings.morningHour) {
                ForEach(0...23, id: \.self) { Text("\($0):00").tag($0) }
            }
            .pickerStyle(.menu)
            Toggle("夜の確認通知", isOn: $notificationSettings.eveningEnabled)
            if notificationSettings.eveningEnabled {
                Picker("夜の時刻", selection: $notificationSettings.eveningHour) {
                    ForEach(0...23, id: \.self) { Text("\($0):00").tag($0) }
                }
                .pickerStyle(.menu)
            }
            Text("通知をオンにして保存すると、iPhoneの許可を確認します。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("iPhoneの通知設定を開く", destination: url).font(.footnote)
            }
        }
    }

    @ViewBuilder private var backupControls: some View {
        Text("データのバックアップ").font(.subheadline.bold())
        Text("大会設定・記録・通知設定をJSONファイルとして保存、または復元できます。復元すると現在のデータは置き換わります。")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack(spacing: 10) {
            Button("書き出す") {
                do { backupDocument = BackupDocument(data: try store.exportBackupData()) }
                catch { message = "バックアップを作成できませんでした。" }
            }
            .buttonStyle(.bordered)
            Button("復元する") { showingImporter = true }
                .buttonStyle(.bordered)
                .tint(.orange)
        }
        if store.canUndoRestore {
            Button("復元前のデータに戻す") {
                do {
                    try store.undoRestore()
                    NotificationManager.reschedule(store: store)
                    message = "復元前の状態に戻しました。"
                } catch { message = error.localizedDescription }
            }.buttonStyle(.bordered)
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
        if !isOnboarding && section == .backup { dismiss(); return }
        if !isOnboarding && section == .notifications { save(); return }
        if store.planWouldShift(date: date) { confirming = true } else { save() }
    }

    private func save() {
        if isOnboarding || section == .race { store.setRace(name: name, date: date) }
        if isOnboarding || section == .notifications {
            store.setNotificationSettings(notificationSettings)
            saving = true
            Task {
                var permitted = true
                if notificationSettings.enabled { permitted = await NotificationManager.requestAuthorizationIfNeeded() }
                NotificationManager.reschedule(store: store)
                saving = false
                if permitted { dismiss() }
                else { message = "通知はiPhoneの設定で許可されていません。練習曜日は保存しました。「iPhoneの通知設定を開く」から変更できます。" }
            }
            return
        }
        NotificationManager.reschedule(store: store)
        dismiss()
    }

    private func restoreBackup() {
        guard let data = pendingBackupData else { return }
        do {
            try store.restoreBackupData(data)
            notificationSettings = store.notificationSettings
            name = store.hasRaceSetting ? store.plan.raceName : ""
            date = store.hasRaceSetting ? store.plan.race : defaultRaceDate()
            NotificationManager.reschedule(store: store)
            if isOnboarding {
                dismiss()
            } else {
                message = "バックアップを復元しました。"
            }
        } catch {
            message = error.localizedDescription.isEmpty ? "バックアップを復元できませんでした。" : error.localizedDescription
        }
        pendingBackupData = nil
    }

    private func weekdayLabel(_ weekday: Int) -> String {
        ["日", "月", "火", "水", "木", "金", "土"][weekday - 1]
    }
}
