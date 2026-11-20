# Built-in Elis pages

Date: 2026-11-20. Status: draft; open questions below need the owner before planning.
Builds on `2026-11-20-phone-pages-design.md` (part 4 there) and the dev-server path it ships.

## Intent

Some pages are useful in every session, so an agent should not have to write and serve them each time:
a file manager for the session's folder, a GitHub workflow view for the session's repository.
They open like any page, on the Mac or on the phone, wherever the session is driven.

## Goals

- `elisctl session page builtin <name>` opens a built-in page for the target session.
- First pages: `files` (browse, preview, download to the phone, rename/delete with confirmation)
  and `github` (workflow runs of the session's repository: status, logs, re-run).
- Same page rules as any page: follows the lead, clears itself, the overlay is not a browser.

## Non-goals

- A general file manager outside the session's folder tree.
- A GitHub client beyond the session's repository and its Actions.
- Third-party built-in pages or a plugin API (custom pages already work through `overlay open`).

## Approaches

- **A. File pages bundled in the app, data through the bridge (recommended).**
  The page is static HTML/JS in the app bundle, opened as a `--html --js` file page;
  it reads data through new read-only control commands (`session.files.list`, `session.files.read`,
  `session.github.runs`, …) via `elis.request`, so it works on the Mac, on the phone, and for remote rows
  with no new transport. Mutations (delete, re-run) are control commands too, refused unless the page asks with a user gesture.
- **B. A built-in HTTP server per page,** shown as a loopback `--url` (reuses part 2's tunnel).
  Simpler pages, but one more long-lived process per page and no remote path without the ssh forward.
- **C. Native phone screens.** Best phone UX, but the Mac gets nothing and each page is written twice.

## Design sketch (approach A)

- Pages live in `macos/Elis/Resources/pages/<name>/` and in the relay's bundle path (same source, like `MarkdownAssets`).
- New control commands are read-only by default, scoped to the session's folder (`cwd` grant) or repository,
  and listed in `HtmlBridge` as allowed only for built-in pages (a capability flag on the page, not a name check).
- `github` uses the `gh` CLI on the session's host for auth; no token handling in Elis.
- Read-back: `htmlOverlays[].builtin: <name>`.

## Security

- A built-in page gets only its own commands; a user page still gets none of them.
- File access is bounded by the session's folder, symlinks resolved; downloads to the phone go through the page channel.
- Mutating actions need a confirmation the page shows, and are logged as session events.

## Open for the owner

1. Approach A, B or C.
2. The first two pages (`files`, `github`) or a different set.
3. Whether built-in pages may mutate (delete files, re-run workflows) in v1 or start read-only.

## Remote path

Approach A runs the commands on the session's host through the existing control routing,
so another Mac and elis-server work without new transport; `gh` must exist on that host.

## Tests (for the plan)

- Control: each command's bounds (outside-folder path refused, symlink escape refused), read-back.
- Bridge: a user page cannot call built-in commands; a built-in page cannot call `phone.*`.
- Pages: smoke tests of the bundled HTML in a hosted WebView on the Mac and on the phone.
