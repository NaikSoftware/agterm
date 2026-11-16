# agterm Mobile over Bluetooth — design

## Intent

agterm Mobile must drive a Mac's agterm with no cable and no Wi-Fi path. On the user's managed Mac an endpoint firewall (ESET, Kandji-managed) refuses incoming LAN connections and blocks non-Apple binaries from reaching LAN devices, so the TLS relay over Wi-Fi and wireless adb both fail. A network firewall does not see Bluetooth.

## Goals

- Full feature parity with the TLS relay: session tree, session screen at the same refresh, typing, scrollback, Fit to phone, drag scroll, alerts in the background, every `phone`-reachable command.
- Same pairing: one QR code pairs Wi-Fi and Bluetooth. The phone picks a working transport by itself.
- Same security level as the TLS relay: only a holder of the pairing token gets in; traffic is confidential and tamper-evident; `mobile reset` cuts Bluetooth phones off too.
- Android 15 (API 35) and newer on the phone.

## Non-goals

- Bluetooth on agterm-qt (Linux). The phone keeps working there over TLS; a Linux peripheral is a later task.
- iOS.
- Bluetooth Classic (RFCOMM), Bluetooth tethering (PAN).
- Several Macs over Bluetooth at once on one phone (one active pairing per transport, as today).

## Anti-goals

- A Bluetooth link that anyone in radio range can use or read without the token.
- A second protocol: Bluetooth carries the same `{cmd,target,args,id}` JSON lines; no command gets a Bluetooth-only shape.
- Mac-wide side effects: no change to the Mac's routing or network interfaces.

## Constraints

- macOS: CoreBluetooth peripheral role (`CBPeripheralManager`), L2CAP CoC via `publishL2CAPChannel` (macOS 10.13+). `agtermctlKit` already imports Network and CryptoKit inside `#if os(macOS)` files; CoreBluetooth joins them there, so the Linux build is unaffected. A process that uses CoreBluetooth needs `NSBluetoothAlwaysUsageDescription` in the responsible app's Info.plist and a one-time TCC grant; the relay runs as agterm's child, so agterm's Info.plist carries the key. A hand-run `agtermctl mobile serve` is attributed to the terminal app hosting it.
- Android 15: `BLUETOOTH_SCAN` (with `neverForLocation`) and `BLUETOOTH_CONNECT` runtime permissions; `BluetoothDevice.createInsecureL2capChannel(psm)` / `createL2capChannel(psm)` give a stream socket (API 29+). A foreground service of type `connectedDevice` keeps the link in the background.
- Flutter has no maintained L2CAP plugin: the phone side is a small Kotlin platform channel (scan, connect, socket streams).
- Throughput: L2CAP CoC over LE 2M PHY gives roughly 100–300 KB/s Pixel↔Mac (to be measured in the spike); GATT notifications give far less. Range ~10 m.
- Existing relay code (`agtermCore/Sources/agtermctlKit/MobileCommands.swift`) owns auth, per-phone order, grid release, `phone.*` refusal, revoke; it must not fork into a second copy.

## Approaches

1. **L2CAP CoC stream (chosen).** GATT only advertises the service and exposes the channel's PSM; data flows over an L2CAP connection-oriented channel, a byte stream like TCP. Highest BLE throughput, plain stream framing, the relay's line protocol reused unchanged. Cost: a Kotlin platform channel on the phone; L2CAP behaviour differs across Android vendors (Pixel is the target).
2. **GATT characteristics (rejected).** Write-without-response in, notifications out, chunked to the MTU. Works through `flutter_blue_plus` with no native code, but throughput is several times lower and needs chunk framing and flow control; "full featured" scrollback and refresh would lag.
3. **Classic RFCOMM / PAN (rejected).** RFCOMM: old macOS server API, unmaintained Flutter plugins. PAN: a network interface the firewall likely filters, and it can reroute the Mac's traffic.

## Design

### Pairing link
The QR link gains one parameter: `agterm://pair?h=…&p=…&t=TOKEN&f=FP&n=NAME&b=1`. `b=1` means this Mac offers Bluetooth. Older phones ignore it. The phone stores it with the pairing.

### Pairing link (Bluetooth-only case) — builder's call
`f` is always present, so the pairing's stored identity becomes `f` (the certificate fingerprint), not `host:port`. With no LAN address, serve omits `h`/`p` instead of writing `127.0.0.1`; `Pairing.parse` accepts a link with `b=1` and no `h`. Existing stored pairings migrate by keeping their `host:port` entries and adding `f` as the key.

