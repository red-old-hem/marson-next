import SwiftUI

@main
struct MarathonPlanApp: App {
    @StateObject private var store = TrackerStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TimelineView(.periodic(from: .now, by: 60)) { _ in ContentView() }
                .environmentObject(store)
                // 大会日が設定されるまで閉じられない。設定された瞬間に自動で閉じる
                .fullScreenCover(isPresented: .constant(!store.hasRaceSetting)) {
                    RaceSettingSheet(isOnboarding: true).environmentObject(store)
                }
                .onAppear {
                    NotificationManager.reschedule(store: store)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        NotificationManager.reschedule(store: store)
                        Task { await HealthKitManager.shared.syncWorkouts(into: store) }
                    }
                }
        }
    }
}
