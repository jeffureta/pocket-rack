import PocketRackCore
import SwiftUI
import UIKit

struct SettingsView: View {
    @Bindable var controller: ServerController
    @State private var revealToken = false

    var body: some View {
        Form {
            Section("Network & Discovery") {
                Stepper("Port: \(controller.port)", value: $controller.port, in: 1024...65535)
                TextField("Bonjour Name", text: $controller.bonjourName)
                Toggle("Public Static Site Reads (/)", isOn: $controller.publicStaticReads)
                Toggle("Require Auth on Webhooks", isOn: $controller.requireAuthForWebhooks)
            }

            Section("M2 Capacity Profile & Storage Guard") {
                Picker("Capacity Preset", selection: $controller.selectedPreset) {
                    ForEach(CapacityPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Storage Quota: \(Int(controller.customQuotaGB)) GB")
                    Slider(value: $controller.customQuotaGB, in: 10...450, step: 5)
                }
                VStack(alignment: .leading) {
                    Text("iPadOS Free-Space Safety Floor: \(Int(controller.customFloorGB)) GB")
                    Slider(value: $controller.customFloorGB, in: 5...50, step: 5)
                }
            }

            Section("Admin & API Bearer Token (Keychain)") {
                HStack {
                    Text(revealToken ? controller.authToken : String(repeating: "•", count: 20))
                        .font(.subheadline.monospaced())
                    Spacer()
                    Button(revealToken ? "Hide" : "Reveal") {
                        revealToken.toggle()
                    }
                }
                HStack {
                    Button("Copy Token") {
                        UIPasteboard.general.string = controller.authToken
                    }
                    Spacer()
                    Button("Rotate Token", role: .destructive) {
                        controller.rotateToken()
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }
}
