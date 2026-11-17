import Foundation

/// The command is the only source of connection configuration. `enabled` also
/// remembers the user's intent across app launches; a network outage doesn't
/// turn that intent off.
struct Tunnel: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var command: String
    var enabled: Bool

    init(id: UUID = UUID(), name: String = "", command: String, enabled: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.enabled = enabled
    }

    var parsed: SSHCommand? { try? SSHCommand(command) }
    var displayName: String { name.isEmpty ? (parsed?.destination ?? "SSH 隧道") : name }
    var portSummary: String { parsed?.portSummary ?? "命令需要检查" }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, enabled
        case host, port, identityFile, autoConnect, portMappings
        case localHost, localPort, remoteHost, remotePort
        case compression, disableTCPKeepAlive, skipHostKeyCheck, extraSSHArguments, proxyJump
        case connectTimeout, serverAliveInterval, serverAliveCountMax
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        if let command = try c.decodeIfPresent(String.self, forKey: .command) {
            self.command = command
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            return
        }
        // One-time, lossless conversion from the former configuration forms.
        enabled = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
        var args = ["ssh", "-N"]
        if let port = try c.decodeIfPresent(Int.self, forKey: .port) { args += ["-p", String(port)] }
        if let key = try c.decodeIfPresent(String.self, forKey: .identityFile), !key.isEmpty {
            args += ["-i", SSHCommand.quote(key), "-o", "IdentitiesOnly=yes"]
        }
        if let jump = try c.decodeIfPresent(String.self, forKey: .proxyJump), !jump.isEmpty {
            args += ["-J", SSHCommand.quote(jump)]
        }
        for (key, option) in [(CodingKeys.connectTimeout, "ConnectTimeout"), (.serverAliveInterval, "ServerAliveInterval"), (.serverAliveCountMax, "ServerAliveCountMax")] {
            if let value = try c.decodeIfPresent(Int.self, forKey: key) { args += ["-o", "\(option)=\(value)"] }
        }
        if try c.decodeIfPresent(Bool.self, forKey: .compression) == true { args += ["-C"] }
        if try c.decodeIfPresent(Bool.self, forKey: .disableTCPKeepAlive) == true { args += ["-o", "TCPKeepAlive=no"] }
        if try c.decodeIfPresent(Bool.self, forKey: .skipHostKeyCheck) == true {
            args += ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]
        }
        struct Mapping: Decodable {
            var forward: String?
            var localHost: String
            var localPort: Int
            var remoteHost: String
            var remotePort: Int
        }
        let mappings: [Mapping]
        if let values = try c.decodeIfPresent([Mapping].self, forKey: .portMappings), !values.isEmpty {
            mappings = values
        } else {
            mappings = [Mapping(
                localHost: try c.decode(String.self, forKey: .localHost),
                localPort: try c.decode(Int.self, forKey: .localPort),
                remoteHost: try c.decode(String.self, forKey: .remoteHost),
                remotePort: try c.decode(Int.self, forKey: .remotePort)
            )]
        }
        func address(_ host: String) -> String { host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host }
        for m in mappings {
            switch m.forward ?? "local" {
            case "dynamic": args += ["-D", SSHCommand.quote("\(address(m.localHost)):\(m.localPort)")]
            case "remote": args += ["-R", SSHCommand.quote("\(address(m.remoteHost)):\(m.remotePort):\(address(m.localHost)):\(m.localPort)")]
            case "local": args += ["-L", SSHCommand.quote("\(address(m.localHost)):\(m.localPort):\(address(m.remoteHost)):\(m.remotePort)")]
            default: throw CommandError("旧配置包含无法识别的转发类型，原文件未被覆盖。")
            }
        }
        if let extra = try c.decodeIfPresent(String.self, forKey: .extraSSHArguments), !extra.isEmpty { args += [extra] }
        args += [SSHCommand.quote(try c.decode(String.self, forKey: .host))]
        command = args.joined(separator: " ")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(command, forKey: .command)
        try c.encode(enabled, forKey: .enabled)
    }
}
