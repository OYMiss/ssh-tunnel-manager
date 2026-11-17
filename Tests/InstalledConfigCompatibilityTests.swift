import XCTest
@testable import SSHTunnelCore

@MainActor
final class InstalledConfigCompatibilityTests: XCTestCase {
    /// Optional read-only check against an existing installation, never used by
    /// CI. Copy to a temporary store so neither migration nor tests touch it.
    func testInstalledConfigIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SSHTUNNEL_CONFIG_CHECK"] else {
            throw XCTSkip("Set SSHTUNNEL_CONFIG_CHECK to check an existing config without modifying it")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let store = ConfigStore(directory: directory)
        try data.write(to: store.fileURL)
        let tunnels = try store.load()
        var valid = 0
        for tunnel in tunnels { if (try? SSHCommand(tunnel.command)) != nil { valid += 1 } }
        XCTAssertEqual(valid, tunnels.count, "All existing commands must remain usable")
        try store.save(tunnels)
        XCTAssertEqual(try store.load(), tunnels)
        print("Installed config migration verified: \(valid)/\(tunnels.count), original unchanged")
    }
}
