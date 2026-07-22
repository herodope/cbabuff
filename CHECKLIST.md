# Post-install verification checklist

Nothing in this addon has been run against a live client — every file was written and
cross-checked by re-reading, with no Lua interpreter available during development. This is the
list of everything worth checking, in the order that makes sense to check it, from "does it
load at all" up to the riskiest, least-verified pieces. Items marked **HIGH RISK** are places I
could not verify an assumption and a failure there is silent (no error, just wrong data) rather
than a crash — check those first and don't trust anything downstream of them until they pass.

## 1. Does it load

- `/reload` with only CBA Buff enabled. Check for Lua errors (enable Lua error display via
  `/console scriptErrors 1` if you don't have BugSack/BugGrabber).
- `/cbab version` should print a version string and your current mode (`coordinator`,
  `paladin`, `coordinator+paladin`, or `passive`). Confirm the mode matches reality — a paladin
  should show `paladin`; the raid leader or an assist should show `coordinator`.
- Bare `/cbab` should open the assignment editor window, not print text (this is the one place
  behavior changed from early testing — it used to print the version).

## 2. Data sanity

- `/cbab dump spells` — six blessings, each with non-empty `normal={...}` and `greater={...}` ID
  lists, a texture path, and the right `talentGated` (true only for kings and sanctuary).
- **HIGH RISK — verify these specific spell IDs** with `/dump GetSpellInfo(id)` for each: `27140`
  (Might rank 8), `27141`–`27143` (the Might/Wisdom greater-rank cluster), `27144` (Light rank
  4), `27145` (Greater Light rank 2), `27168` (Sanctuary rank 5). These were sourced from
  PallyPower's own data file and cross-checked against Wowhead, but never confirmed in-game. If
  any come back nil or wrong, blessing detection for that rank will silently miss it.

## 3. Capability scanning — HIGH RISK, check this before trusting anything solver-related

This is the single riskiest unverified piece in the addon. Update: first-install testing already
caught two real bugs here and both are fixed —
1. `GetTalentTabInfo` on this client returns `(id, name, "", icon, pointsSpent, background,
   ...)`, not the legacy `(name, icon, pointsSpent, ...)` order the code was originally written
   against (confirmed via `/dump GetTalentTabInfo(1, false, false, 1)` against a live client).
   `GetTalentInfo`'s order checked out correct as written.
2. `GetTalentInfo`'s icon return is a numeric FileDataID on this client, not the string icon
   path `Data/Spells.lua` stores — so the texture-equality match spec 6.1 describes (an improved
   talent shares its icon with the base blessing) never matched, silently reading Kings and
   Sanctuary as always-false regardless of actual points spent (caught when a paladin with both
   talents in group 2 still showed `kings=false sanctuary=false`). Fixed by resolving each
   blessing's reference icon at runtime through the same spell-icon lookup, so both sides of the
   comparison use whatever representation this client actually returns.

**Update: the dual-spec group argument is now confirmed working**, tested live on a
retribution/protection paladin (group 1 = retribution: `kings=true sanctuary=false`; group 2 =
protection: `kings=true sanctuary=true`). Both groups kept their own distinct, correct values
across a live spec swap — group 2 still read `sanctuary=true` even while retribution (group 1)
was the active spec, which is exactly the signal that would have been wrong (both groups
collapsing to whichever is active) if the 5th `group` argument were silently ignored. `*` also
correctly followed the swap. This was the single highest-risk unverified assumption in the whole
addon and it's now actually confirmed, not just hoped for.

`impMight`/`impWisdom` weren't independently confirmed (no invested points to test against at
the time), but they run through the identical `rankOf()` code path Kings/Sanctuary just got fixed
in and verified against — there's no reason to expect a different result, though a real
confirmation once someone has points in either Improved talent would close this out fully.

- Remaining: confirm `impMight`/`impWisdom` on a paladin who actually has points in either
  Improved talent, in either dual-spec group.

## 4. Roster

- In any group, `/cbab dump roster` — everyone listed with correct class, tank flags matching
  raid target icons (main tank/assist) or manually-flagged tanks from the active profile, and a
  correct per-class count at the bottom.
- If you run a hunter with a pet out and the active profile has pets enabled, confirm the pet
  shows up in the dump with the right owner. Disable pets in the config page and confirm the pet
  disappears from the dump on the next roster update.

## 5. Solver — test offline first, no group needed

- `/cbab sim all` solo, no group. Every fixture should report `pass`. Two of them (`1_paladin`,
  `3_paladins`) are checked against an exact hand-verified snapshot; the rest just check "no
  validation errors," which is a weaker guarantee — if you want to sanity-check a specific one
  in detail, `/cbab sim <fixture-name>` prints the full assignment and validator output.
