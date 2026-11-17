import Foundation

@MainActor
final class ConfigStore {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSHTunnelManager", isDirectory: true)
    }
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("tunnels.json") }

    init(directory: URL = ConfigStore.defaultDirectory) { self.directory = directory }

    func load() throws -> [Tunnel] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let tunnels: [Tunnel]
        if let flat = try? JSONDecoder().decode([Tunnel].self, from: data) {
            tunnels = flat
        } else {
            tunnels = try JSONDecoder().decode([LegacyItem].self, from: data).compactMap(\.tunnel)
        }
        guard Set(tunnels.map(\.id)).count == tunnels.count else {
            throw CommandError("配置中存在重复 ID；为避免覆盖数据，已停止加载。")
        }
        // Keep the exact original bytes before the first edit in the new format.
        let backup = directory.appendingPathComponent("tunnels.before-command-ui.json")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try data.write(to: backup, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        return tunnels
    }

    func save(_ tunnels: [Tunnel]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tunnels).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private struct LegacyItem: Decodable {
    let tunnel: Tunnel?
    private enum CodingKeys: String, CodingKey { case kind, tunnel }
    private enum Kind: String, Decodable { case tunnel, divider }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .tunnel: tunnel = try c.decode(Tunnel.self, forKey: .tunnel)
        case .divider: tunnel = nil
        }
    }
}
