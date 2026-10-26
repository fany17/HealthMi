import SwiftData
import SwiftUI

@main
@MainActor
struct HealthMiApp: App {
    let modelContainer: ModelContainer

    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let schema = Schema([SyncState.self, StressRecord.self, SyncLogEntry.self])
        let configuration = ModelConfiguration(schema: schema)
        do {
            modelContainer = try ModelContainer(
                for: schema, migrationPlan: MigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            fatalError("无法初始化 SwiftData 容器：\(error)")
        }
        let appModel = AppModel()
        _model = State(initialValue: appModel)
        appModel.bootstrap()
        let container = modelContainer
        // 必须在应用启动时注册；不能等某个 SwiftUI 页面 .task 才注册。
        BackgroundSync.register {
            await appModel.syncAll(modelContext: container.mainContext, isBackground: true)
        }
        BackgroundSync.schedule()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(modelContainer)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { BackgroundSync.schedule() }
                    if phase == .active { model.bootstrap() }
                }
        }
    }
}