- **Spec disagreement worth knowing about, not necessarily a bug**: for a 1-paladin comp lacking
  the Kings talent, the spec's own summary table (5.3) suggests the tank override falls back to
  Light. This implementation follows the more precise mechanical rules in 5.5 instead, which
  land on Might or Wisdom depending on tank class — verified against 5.5's own worked examples,
  but it's a real disagreement between two parts of the spec, not a bug I fixed quietly. If
  `/cbab sim 1_paladin_no_kings` doesn't match what you expect, this is why.
- With a real roster and an active profile, `/cbab solve` out of combat. Read the chat summary:
  greaters per paladin, overrides with reasons, error/warning counts. Then open the editor
  (bare `/cbab`) and confirm it shows the same thing.
- Walk into combat and try `/cbab solve` again — it must refuse with a clear message, not
  silently do nothing or error.

## 6. Comm — needs two clients

- With two accounts/characters in the same group, `/reload` both. `/cbab epoch` on each should
  eventually agree once they've exchanged `HELLO`s.
- Push from the coordinator's client (`/cbab push` or the editor's Push button). Confirm it
  appears on the other client within a few seconds, and that client's chat shows "received
  assignment push from...".
- `/reload` **both** clients. The pushed assignment must survive on both without needing another
  push — this is the core acceptance test for the whole sync system.
- Push repeatedly in quick succession from one client — nothing should disconnect, error, or
  spam excessively; the send queue caps at 8 messages/sec and 4 per 250ms.
- `/cbab check` should list only paladins, never non-paladins, and should clear paladins who
  responded within a few seconds.

## 7. Buff tracking / performance

- `/cbab perf` — note which aura API branch it reports (`C_UnitAuras (modern)` or `UnitAura
  (legacy)`). Either is fine; just confirm it says something and isn't erroring.
