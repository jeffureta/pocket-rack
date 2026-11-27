import Foundation
import PocketRackCore

@main
struct PocketRackCLI {
    static func main() async throws {
        var port: UInt16 = 8080
        var rootPath = FileManager.default.currentDirectoryPath + "/PocketRackSite"
        var dbPath = FileManager.default.currentDirectoryPath + "/pocketrack.sqlite"
        var token = AuthGate.generateToken()
        var preset: CapacityPreset = .balancedM2

        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let flag = args.next() {
            switch flag {
            case "--port":
                if let val = args.next(), let parsed = UInt16(val) { port = parsed }
            case "--root":
                if let val = args.next() { rootPath = val }
            case "--db":
                if let val = args.next() { dbPath = val }
            case "--token":
                if let val = args.next() { token = val }
            case "--profile":
                if let val = args.next(), let parsed = CapacityPreset(rawValue: val) { preset = parsed }
            default:
                break
            }
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let indexURL = rootURL.appendingPathComponent("index.html")
        if !FileManager.default.fileExists(atPath: indexURL.path) {
            try Data("<!doctype html><html><body><h1>PocketRack is Online</h1><p>Open <a href=\"/_admin\">/_admin</a> to manage files, collections, KV, and webhooks.</p></body></html>".utf8).write(to: indexURL)
        }

        let profile: CapacityProfile = switch preset {
        case .eco: .eco
        case .balancedM2: .balancedM2
        case .performanceM2: .performanceM2
        }

        let config = RackConfiguration(
            port: port,
            bonjourName: "PocketRack-CLI",
            rootURL: rootURL,
            databasePath: dbPath,
            authToken: token,
            profile: profile
        )

        let app = try await RackApplication(configuration: config)
        let boundPort = try await app.start()
        print("PocketRack CLI v\(PocketRackVersion.current) listening on http://127.0.0.1:\(boundPort)")
        print("Profile: \(profile.preset.displayName) | Max Sockets: \(profile.maxConcurrentConnections)")
        print("Admin Console: http://127.0.0.1:\(boundPort)/_admin")
        print("Access Token: \(token)")

        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}
