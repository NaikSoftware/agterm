# Phone Link Protocol Model (M2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tested, transport-free model of the phone link v2 protocol (frames, streaming decoder, typed payloads, credit
windows, send scheduler) in Swift, mirrored by a Dart codec on the phone, both pinned by one set of golden vectors.

**Architecture:** Pure value types in `ElisCore` (host-free, Linux-safe) that later milestones plug into the relay
(`elisctlKit`, M4) and the phone (M4). No sockets, ptys or zmx here. The Dart side carries only what the phone needs:
encode, decode, typed payloads. A JSON vectors file is the contract between the two.

**Tech Stack:** Swift 6 (strict concurrency), swift-testing (`import Testing`); Dart 3.13 / Flutter test.

**Spec:** `docs/superpowers/specs/2026-11-18-phone-terminal-stream-design.md` (sections "Protocol model", "Attach model",
"Where the code goes", "Migration to the Elis restructure").

This plan covers M2 only. M1, M3, M4 and M5 get their own plans.

## Global Constraints

- Frame: `u8 kind | u32 channel | u32 len | payload`, big endian, `len` <= 65536 (64 KiB).
- Kinds and codes: OPEN=1, OPENED=2, DATA=3, CREDIT=4, RESIZE=5, GRID=6, RESYNC=7, LEAD=8, CLOSE=9.
- Fixed payloads: CREDIT = u32 bytes; RESIZE and GRID = u16 cols, u16 rows; RESYNC = empty.
- JSON payloads (OPEN, OPENED, LEAD, CLOSE): UTF-8 JSON objects, encoded with sorted keys and no optional nulls.
  OPEN `type` is a free string (`"vt"` today), so later channel types need no codec change.
- Channels: 0 = control, 1 = events, n >= 2 = opened channels. Priority control > events > opened.
- Opened-channel credit window: 16 KiB on Bluetooth, 256 KiB on TLS (the scheduler takes it as a parameter).
- Upgrade lines: phone sends `{"mux":1}` after the hello answer; relay answers `{"ok":true,"mux":1}`.
- New files only in `ElisCore`, plus one `exclude` line in `ElisCore/Package.swift`. Identifiers use `PhoneLink`,
  never the product name (Elis rename, spec "Migration").
- Phone code goes on an elis branch `feat/phone-link` cut from `main`. Never merge it into elis `main`
  (spec "Migration": the monorepo import does not run again).
- Gates for the Swift branch: `cd ElisCore && swift test`, `make lint` (200 columns, zero findings), `make test-app`.
- Static work only: never execute `elis`/`elisctl` against the default socket, never launch or quit the app.

## Review Focus

1. A frame split at any byte boundary, including one byte per feed, decodes to the same frames. Task 2.
2. A header that claims `len` > 65536 fails at once, before the decoder buffers the payload. Task 2.
3. An unknown kind byte, or a fixed payload of the wrong length, is an error, never a silent skip. Task 2.
4. CREDIT grants that add up past `UInt32.max` clamp and do not trap. Task 3.
5. An opened channel with no credit never delays a control or events frame, and an overflow is reported once and
   drops only that channel's queue. Task 3.

---

### Task 1: Frame type, encoder and golden vectors (Swift)

**Files:**
- Create: `ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkFrame.swift`
- Create: `ElisCore/Tests/ElisCoreTests/Fixtures/phone-link-vectors.json`
- Create: `ElisCore/Tests/ElisCoreTests/PhoneLinkFrameTests.swift`
- Modify: `ElisCore/Package.swift` (the `ElisCoreTests` test target gains `exclude: ["Fixtures"]`)

**Interfaces:**
- Produces:
  - `public enum PhoneLinkKind: UInt8, Sendable, CaseIterable { case open = 1, opened, data, credit, resize, grid, resync, lead, close }`
  - `public struct PhoneLinkFrame: Equatable, Sendable { public let kind: PhoneLinkKind; public let channel: UInt32; public let payload: Data }`
  - `public static let maxPayload = 65536`, `public static let headerSize = 9`
  - `public func encoded() -> Data`
  - Factories: `static func credit(channel: UInt32, bytes: UInt32) -> PhoneLinkFrame`,
    `static func grid(channel: UInt32, cols: UInt16, rows: UInt16)`, `static func resize(channel:cols:rows:)`,
    `static func resync(channel: UInt32)`, `static func data(channel: UInt32, _ bytes: Data)`
  - Vectors file schema (also read by Task 5):
    `{"frames":[{"name","kind","channel","payloadHex","hex"}], "streams":[{"name","hex","frames":[{"kind","channel","payloadHex"}]}], "errors":[{"name","hex","error"}], "json":[{"name","kind","channel","object","hex"}]}`
    where `kind` is the lower-case case name and `error` is one of `unknownKind`, `payloadTooLarge`, `badPayload`.

