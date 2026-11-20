# Camera photo into the session

Date: 2026-11-20. Status: draft; open questions below need the owner before planning.
Builds on `2026-11-20-phone-pages-design.md` (part 3 there).

## Intent

The phone is an input, not only a screen.
A photo taken on the phone (a whiteboard, a bug on another device, a printed log) lands next to the session,
and its path is pasted at the cursor, so any program can use it; an agent reads the path.

## Goals

- A camera control in the phone's session view takes a photo or picks one from the gallery.
- The file is written on the host where the session runs: the Mac, another Mac, or an elis-server host.
- Its absolute path is pasted at the cursor through the session's normal paste path (bracketed paste when the program enabled it).
- Works over Wi-Fi and Bluetooth; over Bluetooth it is slow, and the phone shows upload progress.

## Non-goals

- Video, audio, or arbitrary file upload.
- Editing or annotating the photo on the phone.
- Sending the picture to an agent in any agent-specific format; the pasted path is the only contract.

## Design

- **Phone.** A camera button in the session view (placement follows the Chat-mode app bar layout).
  It opens the system camera or picker, downsizes to a configurable longest edge (default 2048 px, JPEG),
  shows a determinate progress strip during upload, and on success pastes nothing itself: the host pastes.
- **Wire.** A new mux OPEN type `upload` `{target, name, size, mime}`, data in 64 KiB frames under CREDIT,
  in the low scheduler class (one frame in nine under steady vt, like `present` and `forward`).
  A size over the cap is refused at OPEN.
- **Relay.** Writes into `<stateDir>/uploads/<session-id>/<timestamp>-<name>` on the session's host:
  a local row directly; a remote row through `ssh -T <host> elisctl session upload --target <id>` reading stdin
  (the same transport the relay already uses for remote rows).
  After the last byte it runs `session.paste` (or the existing text input path) with the shell-quoted absolute path.
- **Control API.** `elisctl session upload --target <id> --name <file> < bytes` (the host side, also usable by scripts);
  read-back `uploads[]` on `ControlSessionNode` (path, size, time) so a script or agent can find the last photo.
- **Clearing.** The uploads folder of a session is removed when the session is deleted;
  files older than 7 days are pruned at app launch.

## Known limits

- The system camera sends the phone app to the background, so the claim closes and an open page moves to the Mac and back
  (phone pages follow the lead). No grace period unless the owner asks for one.
- A photo pasted into a program that does not expect a path is just text.

## Open for the owner

1. Default longest edge and JPEG quality, and the size cap (proposal: 2048 px, q 0.85, 20 MiB).
2. Paste the path at the cursor, or also notify the session (`notify`) so an idle agent sees it.
3. Retention: delete with the session and after 7 days, or keep until the user clears them.

## Remote path

A remote row (another Mac, elis-server) writes the file on that host and pastes there; the phone never needs
to know which host it is. The elis-server side needs `session upload` in its command policy.

## Tests (for the plan)

- Relay: OPEN `upload` refused over the cap; bytes land at the expected path; paste carries the quoted path;
  a remote row runs the ssh argv; link loss mid-upload leaves no partial file.
- Phone: progress strip; cancel; refusal shown.
- Control: `uploads[]` read-back; pruning.
