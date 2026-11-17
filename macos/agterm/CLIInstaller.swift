import AppKit
import agtermCore

/// Installs the bundled `agtermctl` CLI into the user's PATH by symlinking it from the app bundle into
/// `/usr/local/bin`: a direct symlink when the dir is user-writable (no prompt), else a one-time GUI admin
/// prompt via `osascript` (a clean Apple Silicon Mac has a root-owned `/usr/local/bin`). Host-free
/// path/command logic is `agtermCore.CLIInstall`; this owns the AppKit filesystem + authorization glue.
@MainActor
enum CLIInstaller {
    enum InstallResult {
        case installed(path: String)
        case failed(String)
        case cancelled
    }

    /// The bundled helper at `Contents/MacOS/agtermctl`, or nil when this build skipped the bundling phase
    /// (e.g. a bare `swift build`).
    static var bundledTool: URL? { Bundle.main.url(forAuxiliaryExecutable: CLIInstall.toolName) }

    /// Run the install, alerting only on a failure.
    static func run() {
        if case .failed(let message) = install() {
            present(style: .warning, title: "Command Line Tool Not Installed", text: message)
        }
    }

    private static func install() -> InstallResult {
        guard let source = bundledTool?.path else {
            return .failed("\(CLIInstall.toolName) is not bundled in this build.")
        }
        // already linked here, or by the Homebrew cask: relinking would only add an admin prompt
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: CLIInstall.installPath)) == source
            || fm.fileExists(atPath: CLIInstall.homebrewPath) {
            return .installed(path: CLIInstall.installPath)
        }
        if directSymlink(source: source) { return .installed(path: CLIInstall.installPath) }
        return elevatedSymlink(source: source)
    }

    /// Replace any existing link and symlink the bundled tool into place. Succeeds only when the target
    /// directory is user-writable; any error (typically a root-owned dir) returns false so the caller
    /// escalates.
    private static func directSymlink(source: String) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(atPath: CLIInstall.installPath)
        do {
            try fm.createSymbolicLink(atPath: CLIInstall.installPath, withDestinationPath: source)
            return true
        } catch {
            return false
        }
    }

    /// Create the symlink through a single GUI admin prompt. Returns `.cancelled` when the user dismisses
    /// the authorization dialog (AppleScript error -128).
    private static func elevatedSymlink(source: String) -> InstallResult {
        let command = CLIInstall.privilegedInstallCommand(source: source)
        let apple = "do shell script \(appleScriptString(command)) with administrator privileges"
        guard let script = NSAppleScript(source: apple) else {
            return .failed("Could not build the install script.")
        }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
        guard let err else { return .installed(path: CLIInstall.installPath) }
        if (err[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled } // user dismissed the prompt
        return .failed((err[NSAppleScript.errorMessage] as? String) ?? "Authorization failed.")
    }

    private static func present(style: NSAlert.Style, title: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    /// Quote a string as an AppleScript string literal.
    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
