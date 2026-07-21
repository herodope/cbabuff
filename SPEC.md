# CBA Buff — Specification

Paladin blessing management addon for World of Warcraft: The Burning Crusade Anniversary Edition.

- **Display name:** CBA Buff
- **Folder / TOC:** `CBABuff`
- **Lua namespace:** `CBAB`
- **Slash commands:** `/cbab`, with `/cbabuff` as a long-form alias
- **Comm prefix:** `CBAB`

Note the deliberate exception: the paladin bar's secure buttons must remain named
`PallyPowerC1`..`PallyPowerC9` and `PallyPowerRF` so existing raider macros keep working
(section 11.2). That is the **only** place the PallyPower name survives. Everything visible to
the user — window titles, chat output, minimap tooltip, config headers — says CBA Buff.

This document is the authoritative spec. It is intended to be supplied as context to any
coding session working on this addon. If code and this document disagree, this document wins
until it is explicitly amended.

---

## 1. Target environment

| Item | Value |
|---|---|
| Client | TBC Anniversary Edition, 2.5.6 |
| Interface | `20506` (verify in-game: `/dump select(4, GetBuildInfo())`) |
| TOC filename | `CBABuff_TBC.toc` |
| Raid size | 25 (groups 1–5) |
| Lua | 5.1 (WoW dialect) |

Do **not** target Classic Era 1.15.x, Wrath, Cataclysm, or Retail. Do not use APIs introduced
after 2.5.6. A 1.15.9 client update is anticipated but is explicitly **out of scope** for v1.

**Dual spec exists in TBC Anniversary** and shipped at launch. A character with it unlocked
holds two talent groups and may swap between them **out of combat** with a short cast. Swapping
is blocked in combat and in PvP instances.

This means paladin capability is **volatile between pulls**, not a static property of a
character. A holy paladin can become protection between trash packs and gain Kings. The addon
must treat a spec swap as a first-class event, not an edge case. See section 6.4.

### Dependencies

Embedded via BigWigs packager, never committed to the repo:

- `LibStub`
- `LibSerialize`
- `LibDeflate`

No Ace3. No LibClassicDurations. No LibUIDropDownMenu.

---

## 2. Scope

### v1 — paladin blessings only

- Greater and normal blessing assignment
- Capability detection (talents, known spells)
- Tank overrides
- Hunter pet blessings (optional, on by default)
- Split/roster profiles with export/import
- Addon-to-addon sync with leader-authoritative push
- Buff state tracking and alerting
- Simulation/test harness

### Explicitly out of scope for v1

- Non-paladin buffs (Fortitude, Arcane Intellect, Gift of the Wild, totems) — v3
- Paladin auras, seals, Righteous Fury — v2
- Automatic Salvation self-cancelling — deferred, see section 5.7
- Reagent / Symbol of Kinship tracking — never
- Warlock pet blessings — never
- Requiring the addon on non-paladin raiders (see section 2.1)
- Raid frame overlay integration — v2 if wanted
- Auto-solve on roster change — manual solve only
- Per-boss profiles — profiles are per raid composition only
- Importing PallyPower SavedVariables

### 2.1 Who needs the addon

**Required:** the raid coordinator (leader or assist doing the assigning) and every paladin.
**Not required:** everyone else.

This is possible because buff state is read locally. `UnitAura` on `raid1`..`raid25` and
`raidpet1`..`raidpet25` is readable from any client regardless of what the target is running.
Only **capability** data (talents, known spells) must originate from the paladin's own client,
and only paladins have capability the solver cares about.

Two modes in v1, detected at login and re-evaluated on `GROUP_ROSTER_UPDATE`:

| Mode | Who | Gets |
|---|---|---|
| `coordinator` | Leader or assist | Editor, roster page, solve, push, full alert window |
| `paladin` | Any paladin | Bar, own assignment, alerts for own assignments, receives push |

A player can be both. Mode determines which UI loads and whether the client participates in
comms. **In v1 there is no reason for anyone else to install the addon** — a non-paladin,
non-coordinator client has no function.

`CBAB:Mode()` must nonetheless be written to accommodate a third `passive` mode without
restructuring. That mode returns when Salvation self-cancelling (5.7) or non-paladin buff
coverage (v3) ships, at which point ordinary raiders gain a reason to install. The comm layer
is addressed by mode rather than by assuming universal install, so lifting the restriction
later requires no redesign.

**Unwanted Salvation on tanks is handled entirely paladin-side.** The tank override (5.5) works
by having the salv carrier's normal blessing *replace his own* greater Salvation on that tank.
Nothing is required from the tank's client. Where a tank does hold stray Salvation from a
second paladin, the alert window surfaces it and recasting the override fixes it.

---

## 3. Game mechanics the solver depends on

These are hard game rules, not design choices.

1. A paladin may have **at most one blessing active per target** at any time. Different
   paladins may stack different blessings on the same target.