- [ ] **Step 1: Write the vectors file.** At least these `frames`: an empty DATA on channel 0; DATA `68690a` on
  channel 0; CREDIT 16384 on channel 2 (`04 00000002 00000004 00004000`); GRID 120x40 on channel 3; RESIZE 60x20 on
  channel 3; RESYNC on channel 2; a DATA on channel `4294967295`. `streams`: two frames back to back. `errors`: kind
  byte `0x00`, kind `0x0a`, `len` = 65537, CREDIT with a 3-byte payload, RESYNC with a 1-byte payload, GRID with
  5 bytes. Task 4 adds the `json` entries.
- [ ] **Step 2: Write the failing tests** in `PhoneLinkFrameTests.swift`: `encodesEveryVectorFrame` (for each
  `frames` entry, `PhoneLinkFrame(kind:channel:payload:).encoded()` equals `hex`), `factoriesMatchVectors`
  (`.credit(channel: 2, bytes: 16384).encoded()` equals the CREDIT vector; same for grid, resize, resync),
  `kindsHaveSpecCodes` (`PhoneLinkKind.allCases.map(\.rawValue) == Array(1...9)`). Load the file the way
  `ElisCore/Tests/elisctlKitTests/BleLinkTests.swift:30` does (`#filePath` + `Fixtures/`).
- [ ] **Step 3: Run** `cd ElisCore && swift test --filter PhoneLinkFrameTests`. Expected: FAIL, `PhoneLinkFrame` not found.
- [ ] **Step 4: Implement** `PhoneLinkFrame.swift` and the `exclude` line. Big-endian writes; `encoded()` does not
  validate (the decoder does).
- [ ] **Step 5: Run** the same command. Expected: PASS.
- [ ] **Step 6: Commit** `feat(phone-link): frame type, encoder and golden vectors`.

### Task 2: Streaming decoder (Swift)

**Files:**
- Create: `ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkDecoder.swift`
- Create: `ElisCore/Tests/ElisCoreTests/PhoneLinkDecoderTests.swift`

**Interfaces:**
- Consumes: `PhoneLinkFrame`, `PhoneLinkKind`, the vectors file (Task 1).
- Produces:
  - `public enum PhoneLinkError: Error, Equatable, Sendable { case unknownKind(UInt8), payloadTooLarge(UInt32), badPayload(PhoneLinkKind, Int) }`
  - `public struct PhoneLinkDecoder: Sendable { public init(); public mutating func feed(_ bytes: Data) throws(PhoneLinkError) -> [PhoneLinkFrame] }`
  - After a throw the decoder is spent: every later `feed` throws the same error (the relay closes the link).

- [ ] **Step 1: Write the failing tests:** `decodesEveryVectorFrame` (feed `hex` whole, get exactly that frame);
  `decodesStreamsAtEveryChunkSize` (for each `streams` entry and chunk sizes 1, 2, 3, 7, 9, 10 and whole: the
  concatenated results equal `frames`); `rejectsErrorVectors` (each `errors` entry throws the named case);
  `rejectsOversizeBeforePayload` (feed only the 9-byte header with `len` = 65537: throws `payloadTooLarge(65537)`
  on that call); `staysFailedAfterError`.
- [ ] **Step 2: Run** `swift test --filter PhoneLinkDecoderTests`. Expected: FAIL, type not found.
- [ ] **Step 3: Implement** the decoder: keep a `Data` buffer; check the kind and `len` as soon as the header is
  complete; check fixed payload lengths (CREDIT 4, RESIZE 4, GRID 4, RESYNC 0) when the payload is complete.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `feat(phone-link): streaming decoder`.

### Task 3: Credit windows and send scheduler (Swift)

