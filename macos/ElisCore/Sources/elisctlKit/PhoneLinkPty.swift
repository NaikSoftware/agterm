#if os(macOS)
import Foundation

/// PhoneLinkPty runs one phone pane's attach command on its own pty and reads the controller at full speed on a
/// dedicated thread. macOS only: Swift's Glibc does not export posix_openpt, grantpt, unlockpt or ptsname.
final class PhoneLinkPty: @unchecked Sendable {
    /// Failure reports the system call that kept the command from starting; `errno` is its code.
    struct Failure: Error, Equatable {
        let operation: String
        let errno: Int32
    }

    private let pid: pid_t
    private let controller: Int32
    private let onOutput: @Sendable (Data) -> Void
    // recursive, so an onOutput that calls terminate() on the reader thread does not deadlock
    private let lock = NSRecursiveLock()
    private var stopping = false
    private var reaped = false

    private init(pid: pid_t, controller: Int32, onOutput: @escaping @Sendable (Data) -> Void) {
        self.pid = pid
        self.controller = controller
        self.onOutput = onOutput
    }

    /// spawn runs `argv` as a session leader on a new cols×rows pty, the terminal as its stdin, stdout and stderr.
    /// onOutput gets each chunk the controller yields; onExit gets the exit code, or 128 + signal, once.
    static func spawn(_ argv: [String], cols: UInt16, rows: UInt16,
                      onOutput: @escaping @Sendable (Data) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) throws -> PhoneLinkPty {
        guard !argv.isEmpty else { throw Failure(operation: "spawn", errno: EINVAL) }
        let controller = posix_openpt(O_RDWR | O_NOCTTY)
        guard controller >= 0 else { throw Failure(operation: "posix_openpt", errno: errno) }
        do {
            _ = fcntl(controller, F_SETFD, FD_CLOEXEC)
            guard grantpt(controller) == 0 else { throw Failure(operation: "grantpt", errno: errno) }
            guard unlockpt(controller) == 0 else { throw Failure(operation: "unlockpt", errno: errno) }
            guard let name = ptsname(controller) else { throw Failure(operation: "ptsname", errno: errno) }
            let path = String(cString: name)
            // the controller refuses TIOCSWINSZ until a terminal is open, and this one stays open until the child has its own
            let terminal = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC)
            guard terminal >= 0 else { throw Failure(operation: "open terminal", errno: errno) }
            defer { close(terminal) }
            var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            // TIOCSWINSZ is _IOW('t', 103, struct winsize), a macro Swift does not import
            guard ioctl(terminal, UInt(0x8008_7467), &size) == 0 else { throw Failure(operation: "TIOCSWINSZ", errno: errno) }
            let pid = try launch(argv, terminalPath: path)
            let pty = PhoneLinkPty(pid: pid, controller: controller, onOutput: onOutput)
            let reader = Thread { pty.readUntilEnd(onExit: onExit) }
            reader.name = "phone-link-pty"
            reader.start()
            return pty
        } catch {
            close(controller)
            throw error
        }
    }

    /// terminate stops output delivery and sends SIGTERM to the command's process group; the reader thread sends
    /// SIGKILL after 2 s and closes the controller once the group is gone. onOutput runs under the lock this takes,
    /// so never call terminate() while holding a lock that onOutput also takes.
    func terminate() {
        lock.withLock {
            guard !stopping else { return }
            stopping = true
            if !reaped { kill(-pid, SIGTERM) }
        }
    }

    private func readUntilEnd(onExit: @Sendable (Int32) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var killAt: Date?
        var giveUpAt: Date?
        while true {
            var poller = pollfd(fd: controller, events: Int16(POLLIN), revents: 0)
            if poll(&poller, 1, 100) > 0 {
                let count = read(controller, &buffer, buffer.count)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                // 0 or EIO: every terminal descriptor is closed
                if count <= 0 { break }
                let chunk = Data(buffer[0..<count])
                lock.withLock { if !stopping { onOutput(chunk) } }
            }
            guard lock.withLock({ stopping }) else { continue }
            let now = Date()
            if killAt == nil { killAt = now.addingTimeInterval(2) }
            if giveUpAt == nil, let killAt, now >= killAt {
                kill(-pid, SIGKILL)
                giveUpAt = now.addingTimeInterval(2)
            }
            // a descendant that left the group can hold the terminal open forever
            if let giveUpAt, now >= giveUpAt { break }
        }
        close(controller)
        // shortcut: a child that closes its stdio but keeps running is waited for and never killed; add a kill here
        // if a relay command ever does that
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        lock.withLock { reaped = true }
        let signal = status & 0x7f
        onExit(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
    }

    private static func launch(_ argv: [String], terminalPath: String) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        // opened after setsid and without O_NOCTTY, so the terminal becomes the controlling tty
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, terminalPath, O_RDWR, 0), "posix_spawn_file_actions_addopen")
        try check(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO), "posix_spawn_file_actions_adddup2")
        try check(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO), "posix_spawn_file_actions_adddup2")

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        try check(posix_spawnattr_setsigmask(&attributes, &noSignals), "posix_spawnattr_setsigmask")
        try check(posix_spawnattr_setsigdefault(&attributes, &allSignals), "posix_spawnattr_setsigdefault")
        // the child gets only stdin, stdout and stderr; a leaked terminal from another pane would block that pane's EOF
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "posix_spawnattr_setflags")

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        var arguments = argv.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { variables.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = arguments.withUnsafeMutableBufferPointer { args in
            variables.withUnsafeMutableBufferPointer { vars in
                posix_spawnp(&pid, argv[0], &actions, &attributes, args.baseAddress, vars.baseAddress)
            }
        }
        try check(spawned, "posix_spawnp")
        return pid
    }

    private static func check(_ result: Int32, _ operation: String) throws {
        guard result == 0 else { throw Failure(operation: operation, errno: result) }
    }
}
#endif
