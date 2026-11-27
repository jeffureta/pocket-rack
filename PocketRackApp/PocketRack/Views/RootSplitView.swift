import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case storage = "Storage & Sites"
    case logs = "Live Logs"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "server.rack"
        case .storage: return "externaldrive"
        case .logs: return "list.bullet.rectangle"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct RootSplitView: View {
    @Bindable var controller: ServerController
    @State private var selection: SidebarDestination? = .dashboard

    var body: some View {
        ZStack {
            NavigationSplitView {
                List(SidebarDestination.allCases, selection: $selection) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
                .navigationTitle("PocketRack")
            } detail: {
                switch selection ?? .dashboard {
                case .dashboard:
                    DashboardView(controller: controller)
                case .storage:
                    StorageView(controller: controller)
                case .logs:
                    LogsView(controller: controller)
                case .settings:
                    SettingsView(controller: controller)
                }
            }

            if controller.isKioskDimmed {
                KioskOverlayView(controller: controller)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controller.isKioskDimmed)
    }
}
