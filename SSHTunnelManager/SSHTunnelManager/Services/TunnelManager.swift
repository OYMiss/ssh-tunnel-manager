import Foundation
import Observation

struct TunnelStatus: Equatable {
    enum Phase { case stopped, connecting, connected, waiting, stopping }
    var phase: Phase = .stopped
    var message: String = "已停止"
}

/// All state changes run on the main actor. Each tunnel has exactly one worker;
/// cancelling that worker requests a restart, but its replacement is not created
/// until stop() has reaped the old process group and drained its stderr.
@Observable @MainActor
final class TunnelManager {
    typealias ProcessFactory = @MainActor (SSHCommand) throws -> any TunnelProcess
    struct Timing {
        var poll: Duration = .milliseconds(100)
        var startupTimeout: TimeInterval = 45
        var retry: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]
    }

    private(set) var tunnels: [Tunnel] = []
    private(set) var isLoaded = false
    private(set) var statuses: [UUID: TunnelStatus] = [:]
    var errorMessage: String?
    private let store: ConfigStore
    private let factory: ProcessFactory
    private let timing: Timing
    private let useRegistry: Bool
    @ObservationIgnored private var registry: ProcessRegistry?
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var online = true
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var shuttingDown = false

    init(store: ConfigStore = ConfigStore(), useRegistry: Bool = true, timing: Timing = Timing(),
         factory: @escaping ProcessFactory = { try SSHProcess(arguments: $0.arguments, remoteForwards: $0.remoteForwardCount) }) {
        self.store = store
        self.useRegistry = useRegistry
        self.factory = factory
        self.timing = timing
    }

    func start() async throws {
        guard !isLoaded else { return }
        if useRegistry {
            let registry = try ProcessRegistry(directory: store.directory)
            self.registry = registry
            try await registry.recover()
        }
        try Task.checkCancellation()
        tunnels = try store.load()
        isLoaded = true
        for tunnel in tunnels where tunnel.enabled { reconcile(tunnel.id) }
    }

    func status(for tunnel: Tunnel) -> TunnelStatus { statuses[tunnel.id] ?? TunnelStatus() }

    @discardableResult
    func save(command: String, name: String? = nil, replacing id: UUID? = nil) throws -> UUID {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try SSHCommand(command)
        guard isLoaded, !shuttingDown else { throw CommandError("配置尚未加载。") }
        var updated = tunnels
        let tunnelID: UUID
        if let id, let index = updated.firstIndex(where: { $0.id == id }) {
            updated[index].command = command
            if let name { updated[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
            tunnelID = id
        } else {
            let new = Tunnel(name: name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", command: command)
            updated.append(new)
            tunnelID = new.id
        }
        try store.save(updated)
        let old = tunnels.first { $0.id == tunnelID }
        tunnels = updated
        if old?.command != command { reconcile(tunnelID) }
        return tunnelID
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard isLoaded, !shuttingDown, let index = tunnels.firstIndex(where: { $0.id == id }) else { return }
        var updated = tunnels
        updated[index].enabled = enabled
        do {
            try store.save(updated)
            tunnels = updated
            reconcile(id)
        } catch { errorMessage = "无法保存配置：\(error.localizedDescription)" }
    }

    func delete(_ id: UUID) {
        let updated = tunnels.filter { $0.id != id }
        do {
            try store.save(updated)
            tunnels = updated
            reconcile(id)
        } catch { errorMessage = "无法保存配置：\(error.localizedDescription)" }
    }

    func networkChanged(available: Bool) {
        online = available
        for tunnel in tunnels where tunnel.enabled { reconcile(tunnel.id) }
    }

    func setSleeping(_ value: Bool) {
        sleeping = value
        for tunnel in tunnels where tunnel.enabled { reconcile(tunnel.id) }
    }

    private func wantsConnection(_ id: UUID) -> Bool {
        !shuttingDown && online && !sleeping && tunnels.contains { $0.id == id && $0.enabled }
    }

    private func reconcile(_ id: UUID) {
        if let task = workers[id] {
            // Keep the slot until teardown completes. Multiple rapid changes
            // only cancel this same worker, never create competing starts.
            task.cancel()
            statuses[id] = TunnelStatus(phase: .stopping, message: "正在释放端口…")
        } else if wantsConnection(id) {
            launchWorker(id)
        } else {
            setIdleStatus(id)
        }
    }

    private func setIdleStatus(_ id: UUID) {
        guard let tunnel = tunnels.first(where: { $0.id == id }) else { statuses[id] = nil; return }
        statuses[id] = tunnel.enabled
            ? TunnelStatus(phase: .waiting, message: sleeping ? "睡眠暂停" : "等待网络…")
            : TunnelStatus()
    }

    private func launchWorker(_ id: UUID) {
        guard workers[id] == nil, wantsConnection(id) else { return }
        workers[id] = Task { [weak self] in
            guard let self else { return }
            await self.run(id)
            self.workers[id] = nil
            if Task.isCancelled {
                if self.wantsConnection(id) { self.launchWorker(id) }
                else { self.setIdleStatus(id) }
            }
        }
    }

    private func run(_ id: UUID) async {
        var failures = 0
        while !Task.isCancelled, wantsConnection(id), let tunnel = tunnels.first(where: { $0.id == id }) {
            let command: SSHCommand
            do { command = try SSHCommand(tunnel.command) }
            catch {
                statuses[id] = TunnelStatus(phase: .waiting, message: error.localizedDescription)
                return // Invalid configuration needs an edit, not a retry storm.
            }
            statuses[id] = TunnelStatus(phase: .connecting, message: "正在连接…")
            let session: any TunnelProcess
            do { session = try factory(command) }
            catch {
                statuses[id] = TunnelStatus(phase: .waiting, message: "无法启动 SSH：\(error.localizedDescription)")
                if !(await backoff(failures)) { return }
                failures += 1
                continue
            }
            if let registry {
                do {
                    guard let identity = session.identity else { throw CommandError("无法读取 SSH 进程身份。") }
                    try registry.register(identity)
                } catch {
                    await session.stop()
                    if let identity = session.identity { registry.remove(identity) }
                    guard !Task.isCancelled, wantsConnection(id) else { return }
                    statuses[id] = TunnelStatus(phase: .waiting, message: error.localizedDescription)
                    if !(await backoff(failures)) { return }
                    failures += 1
                    continue
                }
            }
            let began = Date()
            var connectedAt: Date?
            var timedOut = false
            while !session.hasExited {
                if Task.isCancelled || !wantsConnection(id) {
                    await session.stop()
                    break
                }
                if session.isReady && connectedAt == nil {
                    connectedAt = Date()
                    statuses[id] = TunnelStatus(phase: .connected, message: "已连接")
                }
                if connectedAt == nil && Date().timeIntervalSince(began) > timing.startupTimeout {
                    timedOut = true
                    await session.stop()
                    break
                }
                do { try await Task.sleep(for: timing.poll) }
                catch { await session.stop(); break }
            }
            let result = await session.wait()
            if let identity = session.identity { registry?.remove(identity) }
            guard !Task.isCancelled, wantsConnection(id) else { return }
            if let connectedAt, Date().timeIntervalSince(connectedAt) > 30 { failures = 0 }
            let reason = timedOut ? "SSH 连接超时" : Self.failure(result)
            statuses[id] = TunnelStatus(phase: .waiting, message: "\(reason) · 自动重试中")
            if !(await backoff(failures)) { return }
            failures += 1
        }
    }

    private func backoff(_ attempt: Int) async -> Bool {
        do {
            try await Task.sleep(for: timing.retry[min(attempt, timing.retry.count - 1)])
            return !Task.isCancelled
        } catch { return false }
    }

    private static func failure(_ result: ProcessResult) -> String {
        let text = result.diagnostic.lowercased()
        if text.contains("address already in use") || text.contains("cannot listen to port") {
            return "端口已被占用（未终止其他程序）"
        }
        if text.contains("remote port forwarding failed") { return "服务器上的转发端口被占用或未获允许" }
        if text.contains("permission denied") { return "SSH 认证失败，请检查密钥或 ssh-agent" }
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") {
            return "请先在终端确认 SSH 主机密钥"
        }
        return result.diagnostic.split(whereSeparator: \.isNewline).last.map(String.init)
            ?? "SSH 已断开（\(result.status)）"
    }

    func shutdown() async {
        shuttingDown = true
        let tasks = Array(workers.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        registry = nil
    }
}
