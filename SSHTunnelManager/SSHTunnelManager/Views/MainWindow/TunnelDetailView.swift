import SwiftUI

@MainActor
struct TunnelDetailView: View {
    private enum Mode: String, CaseIterable { case simple = "简单配置", manual = "手动命令" }
    private enum Field: Hashable { case destination, command }

    let original: Tunnel?
    private let initialSetup: TunnelSetup?
    @Environment(TunnelManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    @State private var setup: TunnelSetup
    @State private var name: String
    @State private var command: String
    @State private var lastGeneratedCommand: String?
    @State private var modeMessage: String?
    @State private var saveError: String?
    @FocusState private var focused: Field?

    init(original: Tunnel?) {
        self.original = original
        let setup = original.flatMap { try? TunnelSetup(command: SSHCommand($0.command)) }
        initialSetup = setup
        _setup = State(initialValue: setup ?? TunnelSetup())
        _mode = State(initialValue: original == nil || setup != nil ? .simple : .manual)
        _name = State(initialValue: original?.name ?? "")
        _command = State(initialValue: original?.command ?? "")
    }

    private var currentCommand: String {
        get throws {
            if mode == .manual { return command }
            // Opening and saving a form without edits must not restart a live tunnel.
            if setup == initialSetup, let original { return original.command }
            return try setup.validatedCommand()
        }
    }
    private var validation: Result<SSHCommand, Error> { Result { try SSHCommand(currentCommand) } }
    private var parsed: SSHCommand? { try? validation.get() }
    private var isEmpty: Bool {
        mode == .simple ? setup.destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? "添加隧道" : "编辑隧道").font(.headline)
            Picker("配置方式", selection: Binding(get: { mode }, set: switchMode)) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("连接名称（可选）", prompt: "留空使用 SSH 目标", text: $name)
                        .textFieldStyle(.roundedBorder)
                    if mode == .simple { simpleEditor } else { commandEditor }
                    if let modeMessage { Text(modeMessage).font(.caption).foregroundStyle(.orange) }
                    if case .failure(let error) = validation, !isEmpty {
                        Text(error.localizedDescription).foregroundStyle(.orange).font(.caption)
                    }
                    connectionHelp
                }
                .padding(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 390)

            Divider()
            Text("保存后打开连接开关。网络恢复时会自动重连。")
                .font(.caption).foregroundStyle(.secondary)
            if let saveError { Text(saveError).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try manager.save(command: currentCommand, name: name, replacing: original?.id); dismiss() }
                    catch { saveError = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsed == nil)
            }
        }
        .padding(24)
        .frame(width: 600)
        .onAppear { focused = mode == .manual ? .command : .destination }
    }

    private var simpleEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("类型", selection: Binding(get: { setup.kind }, set: { setup.changeKind(to: $0) })) {
                ForEach(TunnelSetup.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(setup.kind.explanation).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SSH 目标")
                    TextField("user@server 或 SSH 别名", text: $setup.destination)
                        .focused($focused, equals: .destination)
                        .accessibilityLabel("SSH 目标")
                }
                field("SSH 端口（可选）", prompt: "默认 / SSH 配置", text: $setup.sshPort)
                    .frame(width: 150)
            }
            .textFieldStyle(.roundedBorder)

            HStack(alignment: .top, spacing: 12) {
                field(setup.kind == .remote ? "服务器端口" : (setup.kind == .dynamic ? "本地代理端口" : "本地端口"),
                      prompt: setup.kind.defaultListenPort, text: $setup.listenPort)
                    .frame(width: 132)
                if setup.kind != .dynamic {
                    field(setup.kind == .remote ? "这台 Mac 上的服务地址" : "服务器侧的服务地址",
                          prompt: "localhost", text: $setup.targetHost)
                    field("服务端口", prompt: setup.kind.defaultTargetPort, text: $setup.targetPort)
                        .frame(width: 100)
                } else { Spacer() }
            }
            .textFieldStyle(.roundedBorder)

            Text(usageHint).font(.caption).foregroundStyle(.secondary)
            if !setup.preservedArguments.isEmpty {
                Text("已保留原命令的其他连接选项，可在「手动命令」中查看。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("查看生成的命令") {
                Text((try? currentCommand) ?? setup.draftCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
    }

    private var usageHint: String {
        switch setup.kind {
        case .local:
            "连接后，在这台 Mac 访问 localhost:\(setup.listenPort)。服务地址是从 SSH 服务器访问的地址。"
        case .remote:
            "连接后，在 SSH 服务器访问 localhost:\(setup.listenPort)。例如将 Mac 上的 localhost:3000 转发过去。"
        case .dynamic:
            "连接后，在需要代理的应用中设置 SOCKS5：127.0.0.1，端口 \(setup.listenPort)。"
        }
    }

    private var commandEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH 命令")
            TextEditor(text: $command)
                .font(.system(.body, design: .monospaced))
                .focused($focused, equals: .command)
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                .accessibilityLabel("SSH 命令")
            if let parsed {
                Text(parsed.portSummary).font(.system(.body, design: .monospaced))
            } else if isEmpty {
                Text("例如 ssh -N -L 8080:localhost:80 user@server\n或 ssh -N -D 1080 my-server")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("多个转发、指定密钥（-i）或跳板机（-J），都可以直接写在这里。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connectionHelp: some View {
        DisclosureGroup("首次连接帮助") {
            VStack(alignment: .leading, spacing: 10) {
                Text("1. 复制登录命令，粘贴到终端，先确认能登录服务器。\n2. 首次连接时确认服务器指纹；登录成功后输入 exit 退出。\n3. 用 SSH 密钥或 ssh-agent 配好免密码登录，再打开隧道开关。")
                Text("这里沿用 ~/.ssh/config 中的别名、密钥和跳板机设置。需要手动 setup 时在终端完成。")
                    .foregroundStyle(.secondary)
                Button("复制登录命令", systemImage: "doc.on.doc") {
                    guard let parsed else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(parsed.loginCommand, forType: .string)
                }
                .disabled(parsed == nil)
                .help("登录检查不打开转发端口，可以与已有隧道同时使用。")
            }
            .font(.caption)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextField(prompt, text: text).accessibilityLabel(title)
        }
    }

    private func switchMode(_ next: Mode) {
        guard next != mode else { return }
        modeMessage = nil
        if next == .manual {
            command = (try? currentCommand) ?? setup.draftCommand
            lastGeneratedCommand = command
        } else if command != lastGeneratedCommand, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { setup = try TunnelSetup(command: SSHCommand(command)) }
            catch { modeMessage = error.localizedDescription; return }
        }
        mode = next
        focused = next == .manual ? .command : .destination
    }
}