2. **Greater Blessing** lasts 30 minutes, is cast on one player, and applies to **all raid
   members of that player's class**. It does **not** apply to pets.
3. **Normal (single-target) Blessing** lasts 10 minutes and applies to one unit, including pets.
4. Casting a normal blessing on a target **replaces that same paladin's** greater blessing on
   that target. It does not affect other paladins' blessings, and does not affect other members
   of the class.
5. `Blessing of Kings` and `Blessing of Sanctuary` are **Protection talents**. A paladin
   without the talent cannot cast them at all.
6. `Improved Blessing of Might` is a **Retribution** talent. `Improved Blessing of Wisdom` is a
   **Holy** talent. Both are 2-point talents that increase the blessing's effect.
7. `Blessing of Light` and `Blessing of Salvation` are trainable, always available.

### Consequence: the salv carrier is the override carrier

The paladin assigned Salvation is the one whose greater blessing is worthless on tanks and pets.
His single-target slot on those units is therefore free by definition. All tank and pet overrides
are assigned to him. This is not a special case; it falls out of rule 4.

### Consequence: the paladin-class swap

A protection paladin wants Sanctuary on himself. If he casts Greater Kings on the Paladin class,
that includes himself, and rule 1 prevents him also holding his own Sanctuary. Resolution: the
prot paladin casts his greater on the Paladin class as something he can afford to override on
himself, then casts normal Sanctuary on himself. The Kings slot on the Paladin class is covered
by a different paladin.

---

## 4. Blessing value model

Ordered by importance to the raid:

| Blessing | Value |
|---|---|
| Salvation | Mandatory on everyone who is not a tank |
| Kings | Extremely useful on every spec in every situation |
| Light | High value on tanks; low impact for general raid healing |
| Might | High value for physical DPS; zero value outside that |
| Wisdom | High value for casters; small value for tanks and physical DPS |

---

## 5. Solver

The solver is deterministic. It is **not** a cost matrix, scoring function, or optimiser.
It is slot construction followed by list walks.

### 5.1 Slot construction

Slots are defined by blessing coverage in fixed priority order. Talents never change what the
slots are, only who fills them.

1. Salvation
2. Kings — slot omitted entirely if no paladin has the talent
3. Might or Wisdom — whichever the raid values more by headcount
4. The other of Might / Wisdom

With N paladins, fill the first N slots. If Kings is unavailable the list shifts up, and the
4th paladin (if present) may land on Light.

### 5.2 Slot filling

Once slots exist, capability is used only as a sort key:

- Might slot: prefer highest `impMight` rank
- Wisdom slot: prefer highest `impWisdom` rank
- Kings slot: requires `kings == true`
- Ties, zeros, and duplicate talents are **normal and expected**. No warning is emitted.
  Sort falls through: talent rank → spec → name, so the result is deterministic.
- The addon never suggests a respec.

### 5.3 Count rules (reference behaviour)

| Paladins | Greaters raid-wide | Overrides |
|---|---|---|
| 1 | Salv | Salv carrier → Kings on tanks; Light if no Kings talent |
| 2 | Salv, Kings | Salv carrier → next unfilled want per tank |
| 3 | Salv, Kings, Might/Wis | Same, one step further down each tank's want-list |
| 4 | Salv, Kings, Might, Wis | Light deprioritised; overrides only where a want is unfilled |

5 and 6 paladins require no additional logic — all blessings are already covered.

### 5.4 Intra-class conflicts

Greater blessings are class-wide, so a class with mixed specs cannot receive per-spec greaters.

Affected classes:

- Shaman: enhancement wants Might, elemental/restoration want Wisdom
- Druid: feral tank wants Might, balance/restoration want Wisdom
- Paladin: retribution wants Might, holy/protection want Wisdom
- Warrior: fury/arms want Might, protection tank handled by tank override

**Rule: minimise manual rebuffing while preserving priority.** The greater goes to whichever
subgroup is larger. The minority receives a normal blessing from the same paladin, added to
his override list.

Examples:
- 3 resto + 1 enh shaman → greater Wisdom, one normal Might on the enh shaman
- 1 resto + 3 enh shaman → greater Might, one normal Wisdom on the resto shaman
- feral tank + 2 boomkin → greater Wisdom; the feral picks up Might via his tank want-list

Physical vs caster classification is sourced from the roster page spec data where available,
and from live raid data otherwise.

### 5.5 Tank overrides

Each tank class has an ordered want-list. The solver computes what the tank already receives
from greaters, then the salv carrier casts the **highest unfilled entry**.

```
prot paladin   kings > wisdom > sanctuary > light
feral tank     kings > might > light
prot warrior   kings > might > light > sanctuary
```

Want-lists are stored per profile and are editable per class as a default. The
roster page's Tanks section (11.6) additionally offers a per-tank override of
up to 4 preferred-buff dropdowns, which take priority over the class default
for that one tank when set. This supersedes the original "no per-tank
dropdown" restriction: per-character overrides turned out to be worth the
added surface once the roster page grew a dedicated Tanks section.

