import AppKit
import ElisCore

/// SessionTyping types a line into a session's main shell once its surface is realized.
@MainActor
protocol SessionTyping: AnyObject {
    func typeLine(_ line: String, into sessionID: UUID, store: AppStore) async -> Bool
}

/// The launchers the workspace row's "+" menu offers: Terminal plus the agents found on the login shell's PATH.
@MainActor
enum SessionLaunchers {
    private(set) static var available: [SessionLauncher] = [.terminal]
    private static var detectedAt: Date?

    /// Re-detects in the background when the cached list is older than `maxAge`; the next menu sees the result.
    /// A Finder-launched app gets launchd's minimal PATH, and agents install into directories only the user's
    /// shell startup adds, so the login shell is asked.
    static func refresh(maxAge: TimeInterval = 300) {
        if let detectedAt, Date().timeIntervalSince(detectedAt) < maxAge { return }
        detectedAt = Date()
        let environment = ProcessInfo.processInfo.environment
        Task.detached {
            let shellPath = loginShellPath(environment: environment)
            let path = [shellPath, CommandPath.widened(environment["PATH"], bundledCLIDirectory: nil),
                        NSHomeDirectory() + "/.local/bin"].compactMap(\.self).joined(separator: ":")
            let found = SessionLauncher.available(path: path) { FileManager.default.isExecutableFile(atPath: $0) }
            await MainActor.run { available = found }
        }
    }

    private nonisolated static func loginShellPath(environment: [String: String], timeout: TimeInterval = 3) -> String? {
        let marker = "elis-launcher-path-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh")
        // printenv rather than "$PATH": fish joins a quoted list with spaces
        process.arguments = ["-l", "-i", "-c", "printf '\\n%s\\n' \(marker); printenv PATH"]
        var environment = environment
        environment.removeValue(forKey: "ELIS_SESSION_ID")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: marker + "\n", options: .backwards) else { return nil }
        return text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension SessionLauncher {
    /// A template image from the asset catalog: the Lucide terminal, or the agent's logo.
    func image(pointSize: CGFloat) -> NSImage? {
        let image = NSImage.bundledIcon(self == .terminal ? "session-terminal" : "launcher-\(rawValue)", size: pointSize)
        image?.accessibilityDescription = title
        return image
    }
}

/// SessionAgentMonitor samples both panes of each local session every two seconds and records the coding agent
/// in their foreground, so a row's agent icon also follows an agent typed by hand and clears when it exits.
@MainActor
final class SessionAgentMonitor {
    private let library: WindowLibrary
    private let zmxResolver: ZmxForegroundResolver?
    private var timer: Timer?
    private static var shared: SessionAgentMonitor?

    static func start(library: WindowLibrary, zmxResolver: ZmxForegroundResolver?) {
        shared = SessionAgentMonitor(library: library, zmxResolver: zmxResolver)
    }

    private init(library: WindowLibrary, zmxResolver: ZmxForegroundResolver?) {
        self.library = library
        self.zmxResolver = zmxResolver
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        zmxResolver?.refreshIfNeeded()
        for window in library.windows {
            guard let store = library.store(for: window.id) else { continue }
            for session in store.workspaces.flatMap(\.sessions) where session.remoteHost == nil {
                let panes: [(StatusPane, (any TerminalSurface)?)] = [(.left, session.surface), (.right, session.splitSurface)]
                let samples = panes.compactMap { pane, surface in (surface as? GhosttySurfaceView).map { sample(pane, $0) } }
                store.applyAgentSamples(samples, focused: session.focusedPane == .right ? .right : .left, forSession: session.id)
            }
        }
    }

    private func sample(_ pane: StatusPane, _ view: GhosttySurfaceView) -> AgentPaneSample {
        let pids = ForegroundProcess.groupPIDs(for: view, zmxResolver: zmxResolver)
        let agent = SessionLauncher.agent(group: pids.compactMap(ForegroundProcess.procArgs(pid:)))
        let directory = ClaudeHome.directory()
        let json = agent == .claude
            ? pids.lazy.compactMap { ClaudeHome.sessionJSON(pid: $0, directory: directory) }
                .first { SessionLauncher.claudeSessionID(json: $0) != nil }
            : nil
        return AgentPaneSample(pane: pane, agent: agent, claudeSessionJSON: json)
    }
}
