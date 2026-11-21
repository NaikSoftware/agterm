# Elis Mobile

The phone app for Elis (Flutter, Android): the session tree with status dots (pulsing while an agent works), a
session's screen in two modes, Chat (a Claude Code conversation drawn as a native chat from its transcript) and Term
(the terminal grid) with Fit to phone, on while the screen is open (gives the program the phone's columns and rows, so it redraws for the phone and
nothing wraps, and gives the grid back on leave), typing into it, direct input of a Live pane (the phone leads a Live pane it opens), the sidebar's row menus, and notifications when an agent blocks or finishes while the app is in the background, over
the TLS relay that `elisctl mobile serve` runs on the computer. The project
README's [Phone app](../linux/README.md#phone-app) section covers the relay and its security model.

## Build and run

Needs Flutter and the Android SDK, and Gradle needs a full JDK 21 (one with `javac` and `jlink`; a JRE is not enough):
point `JAVA_HOME` at it or run `flutter config --jdk-dir <jdk>`.

```sh
cd mobile
./tool/build-vtshim.sh       # once per ghostty pin or shim change: libvtshim for Android and the host (needs zig@0.17, NDK 28.2)
flutter pub get
flutter run                 # on a connected device or emulator
flutter build apk           # build/app/outputs/flutter-apk/app-release.apk
```

`libvtshim` (`native/vtshim.c`) parses the pane's stream and, for direct input, exports the key, paste, wheel and focus
encoders and the terminal's query replies (`vts_encode_*`, `vts_take_replies`); a new export joins the `FUNCS` list
in `tool/build-vtshim.sh`.

## Pairing

1. On the computer, open Settings ▸ Connect a Phone… in Elis and switch it on. Pick the address the phone reaches
   the computer at (or type one, e.g. a Tailscale name). Or, in any terminal, run `elisctl mobile serve` (`--host` sets
   the address); it prints the same QR code and `elis://pair?…` link and serves while it runs.
2. In the app, tap Scan pairing code and point the camera at the code, or paste the link and tap Connect.
3. Revoke Paired Phones in that window (or `elisctl mobile reset`) revokes the pairing; scan the new code to pair anew.

## Background alerts

While the app is in the background it keeps its connection in a foreground service ("Watching <computer>") and posts
one notification per session when its agent is blocked, has finished, or sends a notification; tapping one opens that
session. Turn it off under More ▸ Alerts in the background. Android may delay alerts while the phone sleeps (Doze), and
some vendors' battery savers stop the service.

## Tests

```sh
flutter test                                   # unit tests; the live relay test skips itself
ELIS_PAIR_LINK='elis://pair?…' flutter test test/relay_live_test.dart
```

The live test needs a running Elis and `elisctl mobile serve` reachable from the test host (`--host 127.0.0.1`
for a local run); it creates a session named `from-phone` and types into it.

On a device or emulator (an emulator reaches the computer at 10.0.2.2, so run `serve --host 10.0.2.2`), with a session
named `phone-target` open on the computer:

```sh
flutter test integration_test/app_test.dart -d emulator-5554 --dart-define=PAIR_LINK='elis://pair?…'
```

It uninstalls the app when it finishes.

Fonts: Inter, JetBrains Mono and Noto Sans Symbols 2 (the fallback for agent glyphs JetBrains Mono lacks), SIL Open Font
License 1.1 (`assets/fonts/OFL-*.txt`).