Worked example — 3 paladins, prot warrior tank:
- Kings carrier casts greater Kings on warriors → `kings` filled
- Might/Wis carrier casts greater Might on warriors → `might` filled
- Salv carrier walks the list, first unfilled is `light` → normal Light on the tank

Same tank with 2 paladins: `kings` filled, next unfilled is `might` → normal Might.

Tanks are identified by raid `MAINTANK` / `MAINASSIST` flags, plus manual flags on the roster page.

### 5.6 Hunter pets

**On by default.** Controlled by `wants.petsEnabled` on the active profile, toggled in the
config UI. When disabled, pets are not assigned, not tracked, and generate no alerts — the
solver skips the pet pass entirely and `Track.lua` never registers pet units.

The toggle lives on the **profile**, not per character, because it changes solver output and
therefore the pushed assignment. If it were per character, clients would disagree about whether
pets are assigned. It is edited in the config UI but travels with the profile and with export.

When enabled: greater blessings do not reach pets, so every hunter pet needs an individual
normal blessing.

- Units are `raidpet1` .. `raidpet25`
- Want-list, editable per profile, seeded: `might > kings > light`
- Assigned to the salv carrier by default (his slot on the pet is free)
- Suppress alerts when the pet does not exist or is dead (`UnitExists`, `UnitIsDead`);
  re-arm on `UNIT_PET`
- Warlock pets are excluded entirely — not tracked, not shown, not assigned

Pets are the highest-churn tracking case in the addon. A pet dies, is revived, and silently
loses everything, which is why it is on by default. It is also the main source of alert noise
for a raid that does not care about pet blessings — hence the toggle.

### 5.7 Salvation clearing — deferred, not in v1

Automatic cancellation of unwanted Salvation via `CancelUnitBuff` was designed and then shelved.
The tank override in 5.5 already removes Salvation from tanks paladin-side, which makes
auto-cancel a redundancy rather than a mechanism, and it is the only feature that would have
required non-paladins to install the addon.

It is worth revisiting as an opt-in toggle once tanks have another reason to run the addon.
Retained design if resurrected: modes `off` / `tanks` / `always` defaulting to `tanks`; cancel
blocked in combat so re-check on `PLAYER_REGEN_ENABLED`; one attempt per 2 seconds; no more
than 3 retries per aura instance, to avoid fighting a paladin who is spamming greater Salvation.

Do not build this in v1.

### 5.8 Validation

Runs on every finished assignment. Two levels: `error` blocks Push, `warn` displays only.

Errors:
- A paladin assigned two blessings to the same class
- An assignment a paladin cannot cast (missing talent)
- A tank holding Salvation with no override

Warnings:
- A class missing Salvation or Kings when a carrier exists
- Unknown capability for an assigned paladin, meaning that paladin has not installed the addon
  or has not been seen since login
- A paladin's live active talent group differs from the `plannedGroup` in the profile

### 5.9 Purity requirement

`Solver/Slots.lua`, `Solver/Assign.lua`, and `Solver/Validate.lua` must be **pure functions**.
They take plain tables and return plain tables. They must not call `UnitClass`, `GetTalentInfo`,
`GetRaidRosterInfo`, or any other game API. This is what allows `/cbab sim` to run them against
fixtures with no group present, and is a hard architectural constraint.

---

## 6. Capability model

Capability is per **talent group**, not per character. Each paladin has one or two groups; the
active group is what the solver reads.

Spec is **cosmetic**. The solver reads only:

- `kings` — boolean, spell known
- `sanctuary` — boolean, spell known
- `impMight` — integer 0–2
- `impWisdom` — integer 0–2

A paladin with an off-meta build is just a capability record. The displayed spec label is derived
from whichever talent tree holds the most points, purely so the UI has something to print. The
spec field on the roster page is optional and must be visually secondary, so nobody believes they
are configuring the solver by setting it.

### 6.1 Talent detection

Build a `textureID → {tab, index}` map of every talent via `GetTalentInfo`. Then look up each
blessing's own texture in that map — the improved talent shares its icon with the base blessing.
This yields improved ranks without hardcoding talent tree positions, and survives patches.

Technique adapted from PallyPower's `ScanTalents` / `ScanSpells`.

Capability score for sorting is `spellRank + talentPoints`.

Scan **both talent groups**, not only the active one. `GetTalentInfo` accepts a talent group
argument; `GetNumTalentGroups()` reports how many exist and `GetActiveTalentGroup()` reports
which is live. Known-spell checks (`IsSpellKnown`) only reflect the **active** group, so Kings
and Sanctuary availability for the inactive group must be derived from its talent data rather
than from the spellbook.

### 6.2 Provenance and caching

Sources, in precedence order:

