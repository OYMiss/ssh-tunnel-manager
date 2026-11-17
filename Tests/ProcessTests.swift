import XCTest
import Darwin
@testable import SSHTunnelCore

@MainActor
final class ProcessTests: XCTestCase {
    func testCancelledStopStillReapsUncooperativeProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = try SSHProcess(arguments: ["-c", "trap '' TERM; sleep 60 & echo $! > '\(marker.path)'; echo 'debug1: Entering interactive session.' >&2; wait"], executable: "/bin/sh", stopGrace: .milliseconds(100))
        try await eventually { process.isReady && FileManager.default.fileExists(atPath: marker.path) }
        let child = Int32(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        let parent = try XCTUnwrap(process.identity)
        let stopping = Task { await process.stop() }
        stopping.cancel()
        await stopping.value
        XCTAssertTrue(process.hasExited)
        XCTAssertNil(ProcessIdentity.read(pid: parent.pid))
        try await eventually { ProcessIdentity.read(pid: child) == nil }
        // Idempotent: a delayed repeated stop cannot signal a reused PID.
        await process.stop()
    }

    func testLeaderExitCleansChildrenHoldingStderr() async throws {
        let process = try SSHProcess(arguments: ["-c", "sleep 60 & echo 'child started' >&2; exit 7"], executable: "/bin/sh")
        let started = Date()
        let result = await process.wait()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.diagnostic.contains("child started"))
    }

    func testVerboseStderrIsDrainedWhileRunning() async throws {
        let script = "i=0; while [ $i -lt 12000 ]; do echo 'debug1: a line of diagnostics that exceeds the pipe buffer' >&2; i=$((i+1)); done; echo 'debug1: Entering interactive session.' >&2; sleep 60"
        let process = try SSHProcess(arguments: ["-c", script], executable: "/bin/sh")
        try await eventually { process.isReady }
        await process.stop()
        XCTAssertTrue(process.hasExited)
    }

    func testRegistryRejectsSecondInstanceAndIgnoresReusedPID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let actual = try SSHProcess(arguments: ["-c", "sleep 60"], executable: "/bin/sh")
        let identity = try XCTUnwrap(actual.identity)
        let stale = ProcessIdentity(pid: identity.pid, seconds: identity.seconds + 1, microseconds: identity.microseconds, executable: "/usr/bin/ssh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([stale]).write(to: directory.appendingPathComponent("owned-processes.json"))
        var registry: ProcessRegistry? = try ProcessRegistry(directory: directory)
        XCTAssertThrowsError(try ProcessRegistry(directory: directory))
        try await registry?.recover()
        XCTAssertFalse(actual.hasExited)
        registry = nil
        let next = try ProcessRegistry(directory: directory)
        try await next.recover()
        await actual.stop()
    }
}
