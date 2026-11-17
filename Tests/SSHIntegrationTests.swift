import XCTest
import Darwin
@testable import SSHTunnelCore

private func unusedPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CommandError("socket failed") }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw CommandError("bind failed") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// Isolated loopback HTTP endpoint used to verify data actually passes through
/// the forwarded port, rather than treating any listening socket as connected.
private final class HTTPFixture: @unchecked Sendable {
    let port: Int
    private let source: DispatchSourceRead
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CommandError("socket failed") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else { close(fd); throw CommandError("HTTP bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = Int(UInt16(bigEndian: addr.sin_port))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "test.http"))
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.read(client, &buffer, buffer.count)
            let response = Array("HTTP/1.0 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
            _ = response.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, $0.count) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }
    deinit { source.cancel() }
}

@MainActor
private final class SSHServerFixture {
    let directory: URL
    let port: Int
    private let daemon = Process()
    private let log: FileHandle

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        port = try unusedPort()
        for key in ["host", "client"] {
            let generate = Process()
            generate.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            generate.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", directory.appendingPathComponent(key).path]
            try generate.run()
            generate.waitUntilExit()
            guard generate.terminationStatus == 0 else { throw CommandError("ssh-keygen failed") }
        }
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(directory.path)/host
        PidFile \(directory.path)/pid
        AuthorizedKeysFile \(directory.path)/client.pub
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin yes
        LogLevel ERROR
        """
        let configURL = directory.appendingPathComponent("sshd_config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let logURL = directory.appendingPathComponent("sshd.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try FileHandle(forWritingTo: logURL)
        daemon.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        daemon.arguments = ["-D", "-e", "-f", configURL.path]
        daemon.standardOutput = log
        daemon.standardError = log
        try daemon.run()
    }

    func waitUntilReady() async throws {
        try await eventually {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(self.port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
        }
    }

    func command(forward: String) -> String {
        "ssh -F /dev/null -i '\(directory.path)/client' -p \(port) -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \(forward) \(NSUserName())@127.0.0.1"
    }
    func stop() {
        if daemon.isRunning { daemon.terminate(); daemon.waitUntilExit() }
        try? log.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class SSHIntegrationTests: XCTestCase {
    func testRealSSHNetworkChangesReleaseAndRebindSamePort() async throws {
        let server = try SSHServerFixture()
        addTeardownBlock { await server.stop() }
        try await server.waitUntilReady()
        let http = try HTTPFixture()
        let localPort = try unusedPort()
        let directory = server.directory.appendingPathComponent("app")
        let store = ConfigStore(directory: directory)
        let tunnel = Tunnel(command: server.command(forward: "-L127.0.0.1:\(localPort):127.0.0.1:\(http.port)"), enabled: true)
        try store.save([tunnel])
        var processes: [SSHProcess] = []
        let manager = TunnelManager(store: store, useRegistry: true,
            timing: .init(poll: .milliseconds(10), startupTimeout: 8, retry: [.milliseconds(100)])) { command in
                let process = try SSHProcess(arguments: command.arguments, remoteForwards: command.remoteForwardCount)
                processes.append(process)
                return process
            }
        addTeardownBlock { await manager.shutdown() }
        try await manager.start()
        for cycle in 0..<10 {
            try await eventually(timeout: 10) { manager.status(for: tunnel).phase == .connected }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(localPort)/\(cycle)")!)
            request.timeoutInterval = 3
            let (data, _) = try await URLSession.shared.data(for: request)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
            XCTAssertEqual(processes.filter { !$0.hasExited }.count, 1)
            // Both paths may be online: switching Wi-Fi/VPN must still replace
            // the old transport before it can retain the listening port.
            manager.networkChanged(available: false)
            manager.networkChanged(available: true)
        }
        try await eventually(timeout: 10) { manager.status(for: tunnel).phase == .connected }
        manager.setEnabled(false, for: tunnel.id)
        try await eventually { manager.status(for: tunnel).phase == .stopped }
        XCTAssertTrue(processes.allSatisfy(\.hasExited))
        XCTAssertGreaterThanOrEqual(processes.count, 11)
        // Rebinding a real listener is the regression check for leaked ports.
        let replacement = try SSHProcess(arguments: try SSHCommand(tunnel.command).arguments)
        try await eventually { replacement.isReady }
        await replacement.stop()
    }

    func testOccupiedPortDoesNotKillOtherSSHAndRecoversWhenFreed() async throws {
        let server = try SSHServerFixture()
        addTeardownBlock { await server.stop() }
        try await server.waitUntilReady()
        let http = try HTTPFixture()
        let localPort = try unusedPort()
        let command = server.command(forward: "-L127.0.0.1:\(localPort):127.0.0.1:\(http.port)")
        let external = try SSHProcess(arguments: try SSHCommand(command).arguments)
        try await eventually(timeout: 10) { external.isReady }
        let store = ConfigStore(directory: server.directory.appendingPathComponent("app"))
        let tunnel = Tunnel(command: command, enabled: true)
        try store.save([tunnel])
        let manager = TunnelManager(store: store, useRegistry: false,
            timing: .init(poll: .milliseconds(10), startupTimeout: 8, retry: [.milliseconds(100)]))
        addTeardownBlock { await manager.shutdown(); await external.stop() }
        try await manager.start()
        try await eventually(timeout: 10) { manager.status(for: tunnel).message.contains("端口已被占用") }
        XCTAssertFalse(external.hasExited)
        XCTAssertNotEqual(manager.status(for: tunnel).phase, .connected)
        await external.stop()
        try await eventually(timeout: 10) { manager.status(for: tunnel).phase == .connected }
    }

    func testRemoteOnlyTunnelRequiresServerAcknowledgment() async throws {
        let server = try SSHServerFixture()
        addTeardownBlock { await server.stop() }
        try await server.waitUntilReady()
        let http = try HTTPFixture()
        let remotePort = try unusedPort()
        let command = try SSHCommand(server.command(forward: "-R127.0.0.1:\(remotePort):127.0.0.1:\(http.port)"))
        let process = try SSHProcess(arguments: command.arguments, remoteForwards: command.remoteForwardCount)
        try await eventually(timeout: 10) { process.isReady }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(remotePort)")!)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        await process.stop()
    }
    func testCrashRecoveryOnlyStopsVerifiedOwnedSSHGroup() async throws {
        let server = try SSHServerFixture()
        addTeardownBlock { await server.stop() }
        try await server.waitUntilReady()
        let port = try unusedPort()
        let command = try SSHCommand(server.command(forward: "-D127.0.0.1:\(port)"))
        let orphan = try SSHProcess(arguments: command.arguments)
        try await eventually { orphan.isReady }
        let identity = try XCTUnwrap(orphan.identity)
        let directory = server.directory.appendingPathComponent("registry")
        var registry: ProcessRegistry? = try ProcessRegistry(directory: directory)
        try registry?.register(identity)
        registry = nil // Simulate loss of the app's instance lock.
        let recovered = try ProcessRegistry(directory: directory)
        try await recovered.recover()
        _ = await orphan.wait()
        XCTAssertTrue(orphan.hasExited)
        let replacement = try SSHProcess(arguments: command.arguments)
        try await eventually { replacement.isReady }
        await replacement.stop()
    }

    func testJumpHostChildrenExitAndReleasePort() async throws {
        let server = try SSHServerFixture()
        addTeardownBlock { await server.stop() }
        try await server.waitUntilReady()
        let port = try unusedPort()
        let config = server.directory.appendingPathComponent("client_config")
        try """
        Host gateway
            HostName 127.0.0.1
            Port \(server.port)
        Host *
            User \(NSUserName())
            IdentityFile \(server.directory.path)/client
            IdentitiesOnly yes
            StrictHostKeyChecking no
            UserKnownHostsFile /dev/null
            BatchMode yes
        """.write(to: config, atomically: true, encoding: .utf8)
        let command = try SSHCommand("ssh -F '\(config.path)' -p \(server.port) -J gateway -D127.0.0.1:\(port) \(NSUserName())@127.0.0.1")
        let process = try SSHProcess(arguments: command.arguments)
        try await eventually(timeout: 10) { process.isReady }
        await process.stop()
        let replacement = try SSHProcess(arguments: command.arguments)
        try await eventually(timeout: 10) { replacement.isReady }
        await replacement.stop()
    }

    func testSixteenTunnelsCanConnectAndStopTogether() async throws {
        let server = try SSHServerFixture()
        addTeardownBlock { await server.stop() }
        try await server.waitUntilReady()
        let store = ConfigStore(directory: server.directory.appendingPathComponent("app"))
        var ports = Set<Int>()
        while ports.count < 16 { ports.insert(try unusedPort()) }
        let tunnels = ports.map { Tunnel(command: server.command(forward: "-D127.0.0.1:\($0)"), enabled: true) }
        try store.save(tunnels)
        var processes: [SSHProcess] = []
        let manager = TunnelManager(store: store, useRegistry: true,
            timing: .init(poll: .milliseconds(10), startupTimeout: 8, retry: [.milliseconds(100)])) { command in
                let process = try SSHProcess(arguments: command.arguments)
                processes.append(process)
                return process
            }
        addTeardownBlock { await manager.shutdown() }
        try await manager.start()
        try await eventually(timeout: 15) { tunnels.allSatisfy { manager.status(for: $0).phase == .connected } }
        XCTAssertEqual(processes.filter { !$0.hasExited }.count, 16)
        await manager.shutdown()
        XCTAssertTrue(processes.allSatisfy(\.hasExited))
    }

}
