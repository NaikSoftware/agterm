extension WindowLibrary {
    /// Appends an app-wide event (no window or session) and hands it to the hook sink, as `emitAppLaunched` does.
    public func emitAppEvent(_ draft: ControlEventDraft) {
        let event = controlEventRing.append(draft) // outside the call: an optional call skips its argument
        onControlEvent?(event)
        // `phoneViewers` and `phoneLead` are in the tree of the window holding the pane
        guard [.phoneAttached, .phoneDetached, .phoneClaimed, .phoneReleased].contains(draft.kind), let token = draft.payload.paneID else { return }
        for store in stores.values where store.workspaces.contains(where: { $0.sessions.contains { $0.paneRole(forToken: token) != nil } }) {
            store.scheduleTreeChanged()
        }
    }
}
