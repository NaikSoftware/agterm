# Hangar: rename and monorepo

## Intent

The NaikSoftware fork of agterm has become its own product: a terminal workspace for AI coding agents, on macOS, Linux and Android.
It gets its own name, Hangar, and one repository that holds all three apps.
Nothing user-visible or internal keeps the name agterm, except credits and history.

## Goals

- One repository, `NaikSoftware/hangar`, with three projects at the same level: `macos/`, `linux/`, `mobile/`.
- The Linux Qt app and the Flutter phone app move in from `NaikSoftware/agterm-qt` with their git history.
- Every name changes in all three projects: product, app, CLI, env vars, modules, paths, bundle ids, state and config dirs, skill, docs.
- A one-time script moves each user's Mac from Agterm2 to Hangar. Several people run Agterm2 on their own Macs, so the script is generic, ships with the release, and the README and release notes tell users to run it.
- All existing gates pass after the change: macOS build, `swift test`, `make test-app`, `make lint`, Qt `ctest` and `scripts/smoke.sh`, mobile `flutter analyze` and `flutter test`.

## Non-goals

- Merging from `umputun/agterm` after this change. Upstream fixes come in by hand or by cherry-pick.
- Migration code inside any app. No compatibility shims, aliases or fallbacks to old names.
- Keeping live sessions through the switch. Running agents restart as fresh shells.
- Deleting `NaikSoftware/agterm-qt`. The owner removes it after all work is done.
- New features, refactors or behavior changes.

## Anti-goals

- A tree that builds but leaves `agterm` in a user-visible string, path, env var, menu, log line or doc.
- Lost history for any of the three projects.
- A migration script that loses a user's sessions list, keymap, ghostty config or restore denylist.

## Name map

| Now | Hangar |
|---|---|
| Agterm2, agterm (product, `CFBundleName`, menus, docs) | Hangar |
| `agterm.app` | `Hangar.app` |
| `agtermctl` | `hangarctl` |
| `AGTERM_*` (73 variables) | `HANGAR_*` |
| `agtermCore`, `agtermctlKit`, `AgtermServerKit`, `AgtermResponsibility`, `agterm` app target, `agtermTests`, `agtermUITests` | `HangarCore`, `hangarctlKit`, `HangarServerKit`, `HangarResponsibility`, `Hangar`, `HangarTests`, `HangarUITests` |
| `agterm-session-host` (Swift, inside the macOS bundle; C++, in the Qt app), `agterm-server` | `hangar-session-host` for both, `hangar-server` |
| `ua.naiksoftware.agterm2` (+ `.debug`, `.agtermctl`) | `ua.naiksoftware.hangar` (+ `.debug`, `.hangarctl`) |
| `com.umputun.agterm` log subsystems and queue labels | `ua.naiksoftware.hangar` |
| `~/Library/Application Support/agterm`, `agterm-debug` | `…/hangar`, `hangar-debug` |
| `~/.config/agterm` | `~/.config/hangar` |
| socket `agterm.sock`, lock `agterm.lock` | `hangar.sock`, `hangar.lock` |
| skill plugin and marketplace `agterm`, marketplace owner Umputun | `hangar`, owner NaikSoftware |
| `agterm.com` links, skill `homepage`, `site/llms.txt` | `https://naiksoftware.github.io/hangar` |
| `agterm-qt` (binary, `.desktop`, Qt config dirs) | `hangar` on Linux |
| `agterm_mobile`, Android `ua.naiksoftware.agterm2` | `hangar_mobile`, `ua.naiksoftware.hangar` |
| `NaikSoftware/agterm` | `NaikSoftware/hangar` (GitHub redirects the old URL) |

Text that keeps the old name:
- the "Origins and attribution" credit to umputun/agterm, and macterm and Ghostty credits;
- cookbook `Author:` lines;
- `scripts/ghostty-patches/` and `scripts/zmx-patches/` patch bodies (they patch upstream code);
- released `CHANGELOG.md` entries.

## Repository layout

```
README.md  LICENSE  CLAUDE.md  .claude/  .github/  .claude-plugin/
plugins/hangar/        agent skill, shared by all three apps
cookbook/              recipes on the hangarctl protocol
site/                  user guide and command reference
docs/screenshots/      README images
macos/                 today's repo root content: Hangar/, HangarCore/, scripts/, Makefile, project.yml,
                       .swiftlint.yml, ARCHITECTURE.md, CONTRIBUTING.md, CHANGELOG.md, packaging/, docs/ (engineering)
linux/                 agterm-qt without mobile/: CMakeLists.txt, src/, tests/, scripts/, packaging/, resources/, share/, docs/
mobile/                agterm-qt/mobile
```

`.github/workflows/ci.yml` gets path filters and `working-directory: macos` for the macOS jobs.
Linux and mobile have no CI today and get none in this work.

## Approaches

