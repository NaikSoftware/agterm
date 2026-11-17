# Hangar rename and monorepo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One repository `NaikSoftware/hangar` with `macos/`, `linux/`, `mobile/`, every agterm name replaced by Hangar, a one-time user migration script, and a new product page.

**Architecture:** Two committed, re-runnable scripts do the mechanical work: `tools/hangar/restructure.sh` (moves and the agterm-qt import) and `tools/hangar/rename.sh` (path moves plus ordered token replacement over a skip list). Hand fixes follow each script. Both scripts run again on a fresh master just before the merge.

**Tech Stack:** bash, git, Swift 6 / Xcode 26 / xcodegen, CMake + Qt6/KF6, Flutter (Dart 3.13), GitHub Pages.

**Spec:** `docs/superpowers/specs/2026-11-17-hangar-rename-design.md`

## Global Constraints

- Worktree: `/Users/n.savchenko/IdeaProjects/agterm/.claude/worktrees/hangar-rename`, branch `worktree-hangar-rename`. Never touch the main checkout or the live terminal.
- Verbatim for every delegated agent: “never execute `agterm`/`agtermctl` against the default socket, never launch or quit the app, static reading only.”
- No compatibility shims, aliases or fallbacks to old names in any app.
- Kept old names, and only these: umputun/agterm, macterm and Ghostty credits; cookbook `Author:` lines; `scripts/ghostty-patches/` and `scripts/zmx-patches/` bodies; released `CHANGELOG.md` entries; `tools/hangar/` itself; the old paths inside the migration script.
- Name map: exactly the table in the spec. Bundle id `ua.naiksoftware.hangar`, Debug `ua.naiksoftware.hangar.debug`, CLI `ua.naiksoftware.hangar.hangarctl`. Site `https://naiksoftware.github.io/hangar`.
- macOS gates, from `macos/`, once at the end of each code task: build, `swift test`, `make test-app`, `make lint`.
- Mobile gates, from `mobile/`: `flutter analyze --no-pub`, `flutter test --no-pub`. An APK build needs a temporary `sdk: ^3.13.2` in `pubspec.yaml`, restored afterwards.
- Linux gates (`cmake --build`, `ctest`, `scripts/smoke.sh`) need a Linux host. Without one, the PR states "Linux build unverified".
- Commit messages end with `Claude-Session: https://claude.ai/code/session_018MUCCSMmJJaQv76eW9mZ5H`. Every `gh` call passes `--repo NaikSoftware/agterm` (after Task 8, `NaikSoftware/hangar`).

## Review Focus

1. Phone ↔ desktop wire strings (`agterm://pair`, JSON keys such as `agtermLive`, `agtermPaneId`, relay handshake labels) renamed on one side only: pairing or attach fails silently. Task 5 adds a cross-check test.
2. A user's `keymap.conf` `command` lines that call `agtermctl` by name break after migration. Task 7 rewrites and tests them.
3. Old hooks and the old `agterm` skill stay installed next to the new ones: the agent sees two skills and two status hooks fire. Task 7 removes them and tests it.
4. A stray `agterm.sock` default in one resolver splits CLI and app. Task 4 tests that both derive the same default path.
5. The token pass turns `agterm` inside a kept credit or an unrelated word. Task 3's check fails on any match outside the skip list and on a missing credit line.

---

### Task 1: Restructure into `macos/` (moves only)

**Files:**
- Create: `tools/hangar/restructure.sh`
- Modify: `.github/workflows/ci.yml`, `CLAUDE.md` and `.claude/rules/*.md` (paths only), `macos/Makefile`, every `macos/scripts/*` or `macos/project.yml` path that points at a root-level shared dir (`plugins/`, `site/`, `cookbook/`, `docs/screenshots/`)

**Interfaces:**
- Produces: `macos/{agterm,agtermCore,agtermTests,agtermUITests,scripts,packaging,docs,Makefile,project.yml,.swiftlint.yml,ARCHITECTURE.md,CONTRIBUTING.md,CHANGELOG.md}`. The root keeps `README.md LICENSE CLAUDE.md .claude/ .github/ .claude-plugin/ plugins/ cookbook/ site/ docs/screenshots/ tools/`.

- [ ] **Step 1:** Write `restructure.sh` phase 1: exit 0 when `macos/` exists; `git mv` each listed path into `macos/`; move `docs/*` except `docs/screenshots` into `macos/docs/`.
- [ ] **Step 2:** Run it. Expected: `git status` shows only renames.
- [ ] **Step 3:** Fix every path that crossed the boundary: `rg -n '(\.\./)?(plugins|site|cookbook|docs/screenshots)/' macos/project.yml macos/scripts macos/Makefile .github/workflows`. CI jobs get `working-directory: macos` and `macos/**` path filters.
- [ ] **Step 4:** Re-link the worktree artifacts under `macos/` (`GhosttyKit.xcframework`, `agterm/Resources/{ghostty,terminfo,zmx}`, both stamps) after CLAUDE.md's stamp check.
- [ ] **Step 5:** macOS gates. Expected: all pass, the same test counts as before the move.
- [ ] **Step 6:** Commit `refactor: move the macOS app into macos/`.

