extension WindowLibrary {
    /// Appends an app-wide event (no window or session) and hands it to the hook sink, as `emitAppLaunched` does.
    public func emitAppEvent(_ draft: ControlEventDraft) {
        let event = controlEventRing.append(draft) // outside the call: an optional call skips its argument
        onControlEvent?(event)
    }
}
