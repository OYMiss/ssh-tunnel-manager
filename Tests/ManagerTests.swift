import XCTest
@testable import SSHTunnelCore

@MainActor
func eventually(timeout: TimeInterval = 4, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > end { XCTFail("Timed out", file: file, line: line); throw CommandError("Test timeout") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
final class FakeProcess: TunnelProcess {
    var isReady = true
    var hasExited = false
    var identity: ProcessIdentity? { nil }
    private var waiters: [CheckedContinuation<ProcessResult, Never>] = []
    private var stopTask: Task<Void, Never>?
    private var result = ProcessResult(status: 0, diagnostic: "")
    func wait() async -> ProcessResult {
        if hasExited { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func finish(_ error: String = "") {
        guard !hasExited else { return }
        result = ProcessResult(status: 255, diagnostic: error)
        hasExited = true
        for waiter in waiters { waiter.resume(returning: result) }
        waiters = []
    }
    func stop() async {
        if stopTask == nil {
            stopTask = Task {
                try? await Task.sleep(for: .milliseconds(80))
                finish()
            }
        }
        await stopTask?.value
    }
}

@MainActor
final class FakeFactory {
    var processes: [FakeProcess] = []
    var highWater = 0
    func launch(_: SSHCommand) -> any TunnelProcess {
        let process = FakeProcess()
        processes.append(process)
        highWater = max(highWater, processes.filter { !$0.hasExited }.count)
        return process
    }
}

@MainActor
final class ManagerTests: XCTestCase {
    private func fixture() async throws -> (TunnelManager, FakeFactory, UUID, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(directory: directory)
        let tunnel = Tunnel(command: "ssh -D1080 test-alias", enabled: true)
        try store.save([tunnel])
        let factory = FakeFactory()
        let manager = TunnelManager(store: store, useRegistry: false,
            timing: .init(poll: .milliseconds(5), startupTimeout: 2, retry: [.milliseconds(100)]), factory: factory.launch)
        try await manager.start()
        try await eventually { factory.processes.count == 1 && manager.status(for: tunnel).phase == .connected }
        return (manager, factory, tunnel.id, directory)
    }

    func testRapidOffOnNeverOverlapsProcesses() async throws {
        let (manager, factory, id, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<50 { manager.setEnabled(false, for: id); manager.setEnabled(true, for: id) }
        try await eventually { factory.processes.count == 2 }
        XCTAssertTrue(factory.processes[0].hasExited)
        XCTAssertEqual(factory.highWater, 1)
        await manager.shutdown()
        XCTAssertTrue(factory.processes.allSatisfy(\.hasExited))
    }

    func testNetworkChangesAreSerializedAndPreserveIntent() async throws {
        let (manager, factory, id, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<20 {
            manager.networkChanged(available: false)
            manager.networkChanged(available: true)
        }
        try await eventually { factory.processes.count == 2 }
        XCTAssertEqual(factory.highWater, 1)
        manager.networkChanged(available: false)
        try await eventually { factory.processes.allSatisfy(\.hasExited) }
        XCTAssertTrue(manager.tunnels.first!.enabled)
        let count = factory.processes.count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(factory.processes.count, count)
        manager.networkChanged(available: true)
        try await eventually { factory.processes.count == count + 1 }
        manager.setEnabled(false, for: id)
        await manager.shutdown()
        XCTAssertFalse(try ConfigStore(directory: directory).load().first!.enabled)
    }

    func testEditAndDeleteDuringConnectCleanUp() async throws {
        let (manager, factory, id, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        factory.processes[0].isReady = false
        try manager.save(command: "ssh -D1081 changed-alias", replacing: id)
        try await eventually { factory.processes.count == 2 }
        XCTAssertTrue(factory.processes[0].hasExited)
        XCTAssertEqual(factory.highWater, 1)
        factory.processes[1].isReady = false
        manager.delete(id)
        try await eventually { factory.processes.allSatisfy(\.hasExited) }
        XCTAssertTrue(manager.tunnels.isEmpty)
        await manager.shutdown()
    }

    func testStopDuringRetryNeverResurrectsTunnel() async throws {
        let (manager, factory, id, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        factory.processes[0].finish("connection reset")
        try await eventually { manager.status(for: manager.tunnels[0]).phase == .waiting }
        manager.setEnabled(false, for: id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(factory.processes.count, 1)
        XCTAssertEqual(manager.status(for: manager.tunnels[0]).phase, .stopped)
        await manager.shutdown()
    }

    func testSleepPausesAndWakeResumes() async throws {
        let (manager, factory, _, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        manager.setSleeping(true)
        try await eventually { factory.processes[0].hasExited }
        XCTAssertTrue(manager.tunnels[0].enabled)
        manager.setSleeping(false)
        try await eventually { factory.processes.count == 2 }
        XCTAssertEqual(factory.highWater, 1)
        await manager.shutdown()
    }
}