1. `live` — currently grouped with the paladin, data from their own client
2. `guild` — cached from a guild-channel broadcast, carries an age
3. `manual` — typed by the leader on the roster page
4. unknown — solver still runs, treats as no talents, marks the plan provisional

`live` overwrites `guild` overwrites `manual`. `manual` only overwrites unknown.

Paladins broadcast `SELF` on the **guild** channel on login and on capability change, jittered
and rate-limited. This is what gives a leader capability data hours before invites go out. A
`SELF` payload carries **both talent groups plus which is active**, so a cached record stays
useful after the paladin swaps.

Cache entries are keyed `name-realm` (split alts collide across realms otherwise), never expire,
and render greyed with an age when older than ~14 days.

### 6.3 Plan diffing on invite

When the raid forms, live `SELF` data is diffed against what the profile was planned with.
Present the differences and a single action:

```
Lightgrasp is Holy, not Ret (cached 5d ago). Imp Might no longer available.
Ironvow has Kings — plan assumed no Kings carrier.
[Re-solve]  [Keep plan]
```

### 6.4 Dual spec handling

Because a swap can happen between any two pulls, this mechanism is **core**, not an
invite-time nicety.

- Hook `ACTIVE_TALENT_GROUP_CHANGED` in addition to `SPELLS_CHANGED`, `PLAYER_TALENT_UPDATE`
  and `CHARACTER_POINTS_CHANGED`. Debounce; a swap fires several of these in a burst
- On swap, re-scan, update `activeGroup`, and re-broadcast `SELF`
- On receiving a `SELF` whose `activeGroup` differs from cache for a paladin **in the current
  assignment**, evaluate whether the change affects the plan. Only surface it if it does — a
  ret paladin swapping to a second ret build changes nothing the solver cares about
- If it does affect the plan, show a **non-blocking banner** on the editor and a chat notice to
  the leader: `Bulwarkk swapped to Protection — Kings carrier now available. [Re-solve]`.
  Never auto-solve (spec 11.1)
- Swaps are impossible in combat, and `Solve` is gated out of combat, so the two can never race
- A paladin's local bar reflects his **current** group's castable blessings. If he swaps into a
  spec that cannot cast his assigned blessing, his bar shows that assignment as unfulfillable
  and the alert window flags it

### 6.5 Planning against an inactive spec

The roster page allows pinning an expected talent group per character (`plannedGroup`), so a
leader can build a layout around "Bulwarkk will be on his prot spec tonight" while Bulwarkk is
currently holy. The solver uses `plannedGroup` when set and the character is not present live;
live active group always wins once they are in the raid. A mismatch between `plannedGroup` and
the live active group is a **validator warning**, since it usually means someone forgot to swap.

---

## 7. Splits and profiles

A split is a **named profile containing a 25-slot roster of character names**. There is no
main-to-alt mapping.

- Stored account-wide so all of a user's alts see all splits
- Roster slots hold `{name, class, spec, tank}`; class and spec are planning hints only, live
  raid data always wins
- One profile per raid composition. Not per boss
- Auto-detect: on `GROUP_ROSTER_UPDATE`, score each stored split by name overlap with the live
  raid. Best match above 60% auto-selects, with a chat notice and manual override
- Export/import: base64 of a LibDeflate-compressed LibSerialize blob in a copy-paste box.
  Carries roster, want-lists, assignment, and tank flags

---

## 8. Sync and authority

Leader-authoritative, locally cached, versioned.

### State per client

- `activeAssignment` — drives buttons and macros
- `epoch` — monotonic counter, plus author name and timestamp
- `source` — `pushed` / `local` / `default`

### Rules

- Leader or assist computes and pushes a full assignment blob at `epoch = lastKnown + 1`
- Every client writes it to SavedVariables immediately. It persists through reload, disconnect,
  and zoning. No re-push needed
- A client accepts a push only if `incomingEpoch > myEpoch`, or if it is from a verified
  leader/assist at equal-or-newer epoch (handles a leader who reloaded and lost count)
- On join or reload a client broadcasts `HELLO {myEpoch}`. Anyone with a higher epoch replies
  once, whispered. Leader replies preferentially; non-leaders wait 1–2s and only answer if
  nobody else did
- **Local override**: a paladin may change his own assignment. Sets `source = local`, bumps
  `localRevision`. Survives until the next higher-epoch push, which wipes it. UI marks it clearly
- Two assists pushing at the same epoch tiebreak deterministically on
  `(epoch, timestamp, authorName)`. Everyone resolves to the same winner with no round trip.
  The loser is told his push was superseded

### Protocol

- Prefix: `CBAB`
- Channels: `RAID`, `INSTANCE_CHAT` when in an instance group, `GUILD` for `SELF` broadcasts
- **Audience is coordinators and paladins.** `passive` clients neither send nor process
  anything except their own presence. Non-addon raiders simply never respond and are not
  treated as an error condition anywhere
