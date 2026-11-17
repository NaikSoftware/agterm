import Foundation

// One-shot launch payloads a pane consumes when its surface is built.
extension Session {
    /// Takes the pane's PENDING restore-command override, clearing it so a second surface for the same pane
    /// this launch gets a plain shell: `makeSplitSurface` runs again on a fresh ⌘D after a split shell exits,
    /// and a leftover payload would fire twice mid-session. The PERSISTED `restoreCommand`/`splitRestoreCommand`
    /// are untouched — sticky, they must fire again after the next restart. `.scratch` returns nil, never
    /// restored.
    public func takePendingRestoreOverride(pane: StatusPane) -> String? {
        switch pane {
        case .left:
            let pending = pendingRestoreCommand
            pendingRestoreCommand = nil
            return pending
        case .right:
            let pending = pendingSplitRestoreCommand
            pendingSplitRestoreCommand = nil
            return pending
        case .scratch:
            return nil
        }
    }

    /// Takes the pane's transient captured foreground command, clearing it so it fires once. Same
    /// consume-on-read rule as `takePendingRestoreOverride(pane:)`, and for the same reason: a leftover
    /// payload would fire again when `makeSplitSurface` runs on a fresh ⌘D mid-session. `.scratch` is
    /// never restored.
    public func takePendingForegroundCommand(pane: StatusPane) -> [String]? {
        switch pane {
        case .left:
            let pending = pendingForegroundCommand
            pendingForegroundCommand = nil
            return pending
        case .right:
            let pending = pendingSplitForegroundCommand
            pendingSplitForegroundCommand = nil
            return pending
        case .scratch:
            return nil
        }
    }

    /// Takes the reopen's resume line for the main pane only, clearing it so a rebuilt surface never types it twice.
    public func takePendingResumeLine(pane: StatusPane) -> String? {
        guard pane == .left else { return nil }
        defer { pendingResumeLine = nil }
        return pendingResumeLine
    }

    /// Drops the unconsumed CAPTURE payloads only, leaving the persisted and pending `session.restore` pins
    /// armed. The pending half of `clearCapturedForegroundCommands()`; public because agterm-linux calls it.
    public func clearPendingForegroundCommands() {
        pendingForegroundCommand = nil
        pendingSplitForegroundCommand = nil
    }

    /// Drops the captured foreground commands whole: the persisted pair AND the unconsumed pending pair.
    /// `restore.clear` and a non-last window close both need exactly this, over different session sets.
    /// `.claude/rules/settings.md` covers why the persisted fields cannot be dropped on their own.
    public func clearCapturedForegroundCommands() {
        foregroundCommand = nil
        splitForegroundCommand = nil
        clearPendingForegroundCommands()
    }

    /// Drops every unconsumed bootstrap payload — both override pins and both captured commands — leaving
    /// the persisted fields alone. Called where a live `Session` leaves the tree but may return as the SAME
    /// object (the soft-close grace window): a payload armed at bootstrap would otherwise survive the round
    /// trip and fire when its surface is rebuilt.
    public func clearPendingRestoreOverrides() {
        pendingRestoreCommand = nil
        pendingSplitRestoreCommand = nil
        pendingResumeLine = nil
        clearPendingForegroundCommands()
    }
}

extension Sequence<Session> {
    /// The Dock badge count: sessions that need attention, each counted once whether it has unseen
    /// notifications (when `countingUnseen`) or a blocked/completed status.
    @MainActor public func attentionCount(countingUnseen: Bool) -> Int {
        count { (countingUnseen && $0.unseenCount > 0) || $0.agentIndicator.status.needsAttention }
    }
}
