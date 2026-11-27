import PocketRackCore
import SwiftUI

struct LogsView: View {
    @Bindable var controller: ServerController
    @State private var query = ""

    private var filteredLogs: [RequestLogEntry] {
        guard !query.isEmpty else { return controller.logs }
        return controller.logs.filter {
            $0.path.localizedCaseInsensitiveContains(query) ||
            $0.method.localizedCaseInsensitiveContains(query) ||
            "\($0.statusCode)".contains(query)
        }
    }

    var body: some View {
        List(filteredLogs) { entry in
            HStack(spacing: 12) {
                Text(entry.method)
                    .font(.caption.monospaced().bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.2), in: Capsule())
                Text("\(entry.statusCode)")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(entry.statusCode < 400 ? .green : .red)
                Text(entry.path)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.1f ms", entry.durationMs))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "Filter by path, method, or status")
        .navigationTitle("Live Logs")
    }
}
