import SwiftUI

struct StatusIndicator: View {
    let phase: TunnelStatus.Phase
    private var color: Color {
        switch phase {
        case .connected: .green
        case .connecting, .waiting: .orange
        case .stopping, .stopped: .secondary
        }
    }
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}
