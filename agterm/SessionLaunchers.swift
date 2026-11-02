import AppKit
import agtermCore

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
        let marker = "agterm-launcher-path-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh")
        // printenv rather than "$PATH": fish joins a quoted list with spaces
        process.arguments = ["-l", "-i", "-c", "printf '\\n%s\\n' \(marker); printenv PATH"]
        var environment = environment
        environment.removeValue(forKey: "AGTERM_SESSION_ID")
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
    /// A template image: the terminal symbol, or the agent's logo from the asset catalog.
    func image(pointSize: CGFloat) -> NSImage? {
        let image: NSImage?
        if self == .terminal {
            image = NSImage(systemSymbolName: "terminal", accessibilityDescription: title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize - 2, weight: .regular))
        } else {
            image = (NSImage(named: "launcher-\(rawValue)")?.copy() as? NSImage)
            image?.size = NSSize(width: pointSize, height: pointSize)
        }
        image?.isTemplate = true
        return image
    }
}

/// SessionAgentMonitor samples each local session's focused pane every two seconds and records the coding agent
/// in its foreground, so a row's agent icon also follows an agent typed by hand and clears when it exits.
@MainActor
final class SessionAgentMonitor {
    private let library: WindowLibrary
    private let zmxResolver: ZmxForegroundResolver?
    private let shellBasename = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
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
                let agent = (session.activeSurface as? GhosttySurfaceView)
                    .flatMap { ForegroundProcess.running(for: $0, shellBasename: shellBasename, zmxResolver: zmxResolver) }
                    .flatMap(\.command)
                    .flatMap(SessionLauncher.agent(argv:))
                if session.runningAgent != agent { session.runningAgent = agent }
            }
        }
    }
}
