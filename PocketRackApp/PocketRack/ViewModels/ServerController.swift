import Foundation
import Observation
import PocketRackCore
import Security
import UIKit

struct IOSHardwareProbe: SystemResourceProbe {
    let availableMemoryBytes: UInt64
    let thermalState: RackThermalState
    let batteryLevel: Float?
    let batteryCharging: Bool?

    @MainActor
    static func capture() -> IOSHardwareProbe {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel >= 0 ? UIDevice.current.batteryLevel : nil
        let state = UIDevice.current.batteryState
        let charging = (state == .charging || state == .full)
        return IOSHardwareProbe(
            availableMemoryBytes: UInt64(os_proc_available_memory()),
            thermalState: RackThermalState.currentProcess,
            batteryLevel: level,
            batteryCharging: charging
        )
    }
}

enum KeychainTokenStore {
    private static let service = "com.jeffureta.PocketRack.token"
    private static let account = "admin-bearer-token"

    static func loadOrCreate() -> String {
        if let existing = load(), !existing.isEmpty {
            return existing
        }
        let generated = AuthGate.generateToken()
        save(generated)
        return generated
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    static func save(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}

@MainActor
@Observable
final class ServerController {
    var isRunning = false
    var isKioskDimmed = false
    var statusMessage = "Stopped"
    var errorMessage: String?

    var port: UInt16 = 8080
    var bonjourName: String = "PocketRack"
    var selectedPreset: CapacityPreset = .balancedM2
    var customQuotaGB: Double = 100
    var customFloorGB: Double = 15
    var publicStaticReads: Bool = true
    var requireAuthForWebhooks: Bool = false

    var authToken: String = KeychainTokenStore.loadOrCreate()
    var activeRootURL: URL
    var usingExternalBookmark = false

    var boundPort: UInt16 = 8080
    var addresses: [NetworkInterfaceAddress] = []
    var logs: [RequestLogEntry] = []

    var activeConnections: Int = 0
    var effectiveConnectionLimit: Int = 64
    var availableMemoryBytes: UInt64 = 0
    var thermalState: RackThermalState = .nominal
    var batteryLevel: Float?
    var batteryCharging: Bool?
    var storageUsedBytes: UInt64 = 0
    var availableVolumeBytes: UInt64 = 0
    var totalRequests: UInt64 = 0

    private var app: RackApplication?
    private var telemetryTask: Task<Void, Never>?
    private var logStreamTask: Task<Void, Never>?
    private var scopedFolderURL: URL?

    private static let bookmarkDefaultsKey = "pocketrack.storage.bookmark"

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let defaultSite = docs.appendingPathComponent("SiteRoot", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultSite, withIntermediateDirectories: true)
        Self.seedStarterSiteIfNeeded(at: defaultSite)

        if let restored = Self.restoreSecurityScopedFolder() {
            self.activeRootURL = restored
            self.scopedFolderURL = restored
            self.usingExternalBookmark = true
        } else {
            self.activeRootURL = defaultSite
        }

        refreshStaticTelemetry()
    }

    var currentProfile: CapacityProfile {
        var base: CapacityProfile = switch selectedPreset {
        case .eco: .eco
        case .balancedM2: .balancedM2
        case .performanceM2: .performanceM2
        }
        base.storageQuotaBytes = UInt64(max(1, customQuotaGB)) * 1024 * 1024 * 1024
        base.minFreeDiskFloorBytes = UInt64(max(2, customFloorGB)) * 1024 * 1024 * 1024
        return base
    }

    var primaryURLString: String {
        if let lan = addresses.first(where: { $0.kind == .lan }) {
            return "http://\(lan.ip):\(boundPort)"
        }
        return "http://127.0.0.1:\(boundPort)"
    }

    var bonjourURLString: String {
        let host = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        return "http://\(host).local:\(boundPort)"
    }

    var tailscaleURLString: String? {
        guard let ts = addresses.first(where: { $0.kind == .tailscale }) else { return nil }
        return "http://\(ts.ip):\(boundPort)"
    }

    func toggleServer() {
        Task {
            if isRunning {
                await stop()
            } else {
                await start()
            }
        }
    }

    func start() async {
        guard !isRunning else { return }
        errorMessage = nil
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let dbPath = docs.appendingPathComponent("pocketrack.sqlite").path
            let probe = IOSHardwareProbe.capture()
            let config = RackConfiguration(
                port: port,
                bonjourName: bonjourName.isEmpty ? nil : bonjourName,
                rootURL: activeRootURL,
                databasePath: dbPath,
                authToken: authToken,
                profile: currentProfile,
                publicStaticReads: publicStaticReads,
                requireAuthForWebhooks: requireAuthForWebhooks
            )
            let newApp = try await RackApplication(configuration: config, probe: probe)
            let actualPort = try await newApp.start()
            self.app = newApp
            self.boundPort = actualPort
            self.isRunning = true
            self.statusMessage = "Online on :\(actualPort)"
            UIApplication.shared.isIdleTimerDisabled = true
            startMonitors(for: newApp)
        } catch {
            self.errorMessage = error.localizedDescription
            self.statusMessage = "Failed to start"
        }
    }