### Discovery
- `CBPeripheralManager.startAdvertising` carries only a local name and service UUIDs, so the tag lives in the UUID itself: the service UUID is the first 16 bytes of `HMAC-SHA256(token, "agterm-ble-adv")`, with the RFC 4122 version/variant bits set. The phone scans with that UUID as filter. A stranger sees an opaque UUID that changes on `mobile reset`. The local name is omitted (it would expose the Mac's name).
- The service has one read-only characteristic: the L2CAP PSM (2 bytes, little endian) that `publishL2CAPChannel(withEncryption: false)` returned. Both sides use the insecure L2CAP forms (`createInsecureL2capChannel` on Android): the secure forms need a bonded link and bring up the OS pairing dialog. Noise provides the security.
- Only one relay advertises per Mac: serve takes an exclusive `flock` on `<stateDir>/mobile/bluetooth.lock`; a second serve prints `Bluetooth: in use by another relay` and serves TLS only. (builder's call)
- Several phones may connect at once if macOS accepts several centrals on one PSM; the spike checks it. If not, one phone at a time, and a second phone's handshake gets the busy frame below. (builder's call)

### Link security (application layer, on top of the L2CAP stream)
BLE link-layer pairing is not used (no OS pairing dialog, no bond). Instead a Noise `NNpsk0` handshake with `psk = HKDF(token, "agterm-ble-psk")`:
- X25519 ephemeral keys both sides, ChaCha20-Poly1305, SHA-256 (CryptoKit on the Mac; `package:cryptography` on the phone).
- A wrong token fails the handshake; the Mac sends one unencrypted reject byte (`0x01` = wrong key, `0x02` = busy) and closes. The byte reveals nothing a stranger could use, and lets the phone say "The pairing was revoked. Pair this computer again." After a reset the old UUID disappears, so the phone also shows "Can't find <Mac>: out of range, Bluetooth off, or the pairing was reset" after 2 minutes without a match while TLS also fails. (builder's call)
- After the handshake every frame is `u16 length ‖ ciphertext` (max 4 KB plaintext per frame, a JSON line may span frames); nonces are per-direction counters.
- Forward secrecy from the ephemeral keys; `mobile reset` changes the psk, so old phones fail the next handshake, and an open link is closed by the same 5 s token check the TLS relay runs.

Inside the encrypted stream the protocol is exactly the TLS relay's: the first line `{"auth":TOKEN,"id":N}`, then `{cmd,target,args,id}` lines. Keeping the auth line means the existing per-phone state machine runs unchanged.

### Mac side
- `MobileCommands.swift` splits into a transport-neutral `PhoneSession` (auth, order queue, grid claims and release, `phone.*` refusal, revoke watch, logging) and two transports: the existing TLS listener and a new `BluetoothTransport` (CoreBluetooth peripheral + L2CAP + the Noise framer). Both produce a byte stream into `PhoneSession`.
- `agtermctl mobile serve [--bluetooth|--no-bluetooth]`: Bluetooth is on by default when the radio is available; serve prints `Bluetooth: advertising` or the reason it is off (powered off, unauthorized, unsupported) on stderr as a status line.
- Events keep their shape; `ip` becomes the peer label (`bt:<4-hex>` for a Bluetooth phone) so `phone.connected|disconnected|refused` need no new kinds.
- Connect a Phone window: a "Bluetooth" status line (Advertising / Off: reason / Not allowed — open System Settings). `phone.status` and `tree.phone` gain `bluetooth: "advertising"|"off"|"unauthorized"|"unsupported"`.
- agterm's Info.plist gains `NSBluetoothAlwaysUsageDescription`.

### Phone side (agterm-qt repo, `mobile/`)
- `Connection` gains a transport interface; `TlsTransport` (today's code) and `BleTransport` (Kotlin platform channel: scan by service UUID + tag, read PSM, open L2CAP, byte streams).
- Transport choice per connect: try TLS first with a 3 s timeout when `h` is set, then Bluetooth when `b=1`. A setting "Prefer Bluetooth" flips the order. The session screen shows which transport is live (a small "BT" / "Wi-Fi" badge).
- Reconnect: on link loss the existing reconnect loop retries both transports.
- Permissions: request `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` at the first Bluetooth connect. The background service declares `specialUse|connectedDevice` in the manifest but passes `connectedDevice` to `startForeground` only when `BLUETOOTH_CONNECT` is granted (Android 14+ throws otherwise), so a user without Bluetooth keeps background alerts over TLS.
- `minSdk` becomes 35 for the whole app, TLS included (the user's decision: Android 15 minimum).
- Performance: the spike measured about 63 KB/s each way (2M PHY, 15 ms interval, untuned), so frames are deflate-compressed by default (raw DEFLATE per frame inside the ciphertext, both sides; terminal text compresses 5–10×). A screen refresh (2–8 KB) then costs well under 100 ms and a 2000-line scrollback about 0.5 s. The phone requests `CONNECTION_PRIORITY_HIGH` after connect. Tuning (larger writes, DCK priority) is the builder's call if numbers fall short.

## Verification

- Gate (user's decision): if the spike shows Kandji or ESET blocks Bluetooth advertising or L2CAP on the user's Mac, stop and report; no product code is written before the spike passes.
- Spike result (2026-11-16, PASSED on the managed Mac + Pixel): TCC prompt once, then allowedAlways; advertising seen ~200 ms after scan; PSM read ~1.3 s; L2CAP open 1.3–1.45 s from scan start (maxTx 2048); echo RTT 32–98 ms; 1 MiB at 65 KB/s Mac→phone and 62 KB/s phone→Mac; a second concurrent L2CAP channel on the same PSM works. No Kandji/ESET/bluetoothd deny messages. An ad-hoc rebuild re-prompts TCC unless signed with an identifier-based designated requirement (`codesign -s - -r='designated => identifier "<id>"'`); Debug builds of agterm need the same to keep the Bluetooth grant. Notes: scratchpad/btspike/NOTES.md.
- Spike first (throwaway): a minimal macOS `.app` (own Info.plist, CoreBluetooth peripheral + L2CAP echo) and a minimal Android test app or a Kotlin snippet on the Pixel; measure connect time and throughput, and confirm Kandji/ESET allow it.
- Mac: unit tests for the Noise framer against fixed test vectors; `PhoneSession` tests through an in-memory transport (both transports share them); a hosted test for the window's Bluetooth status line with a fake.
- Phone: Dart unit tests for the framer with the same vectors; a manual end-to-end run on the Pixel: pair by QR with Wi-Fi off, open a session, Fit to phone, scroll, background alert.

## Left to the builder

- Exact UUIDs, frame size, scan timeouts.
- Kotlin channel API shape.
- Whether `PhoneSession` lives in one file or two.
