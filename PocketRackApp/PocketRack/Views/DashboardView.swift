import CoreImage.CIFilterBuiltins
import PocketRackCore
import SwiftUI
import UIKit

struct DashboardView: View {
    @Bindable var controller: ServerController
    @State private var selectedURL: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Hero Status & Control Bar
                HStack(spacing: 16) {
                    Circle()
                        .fill(controller.isRunning ? Color.green : Color.secondary)
                        .frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.isRunning ? "Server Online" : "Server Offline")
                            .font(.title2.bold())
                        Text("\(controller.statusMessage) • \(controller.selectedPreset.displayName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if controller.isRunning {
                        Button {
                            controller.isKioskDimmed = true
                        } label: {
                            Label("Kiosk Dimmer", systemImage: "moon.stars.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button {
                        controller.toggleServer()
                    } label: {
                        Label(controller.isRunning ? "Stop" : "Start Server", systemImage: controller.isRunning ? "stop.fill" : "play.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.isRunning ? .red : .blue)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

                if let err = controller.errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }

                // Endpoints & QR Code
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Endpoints").font(.headline)
                        endpointRow(label: "LAN (Wi-Fi / Ethernet)", url: controller.primaryURLString)
                        endpointRow(label: "Bonjour (.local)", url: controller.bonjourURLString)
                        if let ts = controller.tailscaleURLString {
                            endpointRow(label: "Tailscale Private", url: ts)
                        }
                        endpointRow(label: "Web Console", url: "\(controller.primaryURLString)/_admin")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

                    VStack(spacing: 10) {
                        QRCodeImageView(string: selectedURL.isEmpty ? controller.primaryURLString : selectedURL)
                            .frame(width: 150, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text("Scan to Open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }

                // M2 Hardware Capacity Gauges
                Text("iPad Air M2 Capacity Telemetry")
                    .font(.headline)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    metricCard(
                        title: "Concurrent Sockets",
                        value: "\(controller.activeConnections) / \(controller.effectiveConnectionLimit)",
                        subtitle: "Thermal: \(controller.thermalState.rawValue.capitalized)"
                    )
                    metricCard(
                        title: "RAM Headroom",
                        value: ByteCountFormatter.string(fromByteCount: Int64(controller.availableMemoryBytes), countStyle: .memory),
                        subtitle: "503 floor: 256 MB"
                    )
                    metricCard(
                        title: "Quota Usage",
                        value: ByteCountFormatter.string(fromByteCount: Int64(controller.storageUsedBytes), countStyle: .file),
                        subtitle: "Cap: \(Int(controller.customQuotaGB)) GB"
                    )
                    metricCard(
                        title: "Volume Free",
                        value: ByteCountFormatter.string(fromByteCount: Int64(controller.availableVolumeBytes), countStyle: .file),
                        subtitle: "507 floor: \(Int(controller.customFloorGB)) GB"
                    )
                    metricCard(
                        title: "Battery",
                        value: controller.batteryLevel.map { "\(Int($0 * 100))%" } ?? "AC / N/A",
                        subtitle: controller.batteryCharging == true ? "Charging" : "On Battery"
                    )
                    metricCard(
                        title: "Total Requests",
                        value: "\(controller.totalRequests)",
                        subtitle: "Token: \(String(controller.authToken.prefix(6)))••••"
                    )
                }
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
        .onAppear {
            if selectedURL.isEmpty {
                selectedURL = controller.primaryURLString
            }
        }
    }

    private func endpointRow(label: String, url: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(url).font(.system(.subheadline, design: .monospaced))
            }
            Spacer()
            Button("QR") { selectedURL = url }
                .buttonStyle(.bordered)
            Button {
                UIPasteboard.general.string = url
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }

    private func metricCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold())
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct QRCodeImageView: View {
    let string: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image = generateQR(from: string) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.secondary.opacity(0.2)
        }
    }

    private func generateQR(from text: String) -> UIImage? {
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