- Message types: `HELLO`, `SELF`, `PUSH`, `PUSHACK`, `OVERRIDE`, `TANKFLAGS`, `PING`
- Serialization: LibSerialize → LibDeflate → chunked at 240 bytes with `part i/n` headers

### Throttle policy

- Own send queue, hard cap **8 messages/sec**, never more than 4 in any 250ms window
- `SELF` broadcast rate-limited to once per 10s regardless of how many `SPELLS_CHANGED` fire
- `HELLO` responses use random 0–1.5s jitter so 25 clients do not reply simultaneously
- `PUSH` is leader-only and rate-limited to once per 3s
- Inbound: ignore any sender not in the current raid or guild
- Silence from a non-paladin is normal and must never produce a warning

---

## 9. Performance requirements

The addon this replaces (PallyPower) causes UI lag because it buckets `UNIT_AURA` into a full
roster rebuild once per second, runs an unconditional 1s repeating timer, and matches auras by
**localised name and rank string**. Avoiding all three is a primary goal.

Requirements:

- **Spell ID matching only.** Never compare aura names or rank strings
- **Per-unit dirty set.** `UNIT_AURA` marks one unit dirty; it never triggers a full rebuild
- **Coalesced flush.** A single `OnUpdate` drains the dirty set at most every 0.25s, and
  **unregisters itself** when the set is empty. No always-on timer
- **Prefer `C_UnitAuras.GetAuraDataByIndex` and the `UNIT_AURA` `updateInfo` payload** so only
  changed aura instances are re-read. Detect availability at load and fall back to `UnitAura`
  behind a shim. Nothing outside the shim may call either API directly
- **One event frame for the entire addon**, owned by `Core.lua`. Modules subscribe through it.
  No module creates its own event frame
- Event-driven only. No polling for state that has an event
- No work at all while `InCombatLockdown()` except the duration-warning module
- `/cbab perf` exposes counters: aura events received, events coalesced away, flush count,
  milliseconds in the last flush

---

## 10. SavedVariables schema

```lua
## SavedVariables: CBABuffDB
## SavedVariablesPerCharacter: CBABuffCharDB
```

### `CBABuffDB` — account-wide, this is what export/import serializes

```lua
CBABuffDB = {
  schemaVersion   = 1,
  activeProfile   = "Split B",
  autoDetectSplit = true,

  profiles = {
    ["Split B"] = {
      name     = "Split B",
      modified = 1770000000,

      roster = {
        [1] = { name="Thrallbjorn", class="WARRIOR", spec="prot", tank=true  },
        [2] = { name="Lightgrasp",  class="PALADIN", spec="ret",  tank=false,
                plannedGroup=1 },
      },

      wants = {
        petsEnabled = true,
        tanks = {
          PALADIN = { "kings", "wisdom", "sanctuary", "light" },
          DRUID   = { "kings", "might", "light" },
          WARRIOR = { "kings", "might", "light", "sanctuary" },
        },
        pet = { "might", "kings", "light" },
      },

      assignment = {
        epoch     = 7,
        author    = "Bulwarkk",
        timestamp = 1770000000,

        greaters = {
          ["Lightgrasp"] = { WARRIOR="might", ROGUE="might", PRIEST="wisdom" },
          ["Bulwarkk"]   = { WARRIOR="kings", ROGUE="kings", PRIEST="kings"  },
          ["Sanctara"]   = { WARRIOR="salv",  ROGUE="salv",  PRIEST="salv"   },
        },

        overrides = {
          { caster="Sanctara", target="Thrallbjorn", blessing="light", reason="tank" },
          { caster="Sanctara", target="Stormfist",   blessing="might", reason="minority" },
          { caster="Sanctara", target="raidpet3",    blessing="might", reason="pet",
            owner="Kaelthon" },
        },
      },
    },
  },

  capabilityCache = {
    ["Lightgrasp-Whitemane"] = {
      class        = "PALADIN",
      activeGroup  = 1,
      groups = {
        [1] = { spec="ret",  kings=false, sanctuary=false, impMight=2, impWisdom=0 },
        [2] = { spec="holy", kings=false, sanctuary=false, impMight=0, impWisdom=2 },
      },
      source       = "guild",       -- live | guild | manual
      seen         = 1770000000,
      addonVersion = "1.0.0",
    },
  },
}
```

Notes:

- `assignment` lives inside the profile, so switching splits switches layouts atomically
- `epoch` persists through reload — this is what makes the hybrid authority model work
- `overrides[].reason` lets the UI group and explain them, and lets the validator distinguish a
  tank override from a minority override
- `wants` is the only solver configuration
- `capabilityCache` stores **all** talent groups plus which is active. `CBAB.Cap:Get` returns the
  active group's record by default; the full table is available for planning against an
  inactive spec

### `CBABuffCharDB` — per character, never shared