**Files:**
- Create: `ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkScheduler.swift`
- Create: `ElisCore/Tests/ElisCoreTests/PhoneLinkSchedulerTests.swift`

**Interfaces:**
- Consumes: `PhoneLinkFrame.data(channel:_:)` (Task 1).
- Produces:
  - `public struct PhoneLinkScheduler: Sendable`
  - `public init(window: UInt32, bufferLimit: Int)`: the initial credit of every opened channel (n >= 2), and its
    queue cap (spec default 512 KiB).
  - `public enum Enqueue: Equatable, Sendable { case queued, overflowed }`
  - `public mutating func enqueue(channel: UInt32, _ bytes: Data) -> Enqueue`: channels 0 and 1 are never capped and
    need no credit. On an opened channel, a queue that would pass `bufferLimit` is emptied and the call returns
    `.overflowed` (the relay then restarts the attach and sends RESYNC, M4).
  - `public mutating func grant(channel: UInt32, bytes: UInt32)`: adds credit, clamped at `UInt32.max`.
  - `public mutating func close(channel: UInt32)`: drops the queue and the credit.
  - `public mutating func next(maxChunk: Int) -> PhoneLinkFrame?`: the next DATA frame. Order: channel 0, then 1,
    then opened channels round robin. An opened-channel chunk is at most
    `min(maxChunk, credit, PhoneLinkFrame.maxPayload)` and spends that credit. Never returns an empty DATA.
  - `public var pendingBytes: Int { get }`

- [ ] **Step 1: Write the failing tests:** `controlBeforeEventsBeforeOpened`; `noCreditDoesNotBlockControl`
  (channel 2 queued with zero credit, then control: `next` returns the control frame, then nil);
  `chunkLimitedByCredit` (window 10, enqueue 25 bytes: a frame of 10, then nil; `grant(10)`: 10; `grant(10)`: 5);
  `openedChannelsRoundRobin` (channels 2 and 3 alternate); `overflowDropsOnlyThatChannel` (limit 8, enqueue 9 on
  channel 2: `.overflowed`, channel 2 empty, channel 3 and control untouched); `grantClampsAtMax` (grant
  `UInt32.max` twice, no trap, then a 70000-byte queue yields a 65536-byte chunk); `closeDropsQueue`.
- [ ] **Step 2: Run** `swift test --filter PhoneLinkSchedulerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** A channel first seen in `enqueue` starts at `window`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(phone-link): credit windows and send scheduler`.

### Task 4: Typed JSON payloads and upgrade lines (Swift)

**Files:**
- Create: `ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkMessages.swift`
- Create: `ElisCore/Tests/ElisCoreTests/PhoneLinkMessagesTests.swift`
- Modify: `ElisCore/Tests/ElisCoreTests/Fixtures/phone-link-vectors.json` (add `json` entries)

**Interfaces:**
- Consumes: `PhoneLinkFrame`, `PhoneLinkKind` (Task 1).
- Produces (all `Codable, Equatable, Sendable`):
  - `public struct PhoneLinkOpen { type: String; target: String; pane: String?; claim: Bool?; cols: UInt16?; rows: UInt16? }`
  - `public struct PhoneLinkOpened { cols: UInt16?; rows: UInt16?; error: String? }`
  - `public struct PhoneLinkLead { role: String }`
  - `public struct PhoneLinkClose { reason: String }`
  - `public extension PhoneLinkFrame { static func json<T: Encodable>(_ kind: PhoneLinkKind, channel: UInt32, _ value: T) -> PhoneLinkFrame; func decodeJSON<T: Decodable>(_ type: T.Type) throws -> T }`
    (encoder uses `.sortedKeys`; nil optionals are omitted).
  - `public enum PhoneLinkUpgrade { static let request: Data; static let answer: Data; static func isRequest(_ line: Data) -> Bool }`
    with `request` = `{"mux":1}\n` and `answer` = `{"ok":true,"mux":1}\n`. `isRequest` parses JSON, so whitespace
    and key order do not matter; a line without `mux == 1` is false.

