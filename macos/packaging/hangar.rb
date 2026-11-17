# Source-of-truth Homebrew cask for hangar. scripts/release.sh seeds this into
# umputun/homebrew-apps (Casks/hangar.rb) on first publish and rewrites the
# version + sha256 lines on every release.
cask "hangar" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/NaikSoftware/hangar/releases/download/v#{version}/hangar-#{version}.dmg"
  name "hangar"
  desc "Terminal on libghostty with a workspace/session sidebar"
  homepage "https://github.com/NaikSoftware/hangar"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Hangar.app"
  binary "#{appdir}/Hangar.app/Contents/MacOS/hangarctl", target: "hangarctl"

  # strip Homebrew's com.apple.quarantine so brew install/upgrade opens with no
  # "downloaded from the internet" prompt. the app is Developer ID signed, notarized,
  # and stapled, but that only removes the unidentified-developer block and the online
  # check - Gatekeeper still shows the first-launch confirm whenever the quarantine attr
  # is present, and brew re-stamps it on every fresh bundle. the strip runs on the staged copy
  # before the move: brew's install-steps worker does not inherit the terminal's TCC grants, and
  # macOS can refuse it on the bundle in appdir. a failure only costs that prompt, so it warns.
  preflight_steps do
    run "/bin/sh",
        args: [
          "-c",
          'err=$(/usr/bin/xattr -dr com.apple.quarantine "$1" 2>&1 >/dev/null) || ' \
          'echo "Warning: could not remove quarantine from $1 ($(printf "%s\n" "$err" | head -n 1)); ' \
          'macOS may ask to confirm the first launch" >&2',
          "sh",
          "{{staged_path}}/Hangar.app",
        ]
  end

  zap trash: [
    "~/Library/Application Support/hangar",
    "~/Library/Preferences/ua.naiksoftware.hangar.plist",
    "~/Library/Saved Application State/ua.naiksoftware.hangar.savedState",
  ]
end