```lua
CBABuffCharDB = {
  schemaVersion = 1,
  ui = {
    bar   = { point="CENTER", x=0, y=-180, scale=1.0, locked=false, compact=true },
    alert = { point="CENTER", x=0, y=200,  scale=1.0, autoHide=true, hideInCombat=true },
  },
  warnings  = { enabled=true, threshold=120, sound=true, screenText=true, whisper=false },
  debug     = { enabled=false, verbose=false },
}
```

### Runtime only, never saved

Live roster, aura state, dirty-unit set, and the comm epoch table for *other* clients. All
rebuilt on login. Persisting them creates stale-data bugs — a saved buff timer is wrong
immediately and plausibly wrong, which is worse than absent.

Note that *your own* epoch **is** saved, inside `assignment`. Only the table of everyone else's
epochs is runtime.

### Migration

`schemaVersion` on both tables, with a numbered upgrade chain of pure functions on the table.
Future versions add keys rather than rewriting profiles, so members on an older version do not
lose their splits.

---

## 11. User interface

### 11.1 Assignment editor (leader)

Layout: **classes as rows, paladins as columns**. Rationale: the questions a leader asks during
setup are class-first ("do the mages have Kings?", "who is covering priests?"), which this
answers by reading across one row. Classes with no decisions collapse, so a 9-row table usually
renders as 5. Tank conflict markers sit on the class row where the conflict lives.

Contains:
- Capability line per paladin with provenance and age
- `Solve` button — **manual only**, gated on `InCombatLockdown()`, greys with a reason in combat
- `Push to raid` button, blocked by validator errors
- Plan diff banner on invite (section 6.3)
- Validator output inline
- Override count displayed, so the cost of a plan is visible at a glance

There is no auto-solve in v1.

### 11.2 Paladin bar

Frames **must** be named `PallyPowerC1` .. `PallyPowerC9` and `PallyPowerRF`, and must preserve
PallyPower's click semantics, so existing raid macros keep working:

```
/click PallyPowerC1 LeftButton Down    → greater blessing on class 1
/click PallyPowerRF RightButton Down   → seal
```

- Left click on class button: greater blessing. Right click: normal blessing
- Pop-out player buttons for single-target casts
- Class buttons blocked in combat; player buttons allowed
- Secure action button attributes may only be set out of combat — guard with `InCombatLockdown()`
- Visual: icon plus timer, class name **always visible** underneath each button (supersedes the
  original hover-only choice), coloured **border** for state (missing / expiring / good) rather
  than a filled background
- Shift-click forces a refresh even when the duration guard would block it
- A "cast next needed" button picks the single highest-value missing blessing
- The paladin's own summary ("here is your job") is a **tooltip on the drag handle**, not a page

The bar is a real window, not loose floating buttons: a backdrop panel with a title row (drag
handle + tooltip, "CBA Buff" title text, Lock/Unlock, Close) and a resize grip in the bottom-right
corner that adjusts the same scale value as the Config page's "Scale (%)" field. The panel lays
out and sizes itself immediately at `ADDON_LOADED`, not only after the first live roster event, so
its chrome is visible even before any group exists. None of this touches secure attributes --
sizing, backdrop, and label text are always safe to change regardless of combat.

Visibility is a persisted per-character setting (`ui.bar.shown`, default true). The title row's
Close button, `/cbab bar`, and a "Show bar" checkbox on the Config page (11.5) all toggle it, so
closing the bar always has two ways back.

Because the button names collide with PallyPower, detect both addons being loaded and show a
one-time popup: both use the same button names, macros will be unpredictable, disable one.
Do not import PallyPower's SavedVariables.

`/cbab pbar` toggles a debug mode that substitutes a synthetic multi-class/tank roster and
assignment for CBAB.Roster/CBAB.DB's live data, so the bar's layout, icons, and click-through can
be exercised before a live group exists. Only the player's own class button targets the real
`player` unit and can actually cast; every other button targets a fake unit token by design.
Buff-state coloring (Track.lua) is not faked -- every button reads as "missing" in this mode.

### 11.3 Alert window

Auto-hiding. No background when empty. Appears only when something is wrong. Rows are grouped
by **cause**, not by player:

```
Warriors — no Greater Kings           [cast]
Kings expiring 1:42 (Mages)           [cast]
Thrallbjorn (tank) — missing Light    [cast]
Kaelthon's pet — no blessing          [cast]
```

Pet rows appear only when `wants.petsEnabled` is true.

- Rows are click-to-cast if you are the assigned paladin, otherwise dim and informational
- Auto-hides after N seconds of clean state, reappears instantly on a problem
- Suppressed in combat by default (toggleable)

### 11.4 Warnings

Layered, individually toggleable:

1. **Local text and sound** — for your own assignments only. Default on, threshold 120s
2. **Whisper** — leader may enable whispering the responsible paladin when their assignment is
   under threshold or missing. Max 1 whisper per paladin per 60s, never in combat
3. **Raid warning post** — officer-only, manual button. Never automatic

