extension Session {
    static let newCwdHelp = """
        Working directory (defaults to the workspace's remembered folder in the Current session's directory mode, else $HOME). \
        Without --workspace/--workspace-name/--after/--before, the session joins the workspace whose pinned project folder \
        holds it, in any open window unless --window narrows it; else, in that mode, the first workspace whose remembered \
        folder equals it.
        """
}