1. **Scripted rename in one PR (picked).** A committed script does `git mv` for paths, then ordered text replacements, longest token first (`AgtermServerKit` before `Agterm`, `agtermctl` before `agterm`), over an explicit skip list. Then build, gates, and hand fixes for what the script misses. The half-renamed state exists only on the branch, and the script records exactly what changed.
2. **Phased PRs** (user-facing names, then modules, then paths). Rejected: master stays half-renamed for days, and each phase needs the compatibility shims that a clean break exists to avoid.
3. **User-facing rename only, internal names kept.** Rejected by the owner: it keeps upstream merges possible, but the owner chose a clean break.

## Decisions from review

- **Docs site:** GitHub Pages serves `site/` at `https://naiksoftware.github.io/hangar` (owner's choice). Canonical URLs, the skill homepage and every docs link point there. Cloudflare-specific notes in `CLAUDE.md` are removed.
- **Session hosts (builder's call):** the Swift host lives only inside `Hangar.app` and the C++ host installs into the Linux prefix, so one name, `hangar-session-host`, does not collide. `hangar-server` stays a product for remote Linux hosts and installs to `~/.local/lib/hangar-server`.
- **Remote hosts:** users run Hangar on separate Macs; nobody runs `agterm-server` hosts (owner's answer). The migration has no remote step. Two Macs that attach to each other must both be on Hangar, because wire keys such as `agtermLive` and `agterm://pair` change; the release notes say so.
- **Saved web logins (builder's call):** WebKit keys them by bundle id, so they are lost. The script's printout tells users to sign in again.
- **agterm-qt branches (builder's call):** import `main` only. The remote has no other branches and no open PRs.
- **CLAUDE.md and `.claude/rules` (builder's call):** swap names and paths, replace upstream-maintainer references (Eugene, `~/dev.umputun/agterm`, Homebrew, notarization, Cloudflare) with the fork's facts. No other editorial rewrite.
- **Product page (owner's request):** `site/index.html` gets a new design made in Claude Design, not a rename of upstream's page. The owner approves the mockup first; the page is then built to match it exactly.
- **Root Makefile (builder's call):** none. Commands run from `macos/`; `CLAUDE.md` says so.

## Order of work

1. **Restructure (no renames).** Move today's root content into `macos/`, keep the shared items at the root. Import agterm-qt with history: its root content (without `mobile/`) under `linux/`, its `mobile/` under `mobile/`. Fix scripts, Makefile, CI and docs paths so every gate passes. One commit series, reviewable as pure moves.
2. **Rename.** Run the rename script over all three projects, then fix and pass all gates.
3. **Docs.** README for Hangar (from the current draft), `site/`, the skill, `CLAUDE.md` and `.claude/rules` paths and names.
4. **Migration script** `macos/scripts/migrate-from-agterm2.sh` (see below), tested against a copy of real state.
5. **Repository rename** on GitHub, after the PR merges and with a final confirmation from the owner. Update `origin` URLs locally.
6. **Release.** A new release with `Hangar-<ver>.dmg` and `hangar-mobile.apk`.

## Migration script

Runs once on each user's Mac, after Hangar is installed and before it first starts. It is attached to the release as `migrate-from-agterm2.sh`, and it is safe to run twice.

1. Refuse to run while `agterm.app` or `Hangar.app` runs.
2. Stop the old zmx daemons and `agterm-session-host` processes of the old state dir.
3. Copy (not move) `~/Library/Application Support/agterm` to `…/hangar` and `~/.config/agterm` to `~/.config/hangar`, if the targets do not exist. Rewrite `agterm`/`AGTERM_` inside copied config files (`keymap.conf` commands may call `agtermctl`).
4. Remove the old agent hooks from `~/.claude/settings.json` and `~/.codex/`, the installed `agterm` skill, and `/usr/local/bin/agtermctl`. Hangar's first launch installs its own.
5. Print what it did and what is left for the user: remove `agterm.app`, grant Accessibility and other macOS permissions again, install the new phone app and pair again.

The old dirs stay as a backup; the user deletes them.

## Constraints

- `CLAUDE.md` rules still apply: never touch the live terminal's default socket; isolated Debug instances only; every gate once at the end.
- A Swift module rename changes `import` lines and `@testable import` lines; `project.yml` drives Xcode, so the Xcode project is regenerated, not edited.
- `agtermCore` is consumed by the `melonamin/agterm-linux` fork. That consumer breaks; accepted with the clean break.
- The phone and desktop speak one protocol. Any wire string that contains `agterm` changes on both sides in the same PR.
- Developer ID signing is not used; builds stay ad-hoc signed.

## Left to the builder

- The exact skip list, after a first dry run lists every match.
- Commit granularity inside each step.
- How to keep worktree artifact symlinks (`GhosttyKit.xcframework`, stamps, resources) valid after the move to `macos/`.