Automatic raid-channel spam is prohibited. It is how addons get uninstalled.

### 11.5 Config page

Warnings, bar and alert positioning, debug toggles, and **hunter pet blessings
on/off**. The pet toggle is marked as a profile-level, raid-wide setting so it is clear that
changing it alters the plan everyone receives.

### 11.6 Roster page

Not a fixed slot count. Three N+1 auto-growing sections stacked in one scrollable
page, each showing its current entries plus exactly one blank row to type a new
one into -- never a fixed row count, and this supersedes the earlier "25 slots"
fixed-row design:

1. **Paladins** -- name, tank flag, optional and visually secondary spec hint
   field, and an Assign column auto-filled from a planning-time preview (the
   reference count table in 5.3, not the real solver -- it assumes Kings is
   available once there are 2+ paladins, since actual capability isn't known
   until a paladin's own client has scanned talents). Overridable per paladin;
   a red warning line appears only when the override differs from the preview.
2. **Tanks** -- name, class, and up to 4 PreferredBuff dropdowns auto-filled
   from that class's want-list (5.5), overridable per tank.
3. **Class headcounts** -- a manual, per-class-per-spec headcount table (small
   class icon, class-colored name, small numeric field per spec) feeding the
   Might/Wisdom majority used by the Assign preview, ahead of getting real
   numbers from live raid data or addon comms.

A character who is both a paladin and a tank is one underlying roster entry
that simply appears as a row in both of the first two sections -- there is no
duplicate storage. Profile switcher (name box, Switch/New/Rename/Delete
buttons) plus a profile-select dropdown (replacing an earlier clickable
button-per-profile list), and an export/import box, sit above and below the
three sections respectively.

---

## 12. Module breakdown

Single shared namespace via the addon vararg. No globals except frames that must be named for
macros.

```lua
local ADDON, CBAB = ...
```

TOC order is dependency order. Nothing reads a module loaded after it.

```
Core.lua
Data/Spells.lua
Data/Defaults.lua
DB.lua
Capability.lua
Roster.lua
Solver/Slots.lua
Solver/Assign.lua
Solver/Validate.lua
Comm.lua
Track.lua
UI/Bar.lua
UI/Alert.lua
UI/Editor.lua
UI/RosterPage.lua
UI/Config.lua
Sim.lua
Debug.lua
```

### Core.lua
Single event frame and dispatcher, module registry, slash command router, version constant.

```lua
CBAB:On(event, key, handler)
CBAB:Off(event, key)
CBAB:Fire(msg, ...)
CBAB:After(delay, fn)
CBAB:Print(...)
```

### Data/Spells.lua
Pure data, zero logic. Blessings keyed by internal id: `salv`, `kings`, `might`, `wisdom`,
`light`, `sanctuary`.

```lua
CBAB.Blessings        -- [id] = { name, greaterIDs={}, normalIDs={}, texture, talentGated }
CBAB.BlessingOrder
CBAB.WatchedSpellIDs
```

The `texture` field is load-bearing — it is the key for the talent lookup in section 6.1.

### Data/Defaults.lua
Default want-lists, UI positions, warning thresholds, schema defaults for both DB tables.

### DB.lua
Sole owner of SavedVariables. Nothing else touches the globals.

```lua
CBAB.DB:Init()
CBAB.DB:Profile()
CBAB.DB:SetActiveProfile(name)
CBAB.DB:CreateProfile(name)  CBAB.DB:DeleteProfile(name)  CBAB.DB:RenameProfile(old, new)
CBAB.DB:Export(name) -> string
CBAB.DB:Import(string) -> ok, err
CBAB.DB:Char()
CBAB.DB:Cache()
```

### Capability.lua

```lua
CBAB.Cap:ScanSelf() -> entry           -- all talent groups + activeGroup
CBAB.Cap:Get(nameRealm, group) -> record, source, age   -- group defaults to active
CBAB.Cap:GetEntry(nameRealm) -> entry
CBAB.Cap:Put(nameRealm, entry, source)
CBAB.Cap:DiffAgainstPlan(profile) -> {changes}
CBAB.Cap:AffectsPlan(nameRealm, oldEntry, newEntry) -> bool
```

Listens for `SPELLS_CHANGED`, `PLAYER_TALENT_UPDATE`, `CHARACTER_POINTS_CHANGED`, and
`ACTIVE_TALENT_GROUP_CHANGED`. Debounced — a respec or dual-spec swap fires several of these in
a burst. Emits `CAPABILITY_CHANGED` once the burst settles.

`AffectsPlan` exists so a swap that changes nothing the solver cares about produces no UI noise.

### Roster.lua

```lua
CBAB.Roster:Get() -> { [unit] = {name, class, unit, isTank, isPet, owner} }
CBAB.Roster:Paladins() -> {}
CBAB.Roster:Tanks() -> {}
CBAB.Roster:HunterPets() -> {}
CBAB.Roster:ClassCounts() -> { WARRIOR=6, ... }
CBAB.Roster:MatchProfile() -> profileName, confidence
```

Rebuilt on `GROUP_ROSTER_UPDATE` and `UNIT_PET`, never polled. Emits `ROSTER_CHANGED`.

### Solver/Slots.lua — pure

```lua
CBAB.Solver.BuildSlots(paladins, classCounts) -> slots
-- slots = ordered { {blessing="salv", caster="Sanctara"}, ... }
```

### Solver/Assign.lua — pure

```lua
CBAB.Solver.Assign(slots, roster, wants) -> assignment
```

Internally: greater pass → intra-class minority resolution → tank want-list walk → pet
want-list walk.

### Solver/Validate.lua — pure

```lua
CBAB.Solver.Validate(assignment, roster) -> { {level, code, message, subject} }
```

### Comm.lua

```lua
CBAB.Comm:Send(msgType, payload, channel)
CBAB.Comm:BroadcastSelf()
CBAB.Comm:PushAssignment()
CBAB.Comm:Hello()
CBAB.Comm:EpochTable() -> {}
```

### Track.lua

```lua
CBAB.Track:Start()  CBAB.Track:Stop()
CBAB.Track:StateFor(unit) -> { [blessingID] = {expires, caster, isGreater} }
CBAB.Track:Missing() -> { {unit, blessing, assignedTo} }
```

Owns the aura API shim. Emits `BUFF_STATE_CHANGED` at most once per flush.

### UI/Bar.lua, UI/Alert.lua, UI/Editor.lua, UI/RosterPage.lua, UI/Config.lua
See section 11.

### Sim.lua

```lua
CBAB.Sim:Run(fixtureName) -> assignment, validation
CBAB.Sim:RunAll() -> { {name, pass, diff} }
```

Fixture compositions covering 1/2/3/4/5/6 paladins across several class mixes, plus degenerate
cases: all-retribution paladins, no shamans, three tanks, no Kings talent anywhere, duplicate
improved talents, mixed-spec shamans and druids in both majority directions. Expected outputs
are committed as snapshots so a rule change shows exactly which compositions changed.

### Debug.lua
Log ring buffer, `/cbab dump`, `/cbab perf` counters, `/cbab epoch`.

### Cross-module contract

| Emitter | Message | Consumers |
|---|---|---|
| Roster | `ROSTER_CHANGED` | Editor, Track, Comm |
| Capability | `CAPABILITY_CHANGED` | Comm, Editor, Bar, Alert |
| Comm | `ASSIGNMENT_RECEIVED` | DB, Bar, Alert, Editor |
| DB | `ASSIGNMENT_CHANGED` | Bar, Alert, Track, Editor |
| Track | `BUFF_STATE_CHANGED` | Bar, Alert |

No module calls another module's internals. Only these messages and the public functions above.

---

## 13. Slash commands

```
/cbab                      toggle editor
/cbab roster               open roster page
/cbab config               open config
/cbab solve                run solver (out of combat only)
/cbab push                 push assignment to raid
/cbab check                list PALADINS not responding to HELLO (non-paladins are not checked)
/cbab debug on|off|verbose
/cbab dump roster|assign|comm|talents|cache
/cbab sim <fixture>        run solver against a fixture, no group required
/cbab sim all              run all fixtures, report pass/fail diffs
/cbab pbar                 toggle the paladin bar's synthetic-roster debug mode, no group required
/cbab bar                  toggle paladin bar visibility (also a "Show bar" checkbox in Config)
/cbab perf                 aura event counters and flush timings
/cbab epoch                show assignment epoch across the raid
```

---

## 14. Repository and packaging

```
CBABuff/
  CBABuff_TBC.toc
  .pkgmeta
  .github/workflows/release.yml
  docs/SPEC.md
  Libs/                  (gitignored, packager-injected)
  Core.lua
  Data/
  Solver/
  UI/
  locale/enUS.lua
```

- Semantic version in the TOC via `@project-version@` substitution
- GitHub Actions plus the BigWigs packager produces a zip attached to each release
- Libraries embedded by the packager, never committed
- Public GitHub repository

---

## 15. Prior art

`AznamirWoW/PallyPower` was analysed during design. Techniques adopted:

- The `textureID → talent` lookup for deriving improved blessing ranks
- `spellRank + talentPoints` capability scoring
- Greater-on-class plus normal-override-on-tank as the conflict resolution pattern
- The `/click` macro surface and button naming

Techniques deliberately rejected:

- Localised aura name and rank string matching
- Bucketed `UNIT_AURA` triggering full roster rebuilds
- An unconditional 1s repeating timer
- Greedy per-class assignment where class iteration order changes the result
- Hardcoded templates keyed on paladin count
- Forcing non-improvable blessings to be raid-wide rather than per-class
- A custom hex-packed comm protocol with `lastMsg` deduplication, which silently swallows
  identical resends
