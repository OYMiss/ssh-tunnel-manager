import Foundation
import Network

/// Every path update invalidates the old transport, even if both networks have
/// internet access. Debounce the new path so DHCP/VPN transitions don't spawn a
/// succession of SSH processes. SSH keepalives cover changes not reported here.
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private var stopped = false
    private var settleTask: Task<Void, Never>?
    private let changed: @MainActor (Bool) -> Void

    init(changed: @escaping @MainActor (Bool) -> Void) {
        self.changed = changed
    }
    func start() {
        changed(false)
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.receive(available) }
        }
        monitor.start(queue: DispatchQueue(label: "SSHTunnelManager.network"))
    }
    private func receive(_ available: Bool) {
        guard !stopped else { return }
        settleTask?.cancel()
        changed(false)
        guard available else { return }
        settleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            self?.changed(true)
        }
    }
    func refresh() { receive(monitor.currentPath.status == .satisfied) }
    func stop() {
        stopped = true
        monitor.cancel()
        settleTask?.cancel()
    }
}
