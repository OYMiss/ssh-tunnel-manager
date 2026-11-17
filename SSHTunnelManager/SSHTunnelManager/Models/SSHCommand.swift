import Foundation

/// A command is parsed into argv, never evaluated by a shell. OpenSSH still reads
/// ~/.ssh/config, so aliases, keys and jump hosts need no parallel GUI settings.
struct SSHCommand: Equatable, Sendable {
    struct Forward: Equatable, Sendable {
        let flag: Character
        let port: Int
        var summary: String {
            let kind = flag == "R" ? "远程" : (flag == "D" ? "动态" : "本地")
            return "\(kind) :\(port)"
        }
    }

    struct Option: Equatable, Sendable {
        let flag: String
        let value: String?
        var arguments: [String] { [flag] + (value.map { [$0] } ?? []) }
        var configuration: (key: String, value: String)? {
            guard flag == "-o", let value else { return nil }
            let parts = value.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0.isWhitespace })
            guard parts.count == 2 else { return nil }
            return (String(parts[0]).lowercased(), String(parts[1]).trimmingCharacters(in: .whitespaces))
        }
        var forwarding: (flag: Character, specification: String)? {
            if let value, ["-L", "-R", "-D"].contains(flag) { return (flag.last!, value) }
            guard let config = configuration,
                  let flag = ["localforward": Character("L"), "remoteforward": "R", "dynamicforward": "D"][config.key]
            else { return nil }
            return (flag, config.value.split(whereSeparator: \.isWhitespace).joined(separator: ":"))
        }
    }

    private static let valueOptions = Set("BbcDeFIiJLlmopR")

    let destination: String
    let userArguments: [String]
    let forwards: [Forward]

    static let managedOptions = [
        "ForkAfterAuthentication=no", "SessionType=none", "RequestTTY=no",
        "RemoteCommand=none", "ControlMaster=no", "ControlPath=none",
        "ControlPersist=no", "ExitOnForwardFailure=yes", "ClearAllForwardings=no",
        "ServerAliveInterval=10", "ServerAliveCountMax=3", "ConnectTimeout=10",
        "ConnectionAttempts=1", "BatchMode=yes", "PermitLocalCommand=no",
        "LogLevel=DEBUG1"
    ]

    var arguments: [String] {
        // OpenSSH uses the FIRST value for each option. These must precede user
        // options and config-file values, especially ForkAfterAuthentication.
        ["-N", "-T", "-v"] + Self.managedOptions.flatMap { ["-o", $0] }
            + userArguments + [destination]
    }

    var portSummary: String { forwards.map(\.summary).joined(separator: ", ") }
    var remoteForwardCount: Int { forwards.filter { $0.flag == "R" }.count }

    /// userArguments is already normalized to one flag and (where needed) one value.
    var options: [Option] {
        var result: [Option] = []
        var index = 0
        while index < userArguments.count {
            let flag = userArguments[index]
            let hasValue = Self.valueOptions.contains(flag.last!)
            result.append(Option(flag: flag, value: hasValue ? userArguments[index + 1] : nil))
            index += hasValue ? 2 : 1
        }
        return result
    }

    /// An interactive login check must not contend with a running tunnel's ports.
    var loginCommand: String {
        let overrides = ["ClearAllForwardings=yes", "BatchMode=no", "ForkAfterAuthentication=no",
                         "SessionType=default", "RequestTTY=auto", "RemoteCommand=none",
                         "ControlMaster=no", "ControlPath=none", "ControlPersist=no", "PermitLocalCommand=no"]
        let overriddenKeys = Set(overrides.map { $0.split(separator: "=")[0].lowercased() })
        let connectionOptions = options.filter {
            $0.forwarding == nil && !overriddenKeys.contains($0.configuration?.key ?? "")
        }.flatMap(\.arguments)
        return Self.render(["ssh"] + overrides.flatMap { ["-o", $0] } + connectionOptions + [destination])
    }

    init(_ text: String) throws {
        guard !text.utf8.contains(0) else { throw CommandError("命令不能包含空字符。") }
        let tokens = try Self.tokenize(text)
        guard tokens.first == "ssh" || tokens.first == "/usr/bin/ssh" else {
            throw CommandError("命令必须以 ssh 开头。")
        }
        let simpleOptions = Set("1246AaCgKkNnTqxXvYy")
        let forbiddenOptions = Set("fGMEOQSsWwtV")
        var args: [String] = []
        var forwards: [Forward] = []
        var host: String?
        var index = 1
        var optionsEnded = false
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" && !optionsEnded {
                optionsEnded = true
                index += 1
                continue
            }
            if token.hasPrefix("-") && !optionsEnded {
                let flags = Array(token.dropFirst())
                guard !flags.isEmpty else { throw CommandError("不支持单独的 -。") }
                var offset = 0
                while offset < flags.count {
                    let flag = flags[offset]
                    if forbiddenOptions.contains(flag) {
                        throw CommandError("请移除 -\(flag)：应用需要直接管理前台 SSH 隧道，不支持后台运行、远程命令或复用控制命令。")
                    }
                    if Self.valueOptions.contains(flag) {
                        let value: String
                        if offset + 1 < flags.count {
                            value = String(flags[(offset + 1)...])
                        } else {
                            index += 1
                            guard index < tokens.count else { throw CommandError("-\(flag) 缺少参数。") }
                            value = tokens[index]
                        }
                        guard !value.isEmpty else { throw CommandError("-\(flag) 的参数不能为空。") }
                        if "LDR".contains(flag) {
                            forwards.append(try Self.forward(flag, value))
                        } else if flag == "p" {
                            _ = try Self.port(value)
                        } else if flag == "o" {
                            let parts = value.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0.isWhitespace })
                            guard parts.count == 2 else { throw CommandError("-o 需要选项名和取值，例如 -o AddressFamily=inet。") }
                            let key = String(parts[0]).lowercased()
                            let spec = String(parts[1]).trimmingCharacters(in: .whitespaces)
                            if let forwardFlag = ["localforward": Character("L"), "remoteforward": "R", "dynamicforward": "D"][key] {
                                // Config-style LocalForward uses a space between the
                                // listening endpoint and the forwarding destination.
                                let normalized = spec.split(whereSeparator: \.isWhitespace).joined(separator: ":")
                                forwards.append(try Self.forward(forwardFlag, normalized))
                            }
                        }
                        let expanded = (flag == "i" || flag == "F" || flag == "I")
                            ? (value as NSString).expandingTildeInPath : value
                        args += ["-\(flag)", expanded]
                        break
                    }
                    guard simpleOptions.contains(flag) else { throw CommandError("不支持 SSH 参数 -\(flag)。") }
                    // Our verbosity and session flags are deterministic; -q would
                    // otherwise hide the forward-establishment acknowledgment.
                    if !"NnTqv".contains(flag) { args.append("-\(flag)") }
                    offset += 1
                }
            } else {
                guard host == nil, !token.isEmpty, !token.hasPrefix("-"),
                      !token.contains(where: \.isWhitespace) else {
                    throw CommandError("只支持一个 SSH 目标；请移除远程命令或 shell 运算符。")
                }
                host = token
            }
            index += 1
        }
        guard let host else { throw CommandError("请填写 SSH 目标，例如 user@server 或 ~/.ssh/config 中的别名。") }
        guard !forwards.isEmpty else { throw CommandError("请在命令中添加端口，例如 -L 8080:localhost:80 或 -D 1080。") }
        let local = forwards.filter { $0.flag != "R" }.map(\.port)
        guard Set(local).count == local.count else { throw CommandError("同一命令重复使用了本地端口。") }
        self.destination = host
        self.userArguments = args
        self.forwards = forwards
    }

    private static func forward(_ flag: Character, _ specification: String) throws -> Forward {
        let parts = try forwardComponents(specification)
        let listen: String
        if flag == "D" || (flag == "R" && parts.count <= 2) {
            guard (1...2).contains(parts.count) else { throw CommandError("无法识别端口：\(specification)") }
            listen = parts.last!
        } else {
            guard parts.count == 3 || parts.count == 4 else {
                throw CommandError("请使用 TCP 端口格式：[绑定地址:]端口:目标主机:目标端口。")
            }
            listen = parts[parts.count - 3]
            guard !parts[parts.count - 2].isEmpty else { throw CommandError("转发目标主机不能为空。") }
            _ = try port(parts.last!)
        }
        return Forward(flag: flag, port: try port(listen))
    }

    static func forwardComponents(_ specification: String) throws -> [String] {
        var parts: [String] = []
        var part = ""
        var bracket = false
        for char in specification {
            if char == "[" { bracket = true }
            if char == "]" { bracket = false }
            if char == ":" && !bracket { parts.append(part); part = "" }
            else { part.append(char) }
        }
        parts.append(part)
        guard !bracket else { throw CommandError("IPv6 地址缺少右方括号。") }
        return parts
    }

    private static func port(_ text: String) throws -> Int {
        guard let value = Int(text), (1...65535).contains(value) else {
            throw CommandError("端口必须在 1–65535 之间：\(text)")
        }
        return value
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func render(_ arguments: [String]) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+=,-")
        return arguments.map { argument in
            !argument.isEmpty && argument.unicodeScalars.allSatisfy(safe.contains) ? argument : quote(argument)
        }.joined(separator: " ")
    }

    static func tokenize(_ text: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var started = false
        for char in text {
            if escaping {
                if quote == "\"" && !"\"\\$`\n".contains(char) { current.append("\\") }
                if char != "\n" { current.append(char); started = true }
                escaping = false
            } else if char == "\\" && quote != "'" {
                escaping = true
                started = true
            } else if let active = quote {
                if char == active { quote = nil } else { current.append(char) }
            } else if char == "'" || char == "\"" {
                quote = char
                started = true
            } else if char.isWhitespace {
                if started { tokens.append(current); current = ""; started = false }
            } else if ";&|<>`".contains(char) {
                throw CommandError("请输入 SSH 命令本身，不要加 shell 运算符。")
            } else {
                current.append(char)
                started = true
            }
        }
        guard quote == nil, !escaping else { throw CommandError("命令中的引号或反斜杠没有结束。") }
        if started { tokens.append(current) }
        return tokens
    }
}

struct CommandError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