### Task 2: Import agterm-qt with history

**Files:**
- Modify: `tools/hangar/restructure.sh` (phase 2), `linux/scripts/import-file-icons.sh` (path to the Swift app), `linux/README.md`, `mobile/README.md`

**Interfaces:**
- Consumes: Task 1 layout.
- Produces: `linux/` = agterm-qt `main` without `mobile/`; `mobile/` = agterm-qt `main:mobile`.

- [ ] **Step 1:** Phase 2: when `linux/` is absent, `git subtree add --prefix=linux https://github.com/NaikSoftware/agterm-qt.git main`, then `git mv linux/mobile mobile`.
- [ ] **Step 2:** Verify history. Expected: `git log --oneline --follow -- mobile/lib/theme.dart | wc -l` > 1 and `git log --oneline -- linux/src | wc -l` > 1.
- [ ] **Step 3:** Fix cross-repo paths (`import-file-icons.sh` reads `../macos/...`).
- [ ] **Step 4:** Mobile gates. Expected: no analyzer issues, all tests pass.
- [ ] **Step 5:** Commit `chore: import agterm-qt as linux/ and mobile/ with history`.

### Task 3: Rename script and name check

**Files:**
- Create: `tools/hangar/rename.sh`, `tools/hangar/check-names.sh`, `tools/hangar/skip.txt`

**Interfaces:**
- Produces: `rename.sh [--dry-run]` (the dry run prints every path move and the match count per token, and changes nothing). `check-names.sh` exits 0 only when `git grep -n -i agterm` matches nothing outside the `skip.txt` globs and every credit line listed in `skip.txt` still exists.

- [ ] **Step 1:** Write `check-names.sh` and run it. Expected: FAIL, about 20,000 matches.
- [ ] **Step 2:** Write `rename.sh`. Phase A: `git mv` paths, deepest first, applying the token map to each path segment. Phase B: content replacement over `git ls-files` minus binaries and `skip.txt`, tokens in this order:
  `AgtermServerKit→HangarServerKit`, `AgtermResponsibility→HangarResponsibility`, `agtermctlKitTests→hangarctlKitTests`, `agtermctlKit→hangarctlKit`, `agtermCoreTests→HangarCoreTests`, `agtermCore→HangarCore`, `agtermUITests→HangarUITests`, `agtermTests→HangarTests`, `ua.naiksoftware.agterm2→ua.naiksoftware.hangar`, `com.umputun.agterm→ua.naiksoftware.hangar`, `agterm-session-host→hangar-session-host`, `agterm-server→hangar-server`, `agterm-qt→hangar`, `agterm_mobile→hangar_mobile`, `agtermctl→hangarctl`, `AGTERM_→HANGAR_`, `Agterm2→Hangar`, `AGTERM→HANGAR`, `Agterm→Hangar`, `agterm→hangar`. The app target folder `macos/agterm` becomes `macos/Hangar`, and `PRODUCT_NAME` becomes `Hangar`.
- [ ] **Step 3:** `rename.sh --dry-run > /tmp/hg-rename.txt`. Read every match class; add each credit or history line found to `skip.txt`.
- [ ] **Step 4:** Run `rename.sh`, then `check-names.sh`. Expected: PASS.
- [ ] **Step 5:** Commit the tooling (`chore: rename tooling`), then the result (`refactor: rename agterm to Hangar`).

### Task 4: macOS builds and passes after the rename

**Files:**
- Modify: whatever the build and tests reject. Expect `macos/project.yml`, `macos/HangarCore/Package.swift`, `StateDirectory`/`DebugStateDirectory`, socket and lock names, `Logger(subsystem:)` sites, installer path constants.
- Test: `macos/HangarCore/Tests/HangarCoreTests/DefaultSocketPathTests.swift`

**Interfaces:**
- Produces: state dir `~/Library/Application Support/hangar` (Debug `hangar-debug`), config `~/.config/hangar`, socket `hangar.sock`, lock `hangar.lock`.

- [ ] **Step 1:** Test `testCLIAndAppDefaultSocketMatch`: with no `--socket` and no `HANGAR_STATE_DIR`, the CLI resolver returns `~/Library/Application Support/hangar/hangar.sock`, and the app-side constant returns the same path.
- [ ] **Step 2:** `xcodegen`, build, fix errors until it builds.
- [ ] **Step 3:** macOS gates. Expected: all pass. Then `lsappinfo list | grep -A4 hangar.debug` shows no leaked entry.
- [ ] **Step 4:** Commit `fix: build and tests after the rename`.

### Task 5: Linux and mobile after the rename

**Files:**
- Modify: `linux/CMakeLists.txt` (`project(hangar)`; executables `hangar`, `hangar-session-host`, `hangarctl`), `linux/packaging/hangar.desktop.in`, `mobile/pubspec.yaml` (`name: hangar_mobile`), `mobile/android/app/build.gradle.kts` (`namespace` and `applicationId` `ua.naiksoftware.hangar`), `mobile/android/app/src/main/AndroidManifest.xml` (`android:label="Hangar"`, deep-link scheme `hangar`), Kotlin package dirs under `mobile/android/app/src/main/kotlin/ua/naiksoftware/`
- Test: `mobile/test/wire_names_test.dart`