- [ ] **Step 1: Add `json` vectors:** OPEN `{"target":"s1","type":"vt"}` on channel 2; OPEN with `pane`, `claim`,
  `cols`, `rows` on channel 3; OPEN with `type` `"page"` (proves an unknown type still decodes); OPENED
  `{"cols":120,"rows":40}`; OPENED `{"error":"not a Live pane"}`; LEAD `{"role":"follower"}`; CLOSE
  `{"reason":"overflow"}`. Each with the exact `hex` of the sorted-key encoding.
- [ ] **Step 2: Write the failing tests:** `encodesJsonVectors` (`.json(kind, channel:, value).encoded()` equals `hex`);
  `decodesJsonVectors` (round trip equals `object`); `upgradeLines` (`isRequest` true for the request, for
  `{ "mux" : 1 }` and for the request without its newline; false for `{"mux":2}`, `{"auth":"x"}` and non-JSON).
- [ ] **Step 3: Run** `swift test --filter PhoneLinkMessagesTests`. Expected: FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run** `swift test --filter PhoneLink`. Expected: all four suites PASS.
- [ ] **Step 6: Commit** `feat(phone-link): typed payloads and upgrade lines`.

### Task 5: Dart codec on the phone, pinned by the same vectors

**Repository:** `/Users/n.savchenko/IdeaProjects/elis`, branch `feat/phone-link` from `main`.

**Files:**
- Create: `mobile/lib/link/frame.dart`, `mobile/lib/link/decoder.dart`, `mobile/lib/link/messages.dart`
- Create: `mobile/test/fixtures/phone-link-vectors.json` (byte-identical copy of the Swift file)
- Create: `mobile/test/link_test.dart`

**Interfaces:**
- Consumes: the vectors schema (Tasks 1 and 4).
- Produces (Dart names mirror the Swift ones):
  - `enum LinkKind { open, opened, data, credit, resize, grid, resync, lead, close }` with `code` 1...9
  - `class LinkFrame { final LinkKind kind; final int channel; final Uint8List payload; Uint8List encode(); }` with
    factories `LinkFrame.credit(int channel, int bytes)`, `.resize(int channel, int cols, int rows)`,
    `.data(int channel, List<int> bytes)`, `.json(LinkKind kind, int channel, Map<String, Object> object)`
  - `class LinkDecoder { List<LinkFrame> feed(List<int> bytes); }` throwing `LinkError(String code, int value)` with
    `code` in `unknownKind | payloadTooLarge | badPayload`; spent after a throw, as in Task 2.
  - `const linkUpgradeRequest = '{"mux":1}\n';` and `bool isLinkUpgradeAnswer(String line)`.
  - `LinkFrame.json` sorts keys, so it matches the Swift `hex`.

- [ ] **Step 1: Copy the vectors file** from the Swift branch; `cmp` shows no difference.
- [ ] **Step 2: Write the failing tests** in `link_test.dart`, mirroring Tasks 1, 2 and 4: every `frames` and `json`
  entry encodes to `hex` and decodes back; every `streams` entry decodes at chunk sizes 1, 2, 3, 7, 9, 10 and whole;
  every `errors` entry throws its code; a lone 9-byte header with `len` = 65537 throws `payloadTooLarge` on that
  feed. Load the file as `mobile/test/ble_link_test.dart:17` does.
- [ ] **Step 3: Run** `cd mobile && flutter test test/link_test.dart`. Expected: FAIL, imports missing.
- [ ] **Step 4: Implement** the three files with `ByteData` big-endian access.
- [ ] **Step 5: Run** `flutter test test/link_test.dart`, then `flutter analyze`. Expected: PASS, no issues.
- [ ] **Step 6: Commit** on `feat/phone-link`: `feat(mobile): phone link v2 codec`. Do not merge, do not push to `main`.

### Task 6: Contract note and gates

**Files:**
- Modify: `.claude/rules/control-api.md` (one bullet next to the `mobile serve` notes, around line 241)

- [ ] **Step 1:** Add one line: the phone link v2 frame contract lives in `ElisCore/Sources/ElisCore/PhoneLink/`,
  and the vectors file has a byte-identical copy in the phone app that changes together with it.
- [ ] **Step 2: Run the gates once:** `cd ElisCore && swift test` (all PASS), `make lint` (zero findings),
  `make test-app` (PASS). Then run `lsappinfo list | grep -A4 elis.debug` and stop only leaked test processes.
- [ ] **Step 3: Commit** `docs: phone link contract note`.
