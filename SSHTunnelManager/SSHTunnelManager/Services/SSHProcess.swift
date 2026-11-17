import Foundation
import Darwin

struct ProcessResult: Sendable {
    let status: Int32
    let diagnostic: String
}

@MainActor
protocol TunnelProcess: AnyObject {
    var isReady: Bool { get }
    var hasExited: Bool { get }
    var identity: ProcessIdentity? { get }
    func wait() async -> ProcessResult
    func stop() async
}

/// Each invocation owns a separate POSIX process group, including jump-host and
/// ProxyCommand children. Never find or kill processes by port or command text.
@MainActor
final class SSHProcess: TunnelProcess {
    let identity: ProcessIdentity?
    private let state: ProcessState
    private let output: ProcessOutput
    private let completion: Task<ProcessResult, Never>
    private var stopTask: Task<Void, Never>?

    var isReady: Bool { !hasExited && output.isReady }
    var hasExited: Bool { state.hasExited }

    init(arguments: [String], remoteForwards: Int = 0, executable: String = "/usr/bin/ssh", stopGrace: Duration = .milliseconds(500)) throws {
        let pipe = Pipe()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor)
        // pgroup=0 creates a group led by the new child's own PID. The app is
        // never a member of that group. Reset inherited/ignored signal states.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, sig) }
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        let argv = ([executable] + arguments).map { strdup($0) }
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let error = (argv + [nil]).withUnsafeBufferPointer { args in
            (env + [nil]).withUnsafeBufferPointer { environment in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, environment.baseAddress!)
            }
        }
        try? pipe.fileHandleForWriting.close()
        guard error == 0 else {
            try? pipe.fileHandleForReading.close()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        identity = ProcessIdentity.read(pid: pid)
        let state = ProcessState(pid: pid, stopGrace: stopGrace)
        let output = ProcessOutput(remoteForwards: remoteForwards)
        self.state = state
        self.output = output
        // Drain continuously, including while ssh is running. Debug logging can
        // exceed a pipe buffer, so reading only after exit would deadlock ssh.
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { try? pipe.fileHandleForReading.close(); drained.leave() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                output.append(Data(buffer.prefix(count)))
            }
        }
        let childPID = pid
        completion = Task {
            await withCheckedContinuation { continuation in
                // Blocking POSIX I/O belongs on GCD threads, not Swift's
                // cooperative executor (many tunnels would exhaust its pool).
                DispatchQueue.global(qos: .utility).async {
                    var info = siginfo_t()
                    var result: Int32
                    repeat { result = waitid(P_PID, id_t(childPID), &info, WEXITED | WNOWAIT) } while result == -1 && errno == EINTR
                    // Leave the leader unreaped until its group has been killed.
                    state.finishGroup()
                    var status: Int32 = 0
                    var waited: pid_t
                    repeat { waited = waitpid(childPID, &status, 0) } while waited == -1 && errno == EINTR
                    drained.wait()
                    let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                    continuation.resume(returning: ProcessResult(status: exitCode, diagnostic: output.diagnostic))
                }
            }
        }
    }

    func wait() async -> ProcessResult { await completion.value }

    func stop() async {
        if let stopTask { await stopTask.value; return }
        let state = state
        let completion = completion
        // An unstructured task keeps the cleanup deadline alive even if the
        // tunnel's worker was cancelled by another network update or a stop.
        let task = Task {
            state.signal(SIGTERM)
            let deadline = Task.detached {
                try? await Task.sleep(for: state.stopGrace)
                state.signal(SIGKILL)
            }
            _ = await completion.value
            deadline.cancel()
        }
        stopTask = task
        await task.value
    }

    deinit { state.signal(SIGKILL) }
}

/// All accesses, including signaling versus reaping, share this lock. A delayed
/// SIGKILL can never hit a recycled PID after the child has exited.
private final class ProcessState: @unchecked Sendable {
    let pid: pid_t
    let stopGrace: Duration
    private let lock = NSLock()
    private var exited = false
    init(pid: pid_t, stopGrace: Duration) { self.pid = pid; self.stopGrace = stopGrace }
    var hasExited: Bool { lock.withLock { exited } }
    func signal(_ signal: Int32) {
        lock.withLock { if !exited { kill(-pid, signal) } }
    }
    func finishGroup() {
        lock.withLock {
            kill(-pid, SIGKILL)
            exited = true
        }
    }
}

private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = Data()
    private var partialLine = Data()
    private var enteredSession = false
    private var remoteAcknowledgments = 0
    private let remoteForwards: Int
    init(remoteForwards: Int) { self.remoteForwards = remoteForwards }
    var isReady: Bool { lock.withLock { enteredSession && remoteAcknowledgments >= remoteForwards } }
    func append(_ data: Data) {
        lock.withLock {
            tail.append(data)
            if tail.count > 65536 { tail.removeFirst(tail.count - 65536) }
            partialLine.append(data)
            while let newline = partialLine.firstIndex(of: 10) {
                let line = String(decoding: partialLine[..<newline], as: UTF8.self)
                if line.contains("Entering interactive session.") { enteredSession = true }
                if line.contains("remote forward success for:") { remoteAcknowledgments += 1 }
                partialLine.removeSubrange(...newline)
            }
            if partialLine.count > 65536 { partialLine.removeFirst(partialLine.count - 65536) }
        }
    }
    var diagnostic: String {
        lock.withLock {
            String(decoding: tail, as: UTF8.self).split(whereSeparator: \.isNewline)
                .filter { !$0.hasPrefix("debug") }.suffix(6).joined(separator: "\n")
        }
    }
}

/// Crash-recovery records include birth time and executable identity. A bare PID
/// file is unsafe: macOS can reuse its PIDs for an unrelated process.
struct ProcessIdentity: Codable, Equatable, Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
    let executable: String

    static func read(pid: pid_t) -> Self? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec, executable: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
    var matchesLiveSSHGroup: Bool {
        executable == "/usr/bin/ssh" && Self.read(pid: pid) == self && getpgid(pid) == pid
    }
}

@MainActor
final class ProcessRegistry {
    private let lockFD: Int32
    private let fileURL: URL
    private var records: [ProcessIdentity] = []

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lockFD = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            throw InstanceAlreadyRunning()
        }
        fileURL = directory.appendingPathComponent("owned-processes.json")
    }

    func recover() async throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            records = try JSONDecoder().decode([ProcessIdentity].self, from: Data(contentsOf: fileURL))
        }
        let stale = records.filter(\.matchesLiveSSHGroup)
        for record in stale { kill(-record.pid, SIGKILL) }
        // Orphans are no longer our children, so waitpid cannot reap them. Wait
        // for their verified identities to disappear before starting replacements.
        for _ in 0..<40 {
            if !stale.contains(where: \.matchesLiveSSHGroup) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !stale.contains(where: \.matchesLiveSSHGroup) else { throw CommandError("上次的 SSH 进程尚未退出，请稍后重新打开应用。") }
        records = []
        try persist()
    }
    func register(_ identity: ProcessIdentity) throws {
        // The child may already have exited between spawn and registration.
        // Its captured identity is still safe to record: recovery revalidates it.
        guard identity.pid > 1, identity.executable == "/usr/bin/ssh" else { throw CommandError("无法确认新 SSH 进程的身份。") }
        records.append(identity)
        try persist()
    }
    func remove(_ identity: ProcessIdentity) {
        records.removeAll { $0 == identity }
        try? persist()
    }
    private func persist() throws {
        try JSONEncoder().encode(records).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    deinit { close(lockFD) }
}

struct InstanceAlreadyRunning: Error {}
