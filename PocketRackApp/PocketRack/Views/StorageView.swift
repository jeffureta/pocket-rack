import SwiftUI
import UniformTypeIdentifiers

struct StorageView: View {
    @Bindable var controller: ServerController
    @State private var showingPicker = false

    var body: some View {
        Form {
            Section("Active Site & File Vault Root") {
                LabeledContent("Location", value: controller.usingExternalBookmark ? "Mounted External / Files Folder" : "App Documents/SiteRoot")
                Text(controller.activeRootURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                HStack {
                    Button {
                        showingPicker = true
                    } label: {
                        Label("Mount USB-C Drive or Files Folder", systemImage: "folder.badge.plus")
                    }
                    if controller.usingExternalBookmark {
                        Button("Reset to Documents", role: .destructive) {
                            controller.resetToDefaultDocumentsFolder()
                        }
                    }
                }
            }

            Section("iPad Air M2 Storage Safety Guard") {
                LabeledContent("Vault Used", value: ByteCountFormatter.string(fromByteCount: Int64(controller.storageUsedBytes), countStyle: .file))
                LabeledContent("Configured Quota", value: "\(Int(controller.customQuotaGB)) GB")
                LabeledContent("Volume Free Space", value: ByteCountFormatter.string(fromByteCount: Int64(controller.availableVolumeBytes), countStyle: .file))
                LabeledContent("iPadOS Safety Floor", value: "\(Int(controller.customFloorGB)) GB (returns HTTP 507 below floor)")
            }
        }
        .navigationTitle("Storage & Sites")
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                controller.mountExternalFolder(url)
            }
        }
    }
}