    func stop() async {
        telemetryTask?.cancel()
        telemetryTask = nil
        logStreamTask?.cancel()
        logStreamTask = nil
        await app?.stop()
        app = nil
        isRunning = false
        isKioskDimmed = false
        statusMessage = "Stopped"
        UIApplication.shared.isIdleTimerDisabled = false
        refreshStaticTelemetry()
    }

    func rotateToken() {
        let newToken = AuthGate.generateToken()
        authToken = newToken
        KeychainTokenStore.save(newToken)
        if isRunning {
            Task {
                await stop()
                await start()
            }
        }
    }

    func mountExternalFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Could not access selected folder."
            return
        }
        scopedFolderURL?.stopAccessingSecurityScopedResource()
        scopedFolderURL = url
        activeRootURL = url
        usingExternalBookmark = true
        if let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkDefaultsKey)
        }
        if isRunning {
            Task {
                await stop()
                await start()
            }
        } else {
            refreshStaticTelemetry()
        }
    }

    func resetToDefaultDocumentsFolder() {
        scopedFolderURL?.stopAccessingSecurityScopedResource()
        scopedFolderURL = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkDefaultsKey)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let defaultSite = docs.appendingPathComponent("SiteRoot", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultSite, withIntermediateDirectories: true)
        activeRootURL = defaultSite
        usingExternalBookmark = false
        if isRunning {
            Task {
                await stop()
                await start()
            }
        } else {
            refreshStaticTelemetry()
        }
    }

    private func startMonitors(for runningApp: RackApplication) {
        logStreamTask?.cancel()
        logStreamTask = Task {
            let stream = await runningApp.ledger.stream()
            for await entry in stream {
                logs.insert(entry, at: 0)
                if logs.count > 250 {
                    logs.removeLast(logs.count - 250)
                }
            }
        }

        telemetryTask?.cancel()
        telemetryTask = Task {
            while !Task.isCancelled {
                let probe = IOSHardwareProbe.capture()
                await runningApp.governor.updateProbe(probe)
                let snap = await runningApp.governor.currentSnapshot()
                let disk = await runningApp.quota.usageSummary(for: activeRootURL)
                let reqs = await runningApp.ledger.totalRequests()

                self.addresses = NetworkAddresses.discover().filter { $0.kind != .loopback }
                self.activeConnections = snap.active
                self.effectiveConnectionLimit = snap.limit
                self.availableMemoryBytes = snap.memoryHeadroomBytes
                self.thermalState = snap.thermal
                self.batteryLevel = snap.batteryLevel
                self.batteryCharging = snap.batteryCharging
                self.storageUsedBytes = disk.usedBytes
                self.availableVolumeBytes = disk.availableVolumeBytes
                self.totalRequests = reqs

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshStaticTelemetry() {
        let probe = IOSHardwareProbe.capture()
        let diskProbe = DefaultDiskSpaceProbe()
        self.addresses = NetworkAddresses.discover().filter { $0.kind != .loopback }
        self.availableMemoryBytes = probe.availableMemoryBytes
        self.thermalState = probe.thermalState
        self.batteryLevel = probe.batteryLevel
        self.batteryCharging = probe.batteryCharging
        self.effectiveConnectionLimit = currentProfile.maxConcurrentConnections
        self.storageUsedBytes = (try? diskProbe.directoryUsage(for: activeRootURL)) ?? 0
        self.availableVolumeBytes = (try? diskProbe.availableCapacity(for: activeRootURL)) ?? 0
    }

    private static func restoreSecurityScopedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkDefaultsKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else {
            return nil
        }
        return url
    }

    private static func seedStarterSiteIfNeeded(at dir: URL) {
        let indexURL = dir.appendingPathComponent("index.html")
        guard !FileManager.default.fileExists(atPath: indexURL.path) else { return }
        let html = """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>PocketRack on iPad</title></head>
        <body style="font-family:-apple-system,sans-serif;background:#0d1117;color:#e6edf3;display:grid;place-items:center;min-height:100vh;margin:0;">
          <div style="max-width:520px;padding:32px;background:#161b22;border:1px solid #30363d;border-radius:14px;">
            <h1 style="margin-top:0;">PocketRack is Online</h1>
            <p>Served directly from your iPad Air M2.</p>
            <p><a href="/_admin" style="color:#58a6ff;">Open Remote Console (/_admin) →</a></p>
          </div>
        </body>
        </html>
        """
        try? Data(html.utf8).write(to: indexURL)
    }
}
