// swift-tools-version: 5.9
import PackageDescription

// ドメインと保存処理は、iOS SimulatorなしでもmacOS上で検証できる。
let package = Package(
    name: "MarathonPlanCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "MarathonPlanCore", targets: ["MarathonPlan"])],
    targets: [
        .target(name: "MarathonPlan", path: "MarathonPlan",
                exclude: ["Assets.xcassets", "Info.plist", "MarathonPlan.entitlements",
                          "BackupDocument.swift", "ContentView.swift", "DistanceChartCard.swift",
                          "HealthKitManager.swift", "MarathonPlanApp.swift", "NotificationManager.swift",
                          "RaceSettingSheet.swift", "TrackerScreens.swift"],
                sources: ["Models.swift", "Plan.swift", "TrainingPlan.swift", "Season.swift", "Meals.swift",
                          "TrackerRepository.swift", "TrackerStore.swift", "ScheduledSession.swift"]),
        .testTarget(name: "MarathonPlanTests", dependencies: ["MarathonPlan"], path: "MarathonPlanTests")
    ]
)
