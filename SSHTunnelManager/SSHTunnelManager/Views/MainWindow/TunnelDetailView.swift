import SwiftUI
import AppKit

@MainActor
struct TunnelDetailView: View {
    let tunnel: Tunnel
    @Environment(TunnelManager.self) private var tunnelManager
    @FocusState private var focusedField: Field?

    @State private var editedTunnel: Tunnel
    @State private var sshCommandText: String
    @State private var sshCommandError: String?
    @State private var sshCommandNotice: String?
    // Derived from the working copy vs the saved tunnel, so it can never drift
    // out of sync with the actual edits (or with an immediate structural save).
    private var hasChanges: Bool { editedTunnel != tunnel }
    // Jump host is a rare power-user knob — keep it collapsed by default so it
    // doesn't crowd the common case, but auto-expand it when one is already set.
    @State private var showJumpHost: Bool

    enum Field: Hashable {
        case name, host, port, identityFile
        case mappingLocalHost(UUID), mappingLocalPort(UUID)
        case mappingRemoteHost(UUID), mappingRemotePort(UUID)
        case connectTimeout, aliveInterval, aliveCountMax
        case proxyJump, extraSSHArguments
    }

    init(tunnel: Tunnel) {
        self.tunnel = tunnel
        self._editedTunnel = State(initialValue: tunnel)
        self._sshCommandText = State(initialValue: Self.sshCommand(for: tunnel))
        self._showJumpHost = State(initialValue: !(tunnel.proxyJump ?? "").isEmpty)
    }

    private var status: ConnectionStatus {
        tunnelManager.status(for: tunnel)
    }

    private var statusText: String {
        switch status {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        }
    }

    private var statusColor: Color {
        switch status {
        case .disconnected: return .secondary
        case .connecting: return .yellow
        case .connected: return .green
        }
    }

    /// Why the tunnel last failed/dropped, while it isn't up. Drives the red
    /// "Failed" state and the reason row below the status line.
    private var lastError: String? {
        tunnelManager.lastError(for: tunnel)
    }

    /// Local ports this tunnel shares with others — checked against the live
    /// edits so the warning updates as you type a port number.
    private var portConflicts: [(port: Int, names: [String])] {
        tunnelManager.localPortConflicts(for: editedTunnel)
            .sorted { $0.key < $1.key }
            .map { (port: $0.key, names: $0.value) }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    StatusIndicator(status: status, isFailed: lastError != nil)
                    Text(lastError != nil ? "Failed" : statusText)
                        .foregroundStyle(lastError != nil ? .red : statusColor)

                    Spacer()

                    Button(status != .disconnected ? "Disconnect" : "Connect") {
                        if hasChanges {
                            saveChanges()
                        }
                        tunnelManager.toggle(tunnel: editedTunnel)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(status != .disconnected ? .red : .green)
                }

                if let lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }

