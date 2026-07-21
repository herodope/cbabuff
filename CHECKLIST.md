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
caught one real bug here and it's fixed — `GetTalentTabInfo` on this client returns
`(id, name, "", icon, pointsSpent, background, ...)`, not the legacy `(name, icon, pointsSpent,
...)` order the code was originally written against (confirmed via `/dump GetTalentTabInfo(1,
false, false, 1)` against a live client). `GetTalentInfo`'s order checked out correct as written.

What's still unverified: spec 6.1 requires reading talent data for **both** dual-spec groups via
a 5th argument to `GetTalentInfo`/`GetTalentTabInfo`. The `/dump` tests so far only used group
`1` — they confirmed the *return value order*, not that passing group `2` actually reads the
*inactive* spec rather than silently re-reading the active one. If that argument doesn't do what
spec 6.1 claims, **nothing errors** — it's just ignored, and both groups silently read identical
data. This is the part of section 3 below that still needs a real dual-spec test.

- On a paladin with dual spec set up differently in each group, run `/cbab dump talents`.
- Confirm both groups show, with a `*` marking the currently active one.
- Confirm the **inactive** group's `kings`/`sanctuary`/`impMight`/`impWisdom` values match that
  spec, not your current one. This is the actual test — if both groups show identical numbers
  regardless of which is active, the group argument isn't working.
- Swap specs in-game (out of combat) and re-run `/cbab dump talents` — the `*` should follow,
  and the numbers for what's now your active group should update within a couple seconds
  (`SPELLS_CHANGED`/`ACTIVE_TALENT_GROUP_CHANGED` are debounced ~1.5s).

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

## 8. Paladin bar — macro compatibility, HIGH RISK for anyone with existing PallyPower macros

- Have a raider with an old PallyPower macro run it unmodified against your raid. `C1`–`C9`
  aren't fixed to specific classes — like PallyPower, they're compacted to whichever classes are
  actually present, in the fixed order Warrior/Rogue/Priest/Druid/Paladin/Hunter/Mage/Warlock/
  Shaman. Confirm the macro casts the blessing you expect for your current comp.
- `/click PallyPowerRF LeftButton Down` should cast Righteous Fury. **Right-click on RF does
  nothing right now** — there's no seal selection UI yet; this is a known gap, not something to
  troubleshoot.
- Click a class button in combat — it should silently do nothing (no taint error in
  `/console scriptErrors 1` output). Out of combat it should cast normally.
- Hover a class button — individual player buttons should pop out below it; clicking one should
  cast on that specific person, including while in combat.
- Shift-click a class button and confirm the border color updates immediately rather than
  waiting for the next natural buff-state refresh.
- If you also have PallyPower installed, confirm the one-time collision popup appears exactly
  once (check `/reload` doesn't re-show it).

## 9. Alert window and warnings

- Confirm the window has no visible background/frame at all when there are zero problems, not
  just an empty box.
- Enable the whisper warning layer as the coordinator, and confirm it only fires at most once
  per paladin per 60 seconds, and never while you're in combat.
- Confirm the raid-warning "Post" button only appears for the leader/an assist, and never fires
  on its own — it must never make a sound or post anything without you clicking it.

## 10. Packaging (the one thing that's mechanically checkable without a live client)

- Push a version tag (e.g. `v0.1.0`) and confirm the GitHub Action produces a Release with a
  zip attached.
- Download that zip fresh, install it into a clean WoW AddOns folder, and confirm it loads with
  no errors — this is the actual acceptance test for the release pipeline, and doesn't require
  any of the manual troubleshooting above to already be resolved first.

## Known, already-disclosed gaps (not bugs to chase)

- RF's right-click (seal) is unimplemented — no config UI exists yet to pick a seal.
- There is no want-list editing UI anywhere; the "tank conflict" marker in the editor opens a
  chat summary, not a real editor.
- Non-paladin spec detection was never built — the solver's Might-vs-Wisdom "which is more
  valuable" headcount only accounts for Shaman/Druid/Paladin members if the roster page has a
  manual spec hint typed in for them.
- Most files still have hardcoded English strings rather than routing through
  `locale/enUS.lua` — Core.lua and Debug.lua are fully converted; the rest are not.
