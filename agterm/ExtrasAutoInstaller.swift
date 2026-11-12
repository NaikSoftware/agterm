import AppKit
import agtermCore

/// Installs the command line tool, the agent skill and the agent status hooks once per build, so a new
/// install or an update refreshes them with no menu step. Each installer alerts only when the user must act.
@MainActor
enum ExtrasAutoInstaller {
    /// Per user, like the files the installers write, so an isolated-state instance does not reinstall.
    private static let installedBuildKey = "extrasInstalledBuild"
    private static var checked = false

    static func runIfDue(identity: AppIdentity) {
        // Debug and test builds would point the user's live hooks and CLI link at DerivedData.
        #if !DEBUG
        guard !checked, !ContentView.isUITestLaunch else { return }
        checked = true
        // the bundle path re-bakes the hooks' agtermctl path when the app moves
        let build = "\(identity.version) \(identity.commit ?? "") \(Bundle.main.bundlePath)"
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: installedBuildKey) != build else { return }
        // recorded first, so a cancelled admin prompt or a failure does not repeat on every launch
        defaults.set(build, forKey: installedBuildKey)
        // hop out of the scene task before any modal: started inside it, `runModal()` draws nothing
        DispatchQueue.main.async {
            CLIInstaller.run()
            SkillInstaller.run()
            AgentHooksInstaller.run()
        }
        #endif
    }
}
