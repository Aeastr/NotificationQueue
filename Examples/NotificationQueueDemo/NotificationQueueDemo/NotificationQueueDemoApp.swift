import SwiftUI

@main
@MainActor
struct NotificationQueueDemoApp: App {
    @StateObject private var model = DemoModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DemoView(model: model)
                .task(id: scenePhase) {
                    if scenePhase == .active { await model.refresh() }
                }
        }
    }
}
