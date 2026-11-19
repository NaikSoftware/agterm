# Phone session screen: lead on open, hidden composer

Short design, approved by the owner on 2026-11-19.

## Why

Direct typing on the terminal works now. The composer, the status word and the split action take space on a small
screen and add a step the owner no longer needs.

## What changes

1. **Status chip.** The session app bar shows only the status shape (`StatusShape`), no pill and no word.
   A screen reader still reads `statusLabel(status)`.
2. **Split action.** `Split side by side` / `Hide split pane` leaves the phone's actions sheet
   (`showSessionActions`), from the list's long press too. The Left pane / Right pane buttons stay.
3. **Composer.** Hidden by default. The key row (esc, tab, ^C, arrows, …) and prompt answer buttons stay.
   The actions sheet opened from a session screen gets `Show composer` / `Hide composer`.
   The choice is remembered across sessions and app restarts.
4. **Lead on open.** Opening a session on a Live pane claims its lead at once; switching to the other pane claims
   that pane. Leave, pause, pane switch and link loss release it, as today.
   After the Mac takes the lead back during a visit, the phone claims again only at its next input.
   A pane that is not Live has no lead and keeps today's behavior.
   This replaces "looking never claims": opening now resizes the Mac's program to the phone grid.

## Approaches

- **Chosen:** claim from the same place a pane's term channel becomes ready, through the existing `_claim()`.
- Rejected: claim at first paint of the screen — it runs before the channel opens, so the claim would be refused.
- Rejected: keep "first input claims" and only hide the composer — the owner asked for lead on open explicitly.

## Builder's calls

- Where the composer preference is stored (follow the app's existing settings storage).
- The status shape's size and tap target in the app bar.
- Docs to update: `site/docs.html` phone section and the bundled skill where they say looking never claims.