- During actual raid trash (lots of aura churn from procs/debuffs you don't track), check
  `/cbab perf` again — you want a high ratio of "events coalesced away" to "events received,"
  and "last flush" well under a millisecond. If flushes are consistently multi-millisecond or
  the coalesce ratio is near zero, something's marking units dirty too aggressively.
- Drop a blessing (let it fall off, or have someone cancel it) — the alert window should appear
  within about a quarter second. Rebuff — it should disappear after a few seconds of clean
  state, not instantly (that delay is intentional, to avoid flicker on a one-flush blip).

## 8. Paladin bar (pbar grid) — macro compatibility, HIGH RISK for anyone with existing PallyPower macros

The bar was rewritten from a single class-button row into a paladin-rows × class-columns grid
(SPEC.md 11.2, amended). Row 1 is still the old single row under the hood — it's the only place
the `PallyPowerC1`–`PallyPowerC9`/`PallyPowerRF` compat names live — so everything below that's
unchanged from the original design still needs checking exactly as before, plus the new grid
items after it.

**Unchanged (still row 1 / toolbar):**
- Have a raider with an old PallyPower macro run it unmodified against your raid. `C1`–`C9`
  aren't fixed to specific classes — like PallyPower, they're compacted to whichever classes are
  actually present, in the fixed order Warrior/Rogue/Priest/Druid/Paladin/Hunter/Mage/Warlock/
  Shaman. Confirm the macro casts the blessing you expect for your current comp.
- `/click PallyPowerRF LeftButton Down` should cast Righteous Fury. **Right-click on RF does
  nothing right now** — there's no seal selection UI yet; this is a known gap, not something to
  troubleshoot.
- Click a class button in combat — it should silently do nothing (no taint error in
  `/console scriptErrors 1` output). Out of combat it should cast normally.
- Hover a row-1 class button — individual player buttons should pop out below it; clicking one
  should cast on that specific person, including while in combat. This popout is row-1-only by
  design; other rows don't have it (see below).
- Shift-click a class button and confirm the border color updates immediately rather than
  waiting for the next natural buff-state refresh. Try this on a row-2+ cell too, not just row 1
  — the shift-refresh binding was a real bug during development (only wired to whatever rows
  existed at file-load time, i.e. row 1 alone) before being fixed to bind at cell-creation time.
- If you also have PallyPower installed, confirm the one-time collision popup appears exactly
  once (check `/reload` doesn't re-show it).

**New — grid structure, HIGH RISK (never run against a live client):**
- With 2+ paladins in the assignment (via `/cbab solve`, or Solve/Push from another client),
  confirm a row appears for each one, alphabetically after row 1 (which is always you). Confirm
  the row count updates live as paladins are added to/removed from the plan (ASSIGNMENT_CHANGED)
  and as the raid's class composition changes (ROSTER_CHANGED) — both should trigger a full
  re-layout, not just a visual refresh.
- Confirm a row-2+ cell's left-click actually casts the blessing shown in that cell, using YOUR
  own known rank — not a no-op, and not somehow casting as the other paladin (which is
  impossible and would indicate a serious bug if it appeared to happen). If you don't know that
  spell, the click should be a silent no-op, same as clicking a class button in combat.
- Toggle a row's **Manual** checkbox. Confirm a small edit overlay appears on that row's cells,
  clicking one opens a dropdown (Clear + blessing/Aura list), and picking an entry writes to
  the assignment and refreshes every client's ASSIGNMENT_CHANGED-driven UI (roster page, other
  paladins' bars). Confirm you can toggle Manual on your OWN row regardless of leader status, but
  **cannot** toggle it on someone else's row unless you're the leader/an assist — the checkbox
  should be disabled (not just inert) in that case.
- Confirm the green check overlay reflects FULL class coverage (every live member of that class
  holding the blessing), not just the single representative unit the secure attribute targets —
  the easiest way to check this is a class with 2+ members where only one currently holds the
  buff; the checkmark should be absent until all of them do.
- Toggle "Show pets in pbar" (roster page or Config) and confirm the Pets column appears/
  disappears across every row immediately, and that only the paladin actually holding pet
  overrides (normally the salv carrier) has a populated Pets cell — every other row's Pets cell
  should render as empty/neutral, not an error.
- Click **Solve** in the toolbar out of combat and confirm it matches `/cbab solve`'s result
  exactly (same code path, `CBAB.Solve:RunLive`) — try it while pbar debug mode is on and confirm
  it refuses with a clear message instead of solving against the synthetic roster.
- Click **Sync** and confirm it behaves identically to whatever `/cbab check`'s underlying HELLO
  broadcast does — `CBAB.Comm:EpochTable()` should populate/update within a few seconds.
- Click **Report** as the leader/an assist — confirm one raid-chat line per paladin appears,
  under 255 characters each. Click it as a non-coordinator and confirm it refuses with a chat
  message instead of silently doing nothing or erroring.
- Confirm the sync indicator next to each paladin's name (`Y`/`N`/`?`) tracks `CBAB.Comm
  :EpochTable()` sensibly: `?` for a paladin who's never sent anything, `N` (red) for one whose
  known epoch is behind yours, `Y` (green) once they've caught up. Your own row should always
  read "(you)", never a sync status.
- Resize/reposition sanity: with 4+ paladin rows and every column shown (Pets + Aura + several
  classes), confirm the window grows to fit without clipping the Manual checkbox off the right
  edge, and that a comp with only 1-2 classes populated doesn't push the Manual checkbox/label
  into negative x (off the left edge) — this was a real layout bug during development, fixed by
  reserving a fixed-width Manual column rather than sizing it off the (possibly tiny) grid width.

## 9. Auras (pbar's Aura column/cell, roster page's Aura dropdown) — HIGH RISK, unverified spell IDs

Auras are new in this pass (SPEC.md 2, amended into v1 scope as **manual-only**) — no solver
involvement, so the only things to actually verify are the data (spell IDs) and the display.

- **HIGH RISK — verify these against a live client** with `/dump GetSpellInfo(id)`, the same way
  Data/Spells.lua's ranks were checked: every ID in `Data/Auras.lua`'s `devotion`, `retribution`,
  `concentration`, and `sanctity` rank lists. These were never confirmed in-game (no interpreter
  or live client available during development, same caveat as the rest of this file) — if any
  come back nil or wrong, that Aura will silently never read as "active," exactly like a wrong
  blessing rank would.
- Pick an Aura for a paladin on the roster page's Aura dropdown, confirm the pbar's Aura cell
  for that paladin's row shows the right icon after the next Solve (plan)/ASSIGNMENT_CHANGED.
- Actually cast that Aura on the assigned paladin's own character and confirm the cell's green
  check appears and the border goes green — Auras have no fixed duration (unlike blessings),
  so confirm the cell does NOT show a cooldown swipe/countdown, just a steady "active" state.
  Cancel/swap the Aura and confirm the cell goes back to missing (red) promptly.
- Confirm `Data/Auras.lua`'s spell IDs were correctly folded into `CBAB.WatchedSpellIDs` — easiest
  check is `/cbab dump spells` still lists only blessings (Auras aren't in that dump), but
  `/cbab perf`'s aura-event counters should still tick up when an Aura is cast/swapped, same as a
  blessing would, confirming Track.lua is actually watching for it.

## 10. Alert window and warnings

- Confirm the window has no visible background/frame at all when there are zero problems, not
  just an empty box.
- Enable the whisper warning layer as the coordinator, and confirm it only fires at most once
  per paladin per 60 seconds, and never while you're in combat.
- Confirm the raid-warning "Post" button only appears for the leader/an assist, and never fires
  on its own — it must never make a sound or post anything without you clicking it.

**New — chrome (title/lock/close/resize), HIGH RISK (never run against a live client):**
- Config's "Show alert now (preview)" button should force the window visible (with a "No active
  alerts (preview)" placeholder line) even with zero problems and even if auto-hide is on; click
  it again ("Hide preview") and confirm it disappears immediately if there's still nothing wrong.
- Config's "Locked" checkbox and the alert window's own Lock/Unlock title-bar button both write
  the same `ui.alert.locked` field — toggling either one should update the OTHER'S label/behavior
  the next time that widget is shown or clicked (they don't push live to an already-open Config
  page the way the checkbox pushes to an already-open alert window, matching the bar's existing
  Lock/Config asymmetry — not a bug if the alert window's button doesn't relabel the still-open
  Config checkbox, it doesn't for the bar either).
- While unlocked, drag the title bar and confirm the window moves and the new position survives
  `/reload`. While locked, confirm dragging the title bar does nothing.
- While unlocked, drag the bottom-right resize grip and confirm the window (and every row's text)
  widens/narrows live, without waiting for the next alert refresh, and that the width survives
  `/reload`. While locked, confirm the grip is hidden entirely.
- Click the X — confirm it hides the window immediately and cancels an active preview, but a real
  still-unresolved problem should bring the window back on the next buff/roster event (this is
  intentional: X is a dismiss, not a permanent "hide the alert forever" toggle like the bar's
  close button).

**New — group-size-aware row collapsing (rule 1: only one blessing can ever be active on a unit
at once), HIGH RISK, the riskiest logic change in this pass, never run against a live client:**
- Reproduce the original bug report: solve/plan an assignment sized for more paladins than are
  actually in your live group (e.g. a 3-paladin plan with only one paladin present), and confirm
  the alert window shows exactly ONE row for that paladin, not one per class-wide greater/
  override that happens to apply to them.
- Confirm the ONE row shown is the highest-priority one that's actually castable right now — for
  a tank, that means the class's tank want-list order (or their roster-page override list if they
  have one); for a hunter pet, `wants.pet`'s order; for anyone else, the spec 4 importance order
  (Salvation > Kings > Light > Might > Wisdom). If a candidate is talent-gated (Kings, Sanctuary)
  and nobody live actually has that talent, confirm it's skipped in favor of the next-best
  candidate instead of being suggested anyway.
- Cast the suggested blessing on that unit and confirm the row disappears — and stays gone (no
  other candidate row reappears demanding a *different* one of the several originally assigned),
  since holding any one of them satisfies the single aura slot. Let it run down past the warning
  threshold and confirm it comes back as "expiring" for that SAME blessing, not a different one.
- Sanity-check the common case is unaffected: a normal multi-paladin raid where each unit really
  only has one thing assigned should look and behave exactly as before this change.

## 11. Packaging (the one thing that's mechanically checkable without a live client)

- Push a version tag (e.g. `v0.1.0`) and confirm the GitHub Action produces a Release with a
  zip attached.
- Download that zip fresh, install it into a clean WoW AddOns folder, and confirm it loads with
  no errors — this is the actual acceptance test for the release pipeline, and doesn't require
  any of the manual troubleshooting above to already be resolved first.

## Known, already-disclosed gaps (not bugs to chase)

- Auras have no solver: there is no auto-assignment, no capability gate (even Sanctity Aura's
  talent requirement, recorded in `Data/Auras.lua`, isn't read anywhere yet), and no duplicate-
  type warning if two paladins are manually assigned the same Aura. This is deliberate v1 scope
  (SPEC.md 2), not an oversight.
- The pbar grid (UI/Bar.lua) is a from-scratch rewrite that, like the rest of this addon, has
  never been run against a live client or a Lua interpreter — treat every item in section 8 as
  genuinely unverified, not a formality.
- RF's right-click (seal) is unimplemented — no config UI exists yet to pick a seal.
- There is no want-list editing UI anywhere; the "tank conflict" marker in the editor opens a
  chat summary, not a real editor.
- Non-paladin spec detection was never built — the solver's Might-vs-Wisdom "which is more
  valuable" headcount only accounts for Shaman/Druid/Paladin members if the roster page has a
  manual spec hint typed in for them.
- Most files still have hardcoded English strings rather than routing through
  `locale/enUS.lua` — Core.lua and Debug.lua are fully converted; the rest are not.
