import Foundation

/// A small editor for a single forward. The saved command remains the source of truth.
struct TunnelSetup: Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case local, remote, dynamic
        var id: Self { self }
        var title: String {
            switch self { case .local: "本地"; case .remote: "远程"; case .dynamic: "动态" }
        }
        var flag: String {
            switch self { case .local: "-L"; case .remote: "-R"; case .dynamic: "-D" }
        }
        var explanation: String {
            switch self {
            case .local: "在这台 Mac 上，访问服务器里的服务。"
            case .remote: "在服务器上，访问这台 Mac 上的服务。"
            case .dynamic: "通过 SSH 服务器上网，提供本地 SOCKS5 代理。"
            }
        }
        var defaultListenPort: String { self == .dynamic ? "1080" : "8080" }
        var defaultTargetPort: String { self == .remote ? "3000" : "80" }
    }

    var kind: Kind = .local
    var destination = ""
    var sshPort = ""
    var listenPort = "8080"
    var targetHost = "localhost"
    var targetPort = "80"
    private(set) var bindAddress: String? = "127.0.0.1"
    private(set) var preservedArguments: [String] = []
    // Preserve the position of connection options, whose first value wins in SSH.
    private var originalOptions: [SSHCommand.Option] = []

    init() {}

    init(command: SSHCommand) throws {
        guard command.forwards.count == 1 else {
            throw CommandError("这条命令包含多个转发，请在手动命令中编辑。")
        }
        destination = command.destination
        let options = command.options
        let forwards = options.compactMap(\.forwarding)
        guard let forward = forwards.first, forwards.count == 1 else {
            throw CommandError("请在手动命令中编辑这条转发。")
        }
        let parts = try SSHCommand.forwardComponents(forward.specification)
        switch forward.flag {
        case "L": kind = .local
        case "R": kind = .remote
        default: kind = .dynamic
        }
        let baseCount = kind == .dynamic ? 1 : 3
        guard parts.count == baseCount || parts.count == baseCount + 1 else {
            throw CommandError("这种转发需要在手动命令中编辑。")
        }
        bindAddress = parts.count == baseCount + 1 ? parts.first : nil
        guard bindAddress == nil || ["localhost", "127.0.0.1", "[::1]"].contains(bindAddress!) else {
            throw CommandError("这条命令指定了监听地址，请在手动命令中编辑。")
        }
        listenPort = parts[parts.count - baseCount]
        if kind != .dynamic {
            targetHost = parts[parts.count - 2]
            targetPort = parts.last!
        }
        let portOptions = options.filter { $0.flag == "-p" || $0.configuration?.key == "port" }
        guard portOptions.count <= 1 else {
            throw CommandError("这条命令有多个 SSH 端口选项，请在手动命令中编辑。")
        }
        if let port = portOptions.first { sshPort = port.configuration?.value ?? port.value! }
        originalOptions = options
        preservedArguments = options.filter {
            $0.forwarding == nil && $0.flag != "-p" && $0.configuration?.key != "port"
        }.flatMap(\.arguments)
        // If a command uses an unusual host/port syntax, keep it in the manual editor.
        _ = try validatedCommand()
    }

    mutating func changeKind(to next: Kind) {
        if listenPort == kind.defaultListenPort { listenPort = next.defaultListenPort }
        if targetPort == kind.defaultTargetPort { targetPort = next.defaultTargetPort }
        kind = next
    }

    var draftCommand: String {
        let host = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let bracketedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let endpoint = (bindAddress.map { $0 + ":" } ?? "") + listenPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let specification = kind == .dynamic ? endpoint : endpoint + ":" + bracketedHost + ":" + targetPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = sshPort.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["ssh", "-N"]
        var hasForward = false
        var hasPort = false
        for option in originalOptions {
            if option.forwarding != nil {
                arguments += [kind.flag, specification]
                hasForward = true
            } else if option.flag == "-p" || option.configuration?.key == "port" {
                if !port.isEmpty { arguments += ["-p", port] }
                hasPort = true
            } else {
                arguments += option.arguments
            }
        }
        if !hasPort && !port.isEmpty { arguments += ["-p", port] }
        if !hasForward { arguments += [kind.flag, specification] }
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if !destination.isEmpty { arguments.append(destination) }
        return SSHCommand.render(arguments)
    }

    func validatedCommand() throws -> String {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty, !destination.hasPrefix("-"),
              !destination.contains(where: { $0.isWhitespace || $0.isNewline }),
              !destination.contains("://") else {
            throw CommandError("填写 SSH 目标，例如 user@server，或 SSH 配置中的别名。")
        }
        let port = sshPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !port.isEmpty { try Self.checkPort(port, label: "SSH 端口") }
        try Self.checkPort(listenPort, label: kind == .remote ? "服务器端口" : "本地端口")
        if kind != .dynamic {
            let host = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, !host.contains(where: \.isWhitespace), !host.contains("://"),
                  !host.contains("/"), !host.contains("@"), !host.contains("\0") else {
                throw CommandError("服务地址只填主机名或 IP，例如 localhost，不要填网址或端口。")
            }
            if host.contains(":") {
                let raw = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
                guard raw.filter({ $0 == ":" }).count >= 2,
                      !raw.contains("["), !raw.contains("]") else {
                    throw CommandError("服务端口请填在端口栏；IPv6 地址需填写完整。")
                }
            } else if host.contains("[") || host.contains("]") {
                throw CommandError("请填写完整的服务地址。")
            }
            try Self.checkPort(targetPort, label: "服务端口")
        }
        let command = draftCommand
        _ = try SSHCommand(command)
        return command
    }

    private static func checkPort(_ text: String, label: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(trimmed), (1...65535).contains(value) else {
            throw CommandError("\(label)需要填写 1–65535 之间的数字。")
        }
    }
}