- [ ] **Step 1:** `wire_names_test.dart`: each wire key the app sends or parses (from `client.dart`, `model.dart`, `pair.dart`) appears in the matching Swift source under `macos/HangarCore` (the test reads the file), and none contains `agterm`.
- [ ] **Step 2:** Fix until the mobile gates pass. Build a debug APK.
- [ ] **Step 3:** Linux gates in a Linux container if one is available (the `macos/scripts/server-container.sh` pattern); otherwise record "Linux build unverified".
- [ ] **Step 4:** Commit `fix: linux and mobile after the rename`.

### Task 6: Docs, site and product page

**Files:**
- Modify: `README.md` (paths to `linux/`, `mobile/`, screenshots), `site/*.html`, `site/llms.txt`, `plugins/hangar/**`, `.claude-plugin/marketplace.json` (owner NaikSoftware, repo `NaikSoftware/hangar`), `CLAUDE.md`, `.claude/rules/*.md`
- Create: `site/index.html` from the approved Claude Design page (project `381f205d-4d43-4d59-abac-576032711810`, `index.dc.html`), `site/assets/shot-*.webp` from `docs/screenshots/new/`, `.github/workflows/pages.yml`
- Delete: the Cloudflare notes; `docs/screenshots/*.png` that show upstream UI

- [ ] **Step 1:** Build `site/index.html` to match the mockup exactly: status legend with a fading blue circle, a static orange triangle and a green diamond; macOS and Linux download buttons; the Android APK link; local WebP images.
- [ ] **Step 2:** Canonical URLs, the skill `homepage` and docs links point to `https://naiksoftware.github.io/hangar`.
- [ ] **Step 3:** `CLAUDE.md`: replace Eugene, `~/dev.umputun/agterm`, Homebrew, notarization and Cloudflare facts with the fork's; commands run from `macos/`.
- [ ] **Step 4:** `pages.yml` deploys `site/` on every push to master.
- [ ] **Step 5:** `check-names.sh` passes. Render `site/index.html` with Playwright (channel chrome) at 1440 and 390 and compare it with the mockup side by side.
- [ ] **Step 6:** Commit `docs: Hangar docs, site and product page`.

### Task 7: One-time migration script

**Files:**
- Create: `macos/scripts/migrate-from-agterm2.sh`, `macos/scripts/tests/migrate-from-agterm2-test.sh`

**Interfaces:**
- Produces: `migrate-from-agterm2.sh [--home DIR] [--dry-run]`. `--home` exists for the test and skips the running-app check.

- [ ] **Step 1:** The test builds a fake HOME with: the old state dir (a sessions file); `~/.config/agterm/{keymap.conf,ghostty.conf,restore-denylist.conf}` where `keymap.conf` has a `command` line calling `agtermctl`; `.claude/settings.json` with agterm hooks plus one unrelated hook; `.claude/skills/agterm/`; `.codex/` hooks. Assertions: the new dirs exist with byte-identical sessions content; `keymap.conf` calls `hangarctl`; the agterm hooks and skill are gone; the unrelated hook is byte-identical; the old dirs still exist; a second run changes nothing and exits 0.
- [ ] **Step 2:** Run it. Expected: FAIL (script missing).
- [ ] **Step 3:** Implement per the spec's Migration section. Refuse to run while `pgrep -x agterm` or `pgrep -x Hangar` finds a process. Stop the old zmx daemons and `agterm-session-host` processes whose state dir is the old one (skipped under `--home`). Edit JSON with `python3 -I` (stdlib only).
- [ ] **Step 4:** Run the test. Expected: PASS. Commit `feat: one-time migration from Agterm2`.

### Task 8: Final run, merge, repo rename, release

- [ ] **Step 1:** The owner holds merges. `git fetch && git merge origin/master`; re-run `restructure.sh` and `rename.sh` on the merged tree (both idempotent); `check-names.sh`; every gate once.
- [ ] **Step 2:** Open the PR (`--repo NaikSoftware/agterm`). After the owner merges, verify the merge commit on `origin/master`.
- [ ] **Step 3:** Ask the owner to confirm, then `gh repo rename hangar --repo NaikSoftware/agterm`; update local `origin` URLs; enable Pages (source: GitHub Actions).
- [ ] **Step 4:** Archive agterm-qt (owner's request, 2026-11-17): push one commit to `NaikSoftware/agterm-qt` `main` whose README says the project moved to `NaikSoftware/hangar` (`linux/`, `mobile/`), then `gh repo archive NaikSoftware/agterm-qt --yes`. The local clone stays; the owner removes it.
- [ ] **Step 5:** Release with `Hangar-<ver>.dmg`, `hangar-mobile.apk` and `migrate-from-agterm2.sh`. The notes tell users to run the script, and that two attached Macs must both update.
