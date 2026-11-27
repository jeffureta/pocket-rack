import SwiftUI

@main
struct PocketRackApp: App {
    @State private var controller = ServerController()

    var body: some Scene {
        WindowGroup {
            RootSplitView(controller: controller)
                .preferredColorScheme(.dark)
        }
    }
}