                SSHCommandEditor(
                    command: $sshCommandText,
                    error: $sshCommandError,
                    onCopy: { copySSHCommand() },
                    onApply: { applySSHCommand() }
                )
            } header: {
                Text("Status")
            }

            Section {
                TextField("Name", text: $editedTunnel.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
            } header: {
                Text("General")
            }

            Section {
                LabeledContent("Host") {
                    TextField("Host", text: $editedTunnel.host, prompt: Text(""))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($focusedField, equals: .host)
                }

                LabeledContent("Port") {
                    TextField("Port", text: sshPortBinding, prompt: Text(""))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 90)
                        .focused($focusedField, equals: .port)
                }

                Text("Leave blank to use SSH’s default port \(Tunnel.defaultSSHPort).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Identity File (optional)", text: Binding(
                    get: { editedTunnel.identityFile ?? "" },
                    set: { editedTunnel.identityFile = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .identityFile)

                Text("e.g., ~/.ssh/id_rsa")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup(isExpanded: $showJumpHost) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("e.g. bastion.example.com", text: Binding(
                            get: { editedTunnel.proxyJump ?? "" },
                            set: { editedTunnel.proxyJump = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .proxyJump)
                        .help("Adds -J <value>. Reaches the host through one or more bastion hosts, replacing a manual multi-hop ssh.")

                        Text("Optional — routes the login through a bastion to reach the host. Only a login path, not the data flow; -L/-R targets still resolve from the final host. A jump-host-specific key/user goes in ~/.ssh/config. Format: user@host[:port][,user@host2…]")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                } label: {
                    // Make the whole label row toggle, not just the chevron —
                    // DisclosureGroup only wires the triangle up by default on macOS.
                    Text("Jump host")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { showJumpHost.toggle() } }
                }
            } header: {
                Text("SSH Connection")
            }

            Section {
                ForEach($editedTunnel.portMappings) { $mapping in
                    PortMappingEditor(
                        mapping: $mapping,
                        focusedField: $focusedField,
                        canRemove: editedTunnel.portMappings.count > 1,
                        onRemove: { removeMapping(mapping.id) }
                    )
                }

                Button {
                    editedTunnel.portMappings.append(PortMapping(
                        localPort: nextLocalPort(),
                        remotePort: nextLocalPort()
                    ))
                } label: {
                    Label("Add Port Mapping", systemImage: "plus")
                }

                ForEach(portConflicts, id: \.port) { conflict in
                    Label(
                        "Local port \(String(conflict.port)) is also used by \(conflict.names.joined(separator: ", ")). Only one tunnel can bind a port at a time.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }
            } header: {
                Text("Port Forwarding")
            } footer: {
                Text("Each mapping adds a -L (local forward), -R (remote forward), or -D (SOCKS proxy) flag to the SSH command.")
            }

            Section {
                Toggle("Auto-connect on launch", isOn: $editedTunnel.autoConnect)
            } header: {
                Text("Options")
            }

            Section {
                LabeledContent("Connect Timeout") {
                    HStack(spacing: 4) {
                        TextField("Connect Timeout", text: Binding(
                            get: { editedTunnel.connectTimeout.map(String.init) ?? "" },
                            set: { editedTunnel.connectTimeout = Int($0) }
                        ), prompt: Text("off"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 70)
                        .focused($focusedField, equals: .connectTimeout)
                        .help("Seconds ssh waits to establish the connection before giving up. Blank = wait indefinitely.")
                        Text("sec").foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Alive Interval") {
                    HStack(spacing: 4) {
                        TextField("Alive Interval", text: Binding(
                            get: { editedTunnel.serverAliveInterval.map(String.init) ?? "" },
                            set: { editedTunnel.serverAliveInterval = Int($0) }
                        ), prompt: Text("\(Tunnel.defaultServerAliveInterval)"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 70)
                        .focused($focusedField, equals: .aliveInterval)
                        .help("Seconds between keepalive probes that detect a dead connection. Blank uses the default (\(Tunnel.defaultServerAliveInterval)).")
                        Text("sec").foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Alive Count Max") {
                    TextField("Alive Count Max", text: Binding(
                        get: { editedTunnel.serverAliveCountMax.map(String.init) ?? "" },
                        set: { editedTunnel.serverAliveCountMax = Int($0) }
                    ), prompt: Text("\(Tunnel.defaultServerAliveCountMax)"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 70)
                    .focused($focusedField, equals: .aliveCountMax)
                    .help("Drop the connection after this many missed keepalive probes. Blank uses the default (\(Tunnel.defaultServerAliveCountMax)).")
                }
            } header: {
                Text("Connection Resilience")
            } footer: {
                Text("A blank field uses its placeholder default; hover a field for what it does. Connect Timeout is off unless set.")
            }

            Section {
                Toggle("Compression", isOn: $editedTunnel.compression)
                    .help("Compress the data stream (-C). Can help on slow links; costs CPU.")

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Survive brief network drops", isOn: $editedTunnel.disableTCPKeepAlive)
                        .help("Sets TCPKeepAlive=no, so a short outage doesn't tear the connection down at the TCP layer; the Alive Interval probes above handle liveness instead.")
                    Text("Keeps the tunnel up through short outages instead of dropping immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Skip host key check", isOn: $editedTunnel.skipHostKeyCheck)
                        .help("Sets StrictHostKeyChecking=no and UserKnownHostsFile=/dev/null.")
                    Text("For hosts recreated on the same address. Disables protection against a changed/spoofed host — use only on trusted networks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Extra SSH arguments", text: Binding(
                        get: { editedTunnel.extraSSHArguments ?? "" },
                        set: { editedTunnel.extraSSHArguments = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .extraSSHArguments)
                    .font(.system(.body, design: .monospaced))

                    Text("Advanced flags that are not modeled above. They are preserved from Apply and passed to ssh before the destination host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            } header: {
                Text("Advanced")
            }

            if status == .connected {
                Section {
                    ForEach(editedTunnel.portMappings) { mapping in
                        switch mapping.forward {
                        case .dynamic:
                            UsageRow(label: "Proxy", value: "\(mapping.localHost):\(mapping.localPort)")
                            UsageRow(label: "socks5h", value: "socks5h://\(mapping.localHost):\(mapping.localPort)")
                            UsageRow(label: "socks5", value: "socks5://\(mapping.localHost):\(mapping.localPort)")
                        case .remote:
                            UsageRow(
                                label: "R :\(mapping.remotePort)",
                                value: "server listens on \(mapping.remoteHost):\(mapping.remotePort) → \(mapping.localHost):\(mapping.localPort) here"
                            )
                        case .local:
                            UsageRow(
                                label: ":\(mapping.localPort)",
                                value: "http://\(mapping.localHost):\(mapping.localPort)"
                            )
                        }
                    }
                } header: {
                    Text("Usage")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = nil
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    saveChanges()
                }
                .disabled(!hasChanges)
            }
        }
        .alert("Unsupported SSH Options", isPresented: Binding(
            get: { sshCommandNotice != nil },
            set: { if !$0 { sshCommandNotice = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(sshCommandNotice ?? "")
        }
        .onChange(of: editedTunnel) { _, newValue in
            sshCommandText = Self.sshCommand(for: newValue)
        }
        .onChange(of: tunnel.id) { _, _ in
            // Reload the editor only when a *different* tunnel is selected — not
            // when this tunnel's own save round-trips back through `tunnel`. The
            // latter would clobber an edit made right after an auto-save (e.g.
            // removing a port mapping just after a field blur saved the prior set).
            editedTunnel = tunnel
            sshCommandText = Self.sshCommand(for: tunnel)
            sshCommandError = nil
        }
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue != nil && newValue != oldValue && hasChanges {
                saveChanges()
            }
        }
    }

    private func removeMapping(_ id: UUID) {
        editedTunnel.portMappings.removeAll { $0.id == id }
        // Persist right away so the sidebar and menu-bar summaries reflect the
        // removal — a structural change shouldn't wait for a field blur to save.
        saveChanges()
    }

    private func nextLocalPort() -> Int {
        let usedPorts = Set(editedTunnel.portMappings.map(\.localPort))
        var port = (editedTunnel.portMappings.map(\.localPort).max() ?? 8079) + 1
        while usedPorts.contains(port) {
            port += 1
        }
        return port
    }

    private func saveChanges() {
        tunnelManager.updateTunnel(editedTunnel)
    }

    private func copySSHCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sshCommandText, forType: .string)
        sshCommandError = nil
    }

    private func applySSHCommand() {
        do {
            let applied = try Self.parseSSHCommand(sshCommandText)
            var updated = editedTunnel
            updated.host = applied.host
            updated.port = applied.port
            updated.portMappings = applied.portMappings
            updated.identityFile = applied.identityFile
            updated.connectTimeout = applied.connectTimeout
            updated.serverAliveInterval = applied.serverAliveInterval
            updated.serverAliveCountMax = applied.serverAliveCountMax
            updated.compression = applied.compression
            updated.disableTCPKeepAlive = applied.disableTCPKeepAlive
            updated.skipHostKeyCheck = applied.skipHostKeyCheck
            updated.extraSSHArguments = applied.extraSSHArguments.isEmpty ? nil : applied.extraSSHArguments.map(Self.shellQuote).joined(separator: " ")
            updated.proxyJump = applied.proxyJump
            editedTunnel = updated
            sshCommandError = nil
            if !applied.extraSSHArguments.isEmpty {
                sshCommandNotice = "Some SSH options are not represented by dedicated GUI fields. They were saved in Advanced > Extra SSH arguments and will still be passed to ssh."
            }
            saveChanges()
        } catch {
            sshCommandError = error.localizedDescription
        }
    }

    private var sshPortBinding: Binding<String> {
        Binding(
            get: {
                if let sshPort = Tunnel.normalizedSSHPort(editedTunnel.port) {
                    return String(sshPort)
                }
                return ""
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                editedTunnel.port = Int(trimmed)
            }
        )
    }

    private static func sshCommand(for tunnel: Tunnel) -> String {
        var cmd = "ssh -N"
        if let port = tunnel.port {
            cmd += " -p \(port)"
        }
        for mapping in tunnel.portMappings {
            switch mapping.forward {
            case .local:
                cmd += " -L \(mapping.localHost):\(mapping.localPort):\(mapping.remoteHost):\(mapping.remotePort)"
            case .remote:
                cmd += " -R \(mapping.remoteHost):\(mapping.remotePort):\(mapping.localHost):\(mapping.localPort)"
            case .dynamic:
                cmd += " -D \(mapping.localHost):\(mapping.localPort)"
            }
        }
        // Neutralize login-oriented alias directives so this command is safe to
        // copy/paste for a forward (mirrors how the app launches the tunnel).
        cmd += " -o RequestTTY=no -o RemoteCommand=none -o ControlMaster=no -o ControlPath=none"
        cmd += " -o ServerAliveInterval=\(tunnel.serverAliveInterval ?? Tunnel.defaultServerAliveInterval)"
        cmd += " -o ServerAliveCountMax=\(tunnel.serverAliveCountMax ?? Tunnel.defaultServerAliveCountMax)"
        cmd += " -o ConnectionAttempts=2 -o BatchMode=yes"
        if let connectTimeout = tunnel.connectTimeout {
            cmd += " -o ConnectTimeout=\(connectTimeout)"
        }
        if tunnel.compression {
            cmd += " -C"
        }
        if tunnel.disableTCPKeepAlive {
            cmd += " -o TCPKeepAlive=no"
        }
        if tunnel.skipHostKeyCheck {
            cmd += " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        }
        if let proxyJump = tunnel.proxyJump?.trimmingCharacters(in: .whitespaces), !proxyJump.isEmpty {
            cmd += " -J \(proxyJump)"
        }
        if let identityFile = tunnel.identityFile, !identityFile.isEmpty {
            cmd += " -i \(identityFile) -o IdentitiesOnly=yes"
        }
        if let extraSSHArguments = tunnel.extraSSHArguments?.trimmingCharacters(in: .whitespacesAndNewlines), !extraSSHArguments.isEmpty {
            cmd += " \(extraSSHArguments)"
        }
        cmd += " \(tunnel.host)"
        return cmd
    }

    private static func parseSSHCommand(_ command: String) throws -> ParsedSSHCommand {
        let tokens = try tokenizeSSHCommand(command)
        guard tokens.first == "ssh" else {
            throw SSHCommandError.invalidPrefix
        }

        var index = 1
        var result = ParsedSSHCommand()
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "-N":
                break
            case "-p":
                index += 1
                guard index < tokens.count else {
                    throw SSHCommandError.missingValue("-p")
                }
                guard let port = Int(tokens[index]) else {
                    throw SSHCommandError.invalidPort(tokens[index])
                }
                result.port = port
            case "-i":
                index += 1
                guard index < tokens.count else { throw SSHCommandError.missingValue("-i") }
                result.identityFile = tokens[index]
            case "-J":
                index += 1
                guard index < tokens.count else { throw SSHCommandError.missingValue("-J") }
                result.proxyJump = tokens[index]
            case "-L", "-R", "-D":
                index += 1
                guard index < tokens.count else { throw SSHCommandError.missingValue(token) }
                let mapping = try parsePortMapping(flag: token, spec: tokens[index])
                result.portMappings.append(mapping)
            case "-C":
                result.compression = true
            case "-o":
                index += 1
                guard index < tokens.count else { throw SSHCommandError.missingValue("-o") }
                if !(try applySSHOption(tokens[index], to: &result)) {
                    result.extraSSHArguments.append(contentsOf: ["-o", tokens[index]])
                }
            default:
                if token.hasPrefix("-") {
                    result.extraSSHArguments.append(token)
                    if index + 1 < tokens.count - 1, !tokens[index + 1].hasPrefix("-") {
                        index += 1
                        result.extraSSHArguments.append(tokens[index])
                    }
                    break
                }
                result.host = token
            }
            index += 1
        }

        guard !result.host.isEmpty else {
            throw SSHCommandError.missingDestination
        }
        guard !result.portMappings.isEmpty else {
            throw SSHCommandError.missingPortForwarding
        }
        return result
    }

    private static func shellQuote(_ token: String) -> String {
        guard !token.isEmpty else { return "''" }
        if token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           token.rangeOfCharacter(from: CharacterSet(charactersIn: "'\\\"")) == nil {
            return token
        }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func applySSHOption(_ option: String, to result: inout ParsedSSHCommand) throws -> Bool {
        let parts = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw SSHCommandError.malformedOption(option)
        }
        let key = parts[0].lowercased()
        let value = String(parts[1])
        switch key {
        case "connecttimeout":
            result.connectTimeout = Int(value)
            return true
        case "serveraliveinterval":
            result.serverAliveInterval = Int(value)
            return true
        case "serveralivecountmax":
            result.serverAliveCountMax = Int(value)
            return true
        case "tcpkeepalive":
            result.disableTCPKeepAlive = value.lowercased() == "no"
            return true
        case "stricthostkeychecking":
            result.skipHostKeyCheck = value.lowercased() == "no"
            return true
        case "userknownhostsfile", "identitiesonly", "requesttty", "remotecommand", "controlmaster", "controlpath", "connectionattempts", "batchmode", "exitonforwardfailure":
            // These are either represented by a higher-level toggle or generated
            // by the app itself, so don't duplicate them in Extra SSH arguments.
            return true
        default:
            return false
        }
    }

    private static func parsePortMapping(flag: String, spec: String) throws -> PortMapping {
        let parts = spec.split(separator: ":").map(String.init)
        switch flag {
        case "-D":
            if parts.count == 1, let localPort = Int(parts[0]) {
                return PortMapping(forward: .dynamic, localPort: localPort, remotePort: 0)
            }
            // Standard shorthand: `bind_address:port` — parts[0] is the bind
            // address, parts[1] is the listen port.
            guard parts.count == 2, let localPort = Int(parts[1]) else {
                throw SSHCommandError.invalidMapping(spec)
            }
            return PortMapping(forward: .dynamic, localHost: parts[0], localPort: localPort, remotePort: 0)
        case "-L":
            if parts.count == 3, let localPort = Int(parts[0]), let remotePort = Int(parts[2]) {
                return PortMapping(localPort: localPort, remotePort: remotePort)
            }
            guard parts.count == 4, let localPort = Int(parts[1]), let remotePort = Int(parts[3]) else {
                throw SSHCommandError.invalidMapping(spec)
            }
            return PortMapping(localHost: parts[0], localPort: localPort, remoteHost: parts[2], remotePort: remotePort)
        case "-R":
            if parts.count == 3, let remotePort = Int(parts[0]), let localPort = Int(parts[2]) {
                // Standard shorthand: `port:host:hostport` — parts[1] is the
                // destination host; the bind address stays at its default.
                return PortMapping(forward: .remote, localHost: parts[1], localPort: localPort, remotePort: remotePort)
            }
            guard parts.count == 4, let remotePort = Int(parts[1]), let localPort = Int(parts[3]) else {
                throw SSHCommandError.invalidMapping(spec)
            }
            return PortMapping(forward: .remote, localHost: parts[2], localPort: localPort, remoteHost: parts[0], remotePort: remotePort)
        default:
            throw SSHCommandError.invalidMapping(spec)
        }
    }

    private static func tokenizeSSHCommand(_ command: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }

            if character == "\\" && quote != "'" {
                escaping = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                continue
            }

            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if escaping {
            throw SSHCommandError.trailingEscape
        }
        if quote != nil {
            throw SSHCommandError.unclosedQuote
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}

private struct ParsedSSHCommand {
    var host: String = ""
    var port: Int?
    var portMappings: [PortMapping] = []
    var identityFile: String?
    var connectTimeout: Int?
    var serverAliveInterval: Int?
    var serverAliveCountMax: Int?
    var compression = false
    var disableTCPKeepAlive = false
    var skipHostKeyCheck = false
    var proxyJump: String?
    var extraSSHArguments: [String] = []
}

private enum SSHCommandError: LocalizedError {
    case invalidPrefix
    case missingValue(String)
    case invalidPort(String)
    case missingDestination
    case missingPortForwarding
    case invalidMapping(String)
    case malformedOption(String)
    case trailingEscape
    case unclosedQuote

    var errorDescription: String? {
        switch self {
        case .invalidPrefix:
            return "The command must start with ssh."
        case .missingValue(let flag):
            return "Missing value for \(flag)."
        case .invalidPort(let value):
            return "Invalid port number: \(value)."
        case .missingDestination:
            return "Missing SSH destination host."
        case .missingPortForwarding:
            return "The SSH command must include at least one port forwarding flag (-L, -R, or -D)."
        case .invalidMapping(let spec):
            return "Couldn’t parse port mapping: \(spec)."
        case .malformedOption(let option):
            return "Couldn’t parse SSH option: \(option)."
        case .trailingEscape:
            return "The command ends with an unfinished escape."
        case .unclosedQuote:
            return "The command has an unclosed quote."
        }
    }
}

@MainActor
private struct SSHCommandEditor: View {
    @Binding var command: String
    @Binding var error: String?
    let onCopy: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SSH Command")
                .foregroundStyle(.secondary)

            TextEditor(text: $command)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary)
                }
                .textSelection(.enabled)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()

                Button {
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)

                Button("Apply") {
                    onApply()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct PortMappingEditor: View {
    @Binding var mapping: PortMapping
    @FocusState.Binding var focusedField: TunnelDetailView.Field?
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Type", selection: $mapping.forward) {
                Text("Local Forward").tag(ForwardType.local)
                Text("Remote Forward").tag(ForwardType.remote)
                Text("SOCKS Proxy").tag(ForwardType.dynamic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LabeledContent(mapping.forward == .dynamic ? "Listen" : "Local") {
                HStack(spacing: 4) {
                    TextField("Host", text: $mapping.localHost)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($focusedField, equals: .mappingLocalHost(mapping.id))
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField("", value: $mapping.localPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .labelsHidden()
                        .focused($focusedField, equals: .mappingLocalPort(mapping.id))
                }
            }

            switch mapping.forward {
            case .local, .remote:
                LabeledContent("Remote") {
                    HStack(spacing: 4) {
                        TextField("Host", text: $mapping.remoteHost)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .focused($focusedField, equals: .mappingRemoteHost(mapping.id))
                        Text(":")
                            .foregroundStyle(.secondary)
                        TextField("", value: $mapping.remotePort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .labelsHidden()
                            .focused($focusedField, equals: .mappingRemotePort(mapping.id))
                    }
                }
                if mapping.forward == .remote {
                    Text("Reverse of a local forward: the server listens on the Remote address and sends connections back to the Local port on this Mac. Set the Remote host to 0.0.0.0 (and enable GatewayPorts on the server) to accept connections from beyond the server itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .dynamic:
                Text("SOCKS5 proxy — point your app or system proxy at this address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if canRemove {
                Button("Remove", role: .destructive) {
                    onRemove()
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

struct UsageRow: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? .green : .secondary)
            .help("Copy to clipboard")
        }
    }
}

#Preview {
    TunnelDetailView(tunnel: Tunnel(
        name: "Test Tunnel",
        host: "user@example.com",
        port: nil,
        portMappings: [
            PortMapping(localPort: 8080, remotePort: 8080),
            PortMapping(localPort: 5432, remotePort: 5432)
        ]
    ))
    .environment(TunnelManager())
    .frame(width: 500, height: 700)
}
