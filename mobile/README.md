# agterm Mobile

The phone app for agterm-qt (Flutter, Android): the session tree with status dots, a session's screen, typing into it,
and the sidebar's row menus, over the TLS relay that `agtermctl mobile serve` runs on the computer. The project
README's [Phone app](../README.md#phone-app) section covers the relay and its security model.

## Build and run

```sh
cd mobile
flutter pub get
flutter run                 # on a connected device or emulator
flutter build apk           # build/app/outputs/flutter-apk/app-release.apk
```

## Pairing

1. On the computer, in any terminal: `agtermctl mobile serve` (add `--host <name or IP>` when the phone reaches it by
   another address, e.g. over Tailscale). It prints a QR code and an `agterm://pair?…` link and serves while it runs.
2. In the app, tap Scan pairing code and point the camera at the code, or paste the link and tap Connect.
3. `agtermctl mobile reset` on the computer revokes the pairing; run `serve` again and pair anew.

## Tests

```sh
flutter test                                   # unit tests; the live relay test skips itself
AGTERM_PAIR_LINK='agterm://pair?…' flutter test test/relay_live_test.dart
```

The live test needs a running agterm-qt and `agtermctl mobile serve` reachable from the test host (`--host 127.0.0.1`
for a local run); it creates a session named `from-phone` and types into it.
