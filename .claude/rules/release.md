---
paths:
  - "macos/scripts/release.sh"
---

## Release (`scripts/release.sh`)

- **Releases are local; there is no `release.yml`.** Run `scripts/release.sh <version> --publish` on the
  owner's Mac. The script builds Release, creates the tag and GitHub release, and uploads the DMG.
  There is no Homebrew cask; the DMG on the release is the only macOS install path.
- With a `Developer ID Application` identity in the keychain and a `hangar-notary` notary profile, the
  script signs, notarizes and staples the app and DMG. The DMG container must be codesigned before
  notarization or `spctl` rejects `hdiutil`'s unsigned image.
- Without that identity the build is ad-hoc and not notarized. `--publish` then needs
  `HANGAR_ALLOW_UNSIGNED=1`, and the release notes tell users to clear the quarantine flag.
  The README and `site/` say the build is not notarized; change them together if that changes.
- Without `--publish`, the full build/sign dry-run stops before upload.
- Each release also ships hangar-server: `release.sh` needs Docker running, runs `scripts/setup-zmx-linux.sh`, and
  packages `hangar-server-VERSION-linux-{aarch64,x86_64}.tar.gz` with `scripts/server-package.sh` before the Xcode
  build. Their sha256 lines go into the app as `Contents/Resources/hangar-server.sha256` before the re-seal (an
  ad-hoc re-seal on the unsigned path), and `--publish` uploads the DMG, both tarballs, `migrate-from-agterm2.sh`
  and, with `MOBILE_APK=<path>`, `hangar-mobile.apk` in one `gh release upload --clobber`.
  `hangarctl server install` trusts only that bundled file, so a tarball rebuilt after the app was sealed no
  longer installs.
- Developer ID signing is inside-out: `hangarctl`, zmx and `hangar-session-host` are signed first with no
  entitlements, then the app is sealed with its TCC entitlements. The script rejects any helper carrying them.
- Before writing or committing a release section, put the exact `CHANGELOG.md` text in a temp file and
  pass it through the `draft-approval` skill's `draft-review.sh`; address annotations and get explicit
  chat approval. `release.sh:70-85` publishes that text as the GitHub release body.
- **Commit and push the changelog and website version to `master` before `release.sh --publish`.**
  `gh release create "$TAG"` has no `--target` (`release.sh:166`), so it tags `origin/master`, not local
  `HEAD`. The script pushes nothing; the owner must push the main repo.
- Manually set `site/index.html`'s `SoftwareApplication.softwareVersion` in that same pre-release push;
  `release.sh` does not edit it. GitHub Pages deploys `site/` on push, and the DMG links already use
  GitHub's latest release.
- Bump `version` in `.claude-plugin/marketplace.json` and both `plugins/hangar/{.claude,.codex}-plugin/plugin.json`
  in that same commit.
  Otherwise `release.sh` bumps them itself and exits before building, asking for a commit and a re-run.
