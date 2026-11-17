import SwiftUI

@MainActor
struct MenuBarView: View {
    @Environment(TunnelManager.self) private var manager
    @Environment(\.openWindow) private var openWindow

    private var connectedCount: Int {
        manager.tunnels.filter { manager.status(for: $0).phase == .connected }.count
    }

    var body: some View {
        if !manager.isLoaded {
            Text(manager.errorMessage == nil ? "正在载入…" : "配置需要检查")
        } else if manager.tunnels.isEmpty {
            Text("暂无隧道")
        } else {
            Text("已连接 \(connectedCount) / \(manager.tunnels.count)")
            ForEach(manager.tunnels) { tunnel in
                let status = manager.status(for: tunnel)
                Toggle(isOn: Binding(
                    get: { tunnel.enabled },
                    set: { manager.setEnabled($0, for: tunnel.id) }
                )) {
                    Label {
                        Text(compactTitle(for: tunnel))
                    } icon: {
                        Image(systemName: symbol(for: status.phase))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(color(for: status.phase))
                    }
                }
                .help("\(tunnel.displayName)\n\(tunnel.portSummary)\n\(status.message)")
                .accessibilityLabel("\(tunnel.displayName)，\(tunnel.portSummary)")
                .accessibilityValue("\(tunnel.enabled ? "开启" : "关闭")，\(status.message)")
            }
        }
        Divider()
        Button("管理隧道…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("退出") { requestAppTermination() }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func compactTitle(for tunnel: Tunnel) -> String {
        // Native menus size to their titles; keep long aliases and many forwards
        // from stretching the entire menu. Full details remain in the tooltip.
        let name = tunnel.displayName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let shortName = name.count > 28 ? String(name.prefix(18)) + "…" + String(name.suffix(9)) : name
        guard let forwards = tunnel.parsed?.forwards, !forwards.isEmpty else { return shortName }
        let ports = forwards.prefix(2).map { String($0.port) }.joined(separator: ", ")
        let remainder = forwards.count > 2 ? " +\(forwards.count - 2)" : ""
        return "\(shortName)  ·  \(ports)\(remainder)"
    }

    private func symbol(for phase: TunnelStatus.Phase) -> String {
        switch phase {
        case .connected: "circle.fill"
        case .connecting: "ellipsis.circle"
        case .waiting: "arrow.clockwise.circle"
        case .stopping: "minus.circle"
        case .stopped: "circle"
        }
    }

    private func color(for phase: TunnelStatus.Phase) -> Color {
        switch phase {
        case .connected: .green
        case .connecting, .waiting: .orange
        case .stopping, .stopped: .secondary
        }
    }
}
