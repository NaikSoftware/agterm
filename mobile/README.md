# agterm Mobile

The phone app for agterm-qt (Flutter, Android): the session tree with status dots (pulsing while an agent works), a
session's screen with Fit to phone, on while the screen is open (gives the program the phone's columns and rows, so it redraws for the phone and
nothing wraps, and a drag scrolls the program itself; Restore PC size gives the grid back to the computer), typing into it, the sidebar's row menus, and notifications when an agent blocks or finishes while the app is in the background, over
the TLS relay that `agtermctl mobile serve` runs on the computer. The project
README's [Phone app](../linux/README.md#phone-app) section covers the relay and its security model.

## Build and run

Needs Flutter and the Android SDK, and Gradle needs a full JDK 21 (one with `javac` and `jlink`; a JRE is not enough):
point `JAVA_HOME` at it or run `flutter config --jdk-dir <jdk>`.

```sh
cd mobile
flutter pub get
flutter run                 # on a connected device or emulator
flutter build apk           # build/app/outputs/flutter-apk/app-release.apk
```

## Pairing

1. On the computer, open Settings ▸ Connect a Phone… in agterm-qt and switch it on. Pick the address the phone reaches
   the computer at (or type one, e.g. a Tailscale name). Or, in any terminal, run `agtermctl mobile serve` (`--host` sets
   the address); it prints the same QR code and `agterm://pair?…` link and serves while it runs.
2. In the app, tap Scan pairing code and point the camera at the code, or paste the link and tap Connect.
3. Revoke Paired Phones in that window (or `agtermctl mobile reset`) revokes the pairing; scan the new code to pair anew.

## Background alerts

While the app is in the background it keeps its connection in a foreground service ("Watching <computer>") and posts
one notification per session when its agent is blocked, has finished, or sends a notification; tapping one opens that
session. Turn it off under More ▸ Alerts in the background. Android may delay alerts while the phone sleeps (Doze), and
some vendors' battery savers stop the service.

## Tests

```sh
flutter test                                   # unit tests; the live relay test skips itself
AGTERM_PAIR_LINK='agterm://pair?…' flutter test test/relay_live_test.dart
```

The live test needs a running agterm-qt and `agtermctl mobile serve` reachable from the test host (`--host 127.0.0.1`
for a local run); it creates a session named `from-phone` and types into it.

On a device or emulator (an emulator reaches the computer at 10.0.2.2, so run `serve --host 10.0.2.2`), with a session
named `phone-target` open on the computer:

```sh
flutter test integration_test/app_test.dart -d emulator-5554 --dart-define=PAIR_LINK='agterm://pair?…'
```

It uninstalls the app when it finishes.

Fonts: Inter, JetBrains Mono and Noto Sans Symbols 2 (the fallback for agent glyphs JetBrains Mono lacks), SIL Open Font
License 1.1 (`assets/fonts/OFL-*.txt`).
