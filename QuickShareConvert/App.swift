import SwiftUI

@main
struct QuickShareConvertApp: App {
    @StateObject private var controller = ConversionController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
                // Launched by the share extension via quickshareconvert://convert
                .onOpenURL { _ in controller.pickUpPendingJob() }
                .task { controller.pickUpPendingJob() }
        }
    }
}
