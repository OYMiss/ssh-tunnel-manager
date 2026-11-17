import XCTest
@testable import SSHTunnelCore

@MainActor
final class ConfigTests: XCTestCase {
    func testLegacyMigrationAndExactBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let legacy: [String: Any] = [
            "id": id.uuidString, "name": "Legacy", "host": "my-alias", "port": 2222, "autoConnect": true,
            "identityFile": "~/.ssh/key with space", "proxyJump": "bastion", "extraSSHArguments": "-o AddressFamily=inet",
            "portMappings": [
                ["forward": "local", "localHost": "::1", "localPort": 8080, "remoteHost": "::1", "remotePort": 80],
                ["forward": "remote", "localHost": "127.0.0.1", "localPort": 3000, "remoteHost": "0.0.0.0", "remotePort": 8000]
            ]
        ]
        let records: [[String: Any]] = [["kind": "divider"], ["kind": "tunnel", "tunnel": legacy]]
        let data = try JSONSerialization.data(withJSONObject: records)
        let store = ConfigStore(directory: directory)
        try data.write(to: store.fileURL)
        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, id)
        XCTAssertEqual(loaded[0].name, "Legacy")
        XCTAssertTrue(loaded[0].enabled)
        let parsed = try SSHCommand(loaded[0].command)
        XCTAssertEqual(parsed.forwards.map(\.port), [8080, 8000])
        XCTAssertTrue(parsed.userArguments.contains("bastion"))
        XCTAssertTrue(parsed.userArguments.contains("AddressFamily=inet"))
        try store.save(loaded)
        XCTAssertEqual(try store.load(), loaded)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("tunnels.before-command-ui.json")), data)
    }
    func testUnreadableConfigIsNotReplacedWithEmptyList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(directory: directory)
        let broken = Data("{broken".utf8)
        try broken.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), broken)
    }
    func testDuplicateIDsAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(directory: directory)
        let tunnel = Tunnel(command: "ssh -D1080 alias")
        try store.save([tunnel, tunnel])
        XCTAssertThrowsError(try store.load())
    }
}
