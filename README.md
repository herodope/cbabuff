# CBA Buff

Paladin blessing management for World of Warcraft: The Burning Crusade Anniversary Edition.

CBA Buff computes who casts which blessing, keeps every client's copy in sync, tracks who
actually has what buffed, and alerts on gaps — without hooking, injecting into, or reading
memory from the game process. It replaces PallyPower.

- **Client:** TBC Anniversary Edition, 2.5.6 (Interface `20506`)
- **Folder / TOC:** `CBABuff` / `CBABuff_TBC.toc`
- **Slash commands:** `/cbab`, `/cbabuff`

## Who needs this installed

Only **paladins** and the **raid coordinator** (leader, or an assist doing the assigning). Buff
state is read locally off the raid roster (`UnitAura` on `raid1`..`raid25`), so anyone else's
client can see whether a buff landed without needing the addon themselves — there's no reason
for a non-paladin, non-coordinator raider to install it. Their not having it is never an error
or a warning anywhere in the addon.

## How it works, briefly

1. **Capability** — each paladin's client scans their own talents (both dual-spec groups) and
   broadcasts it to the guild and raid. Leaders get this data hours before invites go out.
2. **Solve** — the coordinator runs `/cbab solve` (or the Editor's Solve button) out of combat.
   It's deterministic: slot construction (who covers what, in priority order: Salvation, Kings,
   Might/Wisdom, Light) followed by list walks for tank and pet overrides — not an optimizer,
   and there's no auto-solve.
3. **Push** — the coordinator pushes the result to the raid. Every client saves it immediately;
   it survives reload, disconnect, and zoning with no re-push needed. If two people push around
   the same time, every client resolves the same winner without a round trip.
4. **Track** — each client watches its own raid's buffs (spell ID only, never by name/rank) and
   flags anyone missing what they're supposed to have.
5. **Bar / Alert** — the paladin bar casts your assignments; the alert window tells you (or
   whoever's responsible) when something's wrong.

Paladin talents matter for *who* fills a slot, never for *which* slots exist — a paladin with an
unusual build is just a capability record, and the addon never suggests a respec.

## Commands

```
/cbab                       toggle the assignment editor
/cbab version                print the addon version and your current mode
/cbab roster                 open the roster page (splits, tank flags, export/import)
/cbab config                 open the config page (warnings, bar/alert, pets, debug)
/cbab solve                  run the solver (coordinator, out of combat only)
/cbab push                   push the current assignment to the raid (coordinator)
/cbab check                  list paladins who haven't responded to a presence check
/cbab debug on|off|verbose   toggle the debug log (verbose also echoes it to chat)
/cbab dump <topic>           print diagnostic info -- see topics below
/cbab sim <fixture>           run the solver against a named test fixture, no group needed
/cbab sim all                 run every test fixture and report pass/fail
/cbab perf                   aura-tracking counters: events seen, coalesced, flush timing
/cbab epoch                  show the assignment epoch, yours and every client you've heard from
```

`/cbabuff` works identically to `/cbab` everywhere above.

**Dump topics:** `spells` (blessing data), `roster` (live raid roster + class counts),
`assign` (current assignment), `cache` (capability cache), `talents` (your own talents, both
specs), `comm` (comm epoch table), `log` (opens the scrollable debug log window).

You can do everything above from the UI too — the editor, roster page, and config page don't
require chat commands. Left-clicking (not dragging) the small handle on the paladin bar also
toggles the editor.

## The paladin bar

The bar's class buttons and the seal/Righteous Fury button are deliberately named
`PallyPowerC1`–`PallyPowerC9` and `PallyPowerRF`, so **existing PallyPower macros work
unmodified**:

```
/click PallyPowerC1 LeftButton Down     -- greater blessing on class button 1
/click PallyPowerC1 RightButton Down    -- normal blessing on your current target
/click PallyPowerRF LeftButton Down     -- Righteous Fury
```

Button numbering isn't fixed to a class — like PallyPower, `C1` is whichever class (in the
fixed order Warrior, Rogue, Priest, Druid, Paladin, Hunter, Mage, Warlock, Shaman) is actually
present in the raid first. Class buttons are blocked in combat; hovering a class button pops out
individual player buttons for single-target casts, which work in combat. Shift-click forces a
refresh. **This is the only place the PallyPower name appears** — everything else says CBA Buff.
Both addons loaded at once will fight over those button names; CBA Buff warns you once if it
detects PallyPower is also loaded.

The Righteous Fury button's right-click (seal) is not wired up yet — there's no way for the
addon to know which seal you want without a settings UI that doesn't exist yet.

## Splits and profiles

A "split" is a named profile holding a 25-slot roster of character names, want-lists, and the
current assignment. Profiles are account-wide (all your alts see all your splits). Class and
spec fields on the roster page are optional, cosmetic planning hints only — live raid data
always overrides them, and the solver never reads spec as anything but a tiebreak. On raid
formation the addon scores your saved splits by name overlap with who's actually there.

Export a profile to a copy-paste string from the roster page and import it on another
character/account — it round-trips the full roster, want-lists, tank flags, and assignment.

## Hunter pets

On by default. This is a **profile setting**, not a personal one — turning it off changes what
every paladin in the raid gets told to cast, since it's part of what gets solved and pushed.
It's in the config page, marked clearly as raid-wide for that reason.

## Warnings

Three independent layers, all in the config page:

1. **Local text + sound** for your own assignments — on by default.
2. **Whisper the responsible paladin** — off by default; a coordinator can enable it. Throttled
   to one whisper per paladin per 60 seconds, and never sent in combat.
3. **Raid warning post** — a manual button in the alert window, officer-only. Never automatic;
   automatic raid-channel spam is deliberately not implemented anywhere in this addon.

## Contributing / building

Libraries (`LibStub`, `LibSerialize`, `LibDeflate`) are pulled in by the packager per
`.pkgmeta` and are never committed — clone the repo and run the
[BigWigs packager](https://github.com/BigWigsMods/packager) locally to get a loadable copy, or
just push a tag and let `.github/workflows/release.yml` build one for you.
