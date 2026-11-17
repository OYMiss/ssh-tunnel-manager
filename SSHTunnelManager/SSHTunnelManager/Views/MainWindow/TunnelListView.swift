import SwiftUI

@MainActor
struct TunnelListView: View {
    @Environment(TunnelManager.self) private var manager
    var edit: (Tunnel) -> Void
    var delete: (Tunnel) -> Void

    var body: some View {
        List {
            ForEach(manager.tunnels) { tunnel in
                let status = manager.status(for: tunnel)
                HStack(alignment: .top, spacing: 12) {
                    StatusIndicator(phase: status.phase)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(tunnel.displayName).font(.headline)
                            Text(tunnel.portSummary)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(tunnel.command)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Text(status.message)
                            .font(.caption)
                            .foregroundStyle(status.phase == .waiting ? .orange : .secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("编辑", systemImage: "pencil") { edit(tunnel) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("编辑隧道")
                    Toggle("连接 \(tunnel.displayName)", isOn: Binding(
                        get: { tunnel.enabled },
                        set: { manager.setEnabled($0, for: tunnel.id) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(.vertical, 8)
                .contextMenu {
                    Button("编辑隧道", systemImage: "pencil") { edit(tunnel) }
                    Button("复制命令", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tunnel.command, forType: .string)
                    }
                    Divider()
                    Button("删除", systemImage: "trash", role: .destructive) { delete(tunnel) }
                }
            }
        }
        .listStyle(.inset)
    }
}
