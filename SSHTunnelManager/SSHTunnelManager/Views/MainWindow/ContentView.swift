import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(TunnelManager.self) private var manager
    @State private var editor: EditorRequest?
    @State private var deleting: Tunnel?

    private struct EditorRequest: Identifiable {
        let id = UUID()
        var tunnel: Tunnel?
    }

    var body: some View {
        VStack(spacing: 0) {
            if !manager.isLoaded {
                ContentUnavailableView("无法加载隧道", systemImage: "network", description: Text(manager.errorMessage ?? "正在加载…"))
            } else if manager.tunnels.isEmpty {
                ContentUnavailableView {
                    Label("添加一条隧道", systemImage: "network")
                } description: {
                    Text("选择本地、远程或动态，填好目标和端口即可。")
                } actions: {
                    Button("添加隧道") { editor = EditorRequest() }
                }
            } else {
                TunnelListView(edit: { editor = EditorRequest(tunnel: $0) }, delete: { deleting = $0 })
            }
        }
        .frame(minWidth: 620, minHeight: 340)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加隧道", systemImage: "plus") { editor = EditorRequest() }
                    .disabled(!manager.isLoaded)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(item: $editor) { request in
            TunnelDetailView(original: request.tunnel)
                .environment(manager)
        }
        .confirmationDialog("删除这条隧道？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let deleting { manager.delete(deleting.id) }
                deleting = nil
            }
        } message: {
            Text("连接会停止，并释放它的端口。")
        }
        .alert("无法完成操作", isPresented: Binding(
            get: { manager.errorMessage != nil && manager.isLoaded },
            set: { if !$0 { manager.errorMessage = nil } }
        )) {
            Button("好") { manager.errorMessage = nil }
        } message: { Text(manager.errorMessage ?? "") }
    }
}
