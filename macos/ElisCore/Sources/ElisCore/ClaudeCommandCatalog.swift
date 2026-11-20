import Foundation

/// The "/" menu: Claude Code's built-in commands plus the skills its transcript lists.
enum ClaudeCommandCatalog {
    static let descriptionLimit = 160
    static let panels: Set<String> = ["config", "model", "resume", "rewind", "tasks", "usage"]

    // Captured from Claude Code 2.1.329's "/" menu; descriptions that showed session state keep only the static phrase.
    static let builtins: [ControlTranscriptCommand] = [
        ("add-dir", "Add a working directory"),
        ("advisor", "Let Claude consult a stronger model at key moments"),
        ("artifacts", "Browse your published and shared artifacts"),
        ("auto-mode-setup", "Teach auto mode about your environment"),
        ("autocompact", "Set how full the context gets before auto-summarizing"),
        ("autofix-pr", "Monitor and autofix any issues with the current PR"),
        ("background", "Send this session to the background and free the terminal"),
        ("batch", "Plan a large change; background agents each open a PR"),
        ("branch", "Create a branch of the current conversation at this point"),
        ("btw", "Ask a side question without interrupting Claude"),
        ("bug", "Report a bug or share your session"),
        ("cd", "Move this session to a new working directory"),
        ("chrome", "Open Claude in Chrome settings"),
        ("clear", "Start a new session with empty context; loops carry over, and the old one stays in /resume"),
        ("color", "Set the prompt bar color for this session"),
        ("compact", "Free up context by summarizing the conversation so far"),
        ("config", "Open settings"),
        ("context", "Show what fills the context"),
        ("copy", "Copy the last response to clipboard (/copy 2 for the one before)"),
        ("debug", "Turn on debug logging and investigate problems"),
        ("design", "Make a new Design artifact from a brief"),
        ("design-login", "Authorize design-system access for /design-sync with your claude.ai account"),
        ("design-sync", "Push your design system components to claude.ai/design"),
        ("desktop", "Continue the current session in Claude Desktop"),
        ("diff", "Toggle the diff panel showing uncommitted changes"),
        ("doctor", "Health-check your setup and fix issues: installation, unused extensions, duplicated or bloated memory files, slow hooks, updates, permissions"),
        ("effort", "Set the model's effort level"),
        ("exit", "Exit the CLI"),
        ("export", "Export this session to a file or clipboard"),
        ("fast", "Toggle fast mode"),
        ("feedback", "Send feedback to Anthropic or report a bug"),
        ("focus", "Toggle focus view: just your prompt, summary, and response"),
        ("fork", "Copy this conversation into a new background session and keep working here"),
        ("goal", "Set a goal Claude checks before stopping"),
        ("help", "Show help and available commands"),
        ("hooks", "View hook configurations for tool events"),
        ("ide", "Manage IDE integrations and show status"),
        ("import", "Import config from another AI coding agent"),
        ("insights", "Generate a report analyzing your Claude Code sessions"),
        ("install-github-app", "Set up Claude GitHub Actions for a repository"),
        ("install-slack-app", "Install the Claude Slack app"),
        ("keybindings", "Open your keyboard shortcuts file"),
        ("list-agents", "List subagents, teammates, and other Claude sessions you can message"),
        ("login", "Sign in with your Anthropic account"),
        ("logout", "Sign out from your Anthropic account"),
        ("mcp", "Manage MCP servers"),
        ("memory", "Edit CLAUDE.md files and memory settings"),
        ("mobile", "Show QR code to download the Claude mobile app"),
        ("model", "Switch model"),
        ("output-style", "List output styles or switch to one"),
        ("passes", "Share a free week of Claude Code with friends and earn usage credits"),
        ("permissions", "Manage allow and deny tool permission rules"),
        ("plan", "Turn on plan mode or view the plan"),
        ("plugin", "Manage Claude Code plugins"),
        ("powerup", "Learn Claude Code features in short lessons"),
        ("privacy-settings", "View and update your privacy settings"),
        ("radio", "Listen to Claude FM lo-fi radio"),
        ("rate-limit-options", "Manage usage limits and upgrade options"),
        ("recap", "Generate a one-line session recap now"),
        ("release-notes", "View release notes"),
        ("reload-plugins", "Activate pending plugin changes in the current session"),
        ("reload-skills", "Pick up skills added or changed on disk during this session"),
        ("remote-control", "Connect or disconnect Remote Control"),
        ("remote-env", "Choose the default environment for cloud agents"),
        ("rename", "Rename the current conversation"),
        ("restart", "Restart Claude Code and keep this session"),
        ("resume", "Resume a previous session"),
        ("rewind", "Restore earlier code, conversation, or both"),
        ("run-skill-generator", "Create a skill that knows how to run this project’s app"),
        ("sandbox", "Configure the sandbox"),
        ("scroll-speed", "Adjust mouse wheel scroll speed"),
        ("send-to-project", "Send this session's work to a Claude Project"),
        ("skill-doctor", "Show which loaded skills are unused and costing context"),
        ("skills", "List available skills"),
        ("slides", "Make a new Slides deck artifact from a brief"),
        ("status", "Show version, account, model, MCP servers, and setup warnings"),
        ("statusline", "Set up the status line"),
        ("stickers", "Check Claude Code sticker availability"),
        ("subtask", "Send a subagent off with your full context; its result comes back here"),
        ("tasks", "View and manage this session's background work"),
        ("team-onboarding", "Help teammates ramp on Claude Code with a guide from your usage"),
        ("teleport", "Resume a cloud session here"),
        ("terminal-setup", "Set up Shift+Enter for newlines"),
        ("theme", "Change the theme"),
        ("tui", "Set the terminal UI renderer (classic | fullscreen)"),
        ("ultrareview", "Start a cloud agent that finds and verifies bugs in your branch"),
        ("upgrade", "Upgrade your plan for higher rate limits and more Opus"),
        ("usage", "Show session cost, plan usage, and activity stats"),
        ("usage-credits", "Configure usage credits or request them from your admin when you hit a limit"),
        ("verify", "Try your change and report if it works"),
        ("voice", "Toggle voice mode"),
        ("web-setup", "Set up cloud sessions with your GitHub account"),
        ("whiteboard", "Make a new Whiteboard artifact from a brief"),
        ("workflows", "Browse running and completed workflows"),
    ].map { command($0.0, $0.1, source: "builtin") }

    /// The skills of the listings since the last initial one, each described by its `- <name>: ` content line.
    static func skills(listings: [(isInitial: Bool, names: [String], content: String)]) -> [ControlTranscriptCommand] {
        let current = listings.lastIndex { $0.isInitial }.map { listings[$0...] } ?? listings[...]
        var seen = Set<String>()
        return current.flatMap { listing in
            let lines = listing.content.split(separator: "\n")
            return listing.names.compactMap { name -> ControlTranscriptCommand? in
                guard seen.insert(name).inserted else { return nil }
                let prefix = "- \(name): "
                let line = lines.first { $0.hasPrefix(prefix) }
                return command(name, line.map { String($0.dropFirst(prefix.count)) } ?? "", source: "skill")
            }
        }
    }

    private static func command(_ name: String, _ description: String, source: String) -> ControlTranscriptCommand {
        ControlTranscriptCommand(name: name, description: String(description.prefix(descriptionLimit)), source: source,
                                 panel: source == "builtin" && panels.contains(name) ? true : nil)
    }
}
