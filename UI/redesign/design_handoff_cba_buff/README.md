# Handoff: CBA Buff — UI Redesign

## Overview
A full visual redesign of **CBA Buff**, the paladin-blessing management addon for World of Warcraft: TBC Anniversary Edition (client 2.5.6, Interface `20506`) — the modern replacement for PallyPower. This package covers four surfaces:

1. **Paladin bar (pbar) — "Combat Strip"** — the always-on HUD you cast from (the chosen direction).
2. **Roster window** — profiles, paladin/tank assignment tables, and the Solve/Push rail.
3. **Config window** — settings, reorganized so nothing overflows.
4. **Alert window** — the floating popup that flags missing/expiring buffs.

The redesign is a **full modern dark reskin** (inspired by EllesmereUI — dark, high-contrast, well-organized) with a consistent **blessing + class color system**. Three dead controls from the old bar were **removed**: the drag-handle square, the Righteous-Fury/seal box, and blank class slots. There is **no RF or seal tracking**.

## Implementation Status

| Surface | Status |
|---|---|
| 1. Paladin bar ("Combat Strip") | **Done** — `UI/Bar.lua`, commit `288bc4a` on `main` |
| Shared design system | **Done** — `UI/Theme.lua` |
| 2. Roster window | **Done** — `UI/RosterPage.lua` |
| 3. Config window | Not started — still the pre-redesign visuals |
| 4. Alert window | Not started — still the pre-redesign visuals |

**What shipped (pbar):** `UI/Bar.lua` was reworked to match this doc's Combat
Strip states (§1, HTML `#2a`–`#2d`) — one chevron now cycles three real
states (minimized pill → compact "your casts" row → expanded all-paladins
grid, others read-only) instead of the old always-on multi-row grid. RF/Seal
and the Solve/Sync/Report toolbar are gone from the bar per this doc's spec;
Sync and Report moved to the Roster page's Solve rail (next to the existing
Solve/Push buttons) since the Combat Strip reference has no toolbar. Every
secure-button / combat-lockdown detail, `PallyPowerC1`–`C9` macro
compatibility, and class-compaction rule from the old bar is unchanged.

**Shared design system:** `UI/Theme.lua` is new and holds everything the
remaining three surfaces should build on — the full Core Palette / Accents
hex table from this doc's Design Tokens section, a `color-mix`-equivalent
blessing-tint helper, a type-scale font system (`Theme.Fonts.*`), and
gradient/glow/hairline panel builders approximating what WoW's UI API can't
do natively (no native rounded corners or blur — see this doc's own
Fidelity note). Roster/Config/Alert should reuse it rather than re-deriving
colors/fonts locally.

**Fonts:** Rajdhani/Barlow `.ttf` files have not been added yet — see
`Fonts/README.md` for the exact filenames expected. Until they're dropped
in, `UI/Theme.lua` falls back to stock WoW fonts automatically; no code
change is needed once the real files exist.

**Known gaps / simplifications from this round**, worth revisiting if they
turn out to matter in practice: the "cast next needed" utility button was
dropped with no replacement (no equivalent in the reference design); WoW
has no letter-spacing support on this client tier confirmed, so
`Theme.StyleText`'s `spacing` option is probed defensively and may be a
no-op; rounded corners/blur are approximated with plain square borders and
flat-color halos. None of this has been verified against a running client —
see the Verification note in the next section.

**What shipped (Roster):** `UI/RosterPage.lua` was reworked onto
`UI/Theme.lua` to match this doc's §2 Roster window — window chrome
(fill/hairline/shadow), a single-row profile toolbar (the old name-box
"Switch" button folded into the selector dropdown itself), and a two-pane
body: the Paladins/Tanks tables keep their own scroll region while the
Solve rail (Solve/Push/Sync/Report, three stat chips, a Resolved list, and
class headcount chips) is now a separate fixed panel on the right — this is
what fixes the pre-redesign double-scrollbar the doc calls out. Blessing/
class-colored dots were added next to every Assign/Aura/tank-buff/tank-class
dropdown so "the color system reads at a glance" without having to
retexture native `UIDropDownMenuTemplate` chrome (left un-styled, same
posture as `UI/Bar.lua`'s own edit dropdown). `UI/Theme.lua` gained three
new shared builders this round — `CreateButton`, `CreateToggle`,
`ApplyHoverHighlight` — for the plain backdrop buttons/toggles this window
needed; Config and Alert should reuse them rather than re-deriving.

**Known gaps / simplifications (Roster):** the Class Headcounts section
(manual per-class/spec want-count input, needed to seed the planning
preview before real capability data exists) has no equivalent in the
reference design, which shows only read-only headcount chips — both survive
here: the editable table stayed in the main scroll, and the rail's chips are
a read-only summary of the same data. Rounded pill toggles/corners are still
plain squares (Fidelity note, unchanged). None of this has been verified
against a running client — see the Verification note below.

**Next up:** pick one of Config / Alert and repeat the same approach
(reskin via `UI/Theme.lua`, preserve all underlying Lua logic untouched,
verify secure-attribute/combat-lockdown call sites weren't touched where
applicable).

## About the Design Files
`CBA Buff Redesign.dc.html` in this bundle is a **design reference created in HTML** — a prototype showing the intended look, layout, color system, and interaction states. It is **not production code to copy**.

The real target is the existing addon codebase at **github.com/herodope/cbabuff** — **Lua + the Blizzard WoW UI API** (frames, textures, FontStrings), the `UI/` folder. Recreate these designs as Lua-driven frames using WoW's addon patterns (or a UI helper lib like AceGUI/LibStub if the project already uses one — it vendors LibStub/LibSerialize/LibDeflate). CSS concepts below map to WoW equivalents:

- `background` / gradients → `Texture` layers or a backdrop with solid/gradient textures.
- `border` / `border-radius` → backdrop edge files or nine-slice textures (WoW has limited rounding; approximate with the addon's frame template).
- `box-shadow` / glow → soft additive glow textures behind the frame.
- Hover/active → `OnEnter`/`OnLeave`/`OnMouseDown`/`OnMouseUp` scripts adjusting vertex color / alpha.
- Fonts (Rajdhani/Barlow) → these are web fonts; substitute the addon's chosen font files via `FontString:SetFont()`, or the closest bundled font. Match **weight, size, letter-spacing, case** as specified.

## Fidelity
**High-fidelity.** Colors, typography, spacing, and interaction states are final and specified exactly below. Recreate the layout and visual system faithfully within the constraints of the WoW UI API. Where the API can't match a CSS effect 1:1 (rounded corners, blur), approximate as closely as the addon's existing frame chrome allows and keep the color/type system exact.

## Icons
The mock now uses the **real WoW textures**, pulled from the public Wowhead icon CDN
(`https://wow.zamimg.com/images/wow/icons/large/<slug>.jpg`) purely as a rendering convenience for the HTML reference. In the addon, source the identical textures natively:
- Blessing tiles → `GetSpellTexture(spellID)` (spell IDs already live in `Data/`).
- Class header tiles → the class icon atlas / `CLASS_ICON_TCOORDS`.

Slugs used (swap for the in-game texture path):
- Salvation `spell_holy_sealofsalvation` · Kings `spell_magic_greaterblessingofkings` · Might `spell_holy_fistofjustice` · Wisdom `spell_holy_sealofwisdom` · Sanctuary `spell_holy_greaterblessingofsanctuary` · Light `spell_holy_prayerofhealing02`
- Classes `classicon_<class>` (e.g. `classicon_warrior`).

Each tile keeps a **color-tinted border/ring** (blessing or class color) around the icon so the color system reads even at a glance. In the HTML the icon is applied as a `background-image` (not an `<img>`) so it never fetches a bad URL mid-render — replicate with a texture layer behind the tinted border.

---

## Design Tokens

### Fonts
- **Rajdhani** (weights 400/500/600/700) — titles, section headers, button labels, all numeric/data values. Used UPPERCASE with letter-spacing for labels.
- **Barlow** (weights 300–700) — body copy, descriptions, secondary text.
- Substitute with bundled addon fonts if these can't ship; preserve weight/size/case/spacing.

### Type scale (px, at 100% UI scale)
| Role | Font | Size | Weight | Tracking | Case |
|------|------|------|--------|----------|------|
| Window title ("CBA Buff") | Rajdhani | 15 | 700 | 2px | UPPER |
| Window subtitle ("Roster"/"Config") | Rajdhani | 14 | 500 | 1px | — |
| Section header ("Paladins") | Rajdhani | 14 | 700 | 1.5px | UPPER |
| Table column labels | Rajdhani | 10.5 | 600 | 1px | UPPER |
| Body / description | Barlow | 12.5–14 | 400–600 | — | — |
| Button label | Rajdhani | 12–13.5 | 600–700 | .5–.8px | UPPER |
| Numeric value | Rajdhani | 15–17 | 700 | — | — |
| Name (class-colored) | Rajdhani | 14–14.5 | 700 | — | — |

### Core palette
| Token | Hex |
|-------|-----|
| Page backdrop (dark→darker) | `#12191f` → `#0a0e12` → `#06090b` |
| Window fill (gradient top→bottom) | `#0f161c` → `#0a0e12` |
| Bar/popup fill (gradient) | `#161f27` → `#10161c` |
| Elevated row fill | `rgba(255,255,255,.012–.014)` |
| Sidebar / rail fill | `rgba(0,0,0,.18)` |
| Control fill (buttons, fields) | `#141c23` / field `#101820` / `#131b22` |
| Border (subtle) | `#1c2730` / `#1e2a33` / `#26333d` |
| Border (control) | `#33434f` / `#2c3a45` / `#2a3844` |
| Divider line | `#28353f` |

### Accents
| Token | Hex | Use |
|-------|-----|-----|
| Gold (primary) | `#E7B24C` | primary actions, brand, active nav |
| Gold gradient | `#E7B24C` → `#c8912f` | filled primary button |
| Gold text/tint | `#f0d79a` / `#f0c774` | titles, gold text |
| Teal (success/live) | `#35D0A0` | synced dot, toggles ON, "clean" state |
| Teal text | `#5fe0b8` / `#8fb7ab` | success labels |
| Blue (push/secondary) | `#7cc0ef` (border `#35506a`) | "Push to raid" action |
| Red (danger/missing) | `#E1553F` | warnings, missing buffs, delete |
| Red text | `#f0857a` / `#f0b3a8` / `#e0b0a8` | warning labels |

### Text colors
Primary `#f2f5f7`/`#dfe6eb` · secondary `#9aa6ae`/`#aab4bb` · muted `#7f8b93`/`#6f7b83` · faint `#5f6b73`/`#4a5660`.

### Blessing colors (the system)
| Blessing | Hex |
|----------|-----|
| Salvation | `#E8629E` (pink) |
| Kings | `#8E7BE6` (purple) |
| Might | `#E15A47` (red) |
| Wisdom | `#43A6E6` (blue) |
| Sanctuary | `#4FB477` (green) |
| Light | `#E7BE4A` (gold) |

Tinting recipe: fill `color-mix(blessing 13–38%, dark #101820/#0d1216)`, border `color-mix(blessing 38–58%, dark)`, label text `color-mix(blessing 52–70%, white)`, plus a solid blessing-color dot/underline. In Lua, precompute these blends as RGBA and apply via `Texture:SetVertexColor()` / `FontString:SetTextColor()`.

### Class colors (Blizzard standard)
Warrior `#C79C6E` · Rogue `#FFF569` · Priest `#E8E8E8` (from white) · Druid `#FF7D0A` · Paladin `#F58CBA` · Hunter `#ABD473` · Mage `#69CCF0` · Warlock `#9482C9` · Shaman `#0070DE`. Use `RAID_CLASS_COLORS` in-game.

### Radius / shadow / motion
- Radius: tiles 8–11px, windows 14px, buttons 8–9px, pills/toggles 999px.
- Window shadow `0 30px 80px rgba(0,0,0,.6)`; bar `0 18px 50px rgba(0,0,0,.55)`; popup adds a color-tinted glow `0 0 40px rgba(accent,.08)`.
- Every window/bar has a **3px top accent hairline**: `linear-gradient(90deg, transparent, ACCENT, transparent)` — gold normally, red on the active alert, teal on the clean alert.
- Transitions: `filter, transform, box-shadow .12s ease`.

### Interaction states (applied to all buttons, tiles, toggles, rows)
- **Hover**: gold buttons `brightness(1.07) + translateY(-1px) + shadow 0 8px 24px rgba(231,178,76,.45)`; all other controls `brightness(1.17) + translateY(-1px)`. Table rows: fill → `rgba(255,255,255,.05)`, border → `#37474f`. Alert rows: fill → `color-mix(severity 16%, #101820)`.
- **Active/press**: `translateY(0) scale(.96) brightness(.9)`.

---

## Screens / Views

### 1. Paladin bar — "Combat Strip" (pbar)
The always-on HUD. One chevron cycles three sizes.

**States (see sections 1b/2a–2d in the HTML):**
- **Minimized** — a small rounded pill: gold brand chip (20px) + status dot + coverage count `8/8` (teal) OR `2 gaps` (red) + divider + chevron `⌄`. ~ auto width, height ~35px. Two variants: clean (teal, border `#2a3844`) and gaps (red, border `#43302b`).
- **Your casts (default)** — horizontal pill container (fill `#161f27→#0f151b`, border `#2a3844`, radius 14, shadow `0 14px 40px rgba(0,0,0,.5)`). Left: vertical `CBA` label + teal status dot. Divider. Then a row of **class buttons** (44×44 tiles, gap 8) — each tile shows the blessing you cast on that class (tinted per blessing color, label = blessing abbrev). Empty assignment = dashed tile. Divider. Chevron `⌄` (30×44).
- **Multiple assignments** — same strip, but tiles carry *different* blessings per class (color tells which). Below, a compact blessing legend (dot + name).
- **Expanded — all paladins** — grows into a rounded panel: header row (teal dot + `RAID COVERAGE` label + collapse `⌃`), a class-abbrev header row (class-colored, indented 104px to clear the name column), then one row per paladin: name column (98px, Paladin pink `#F58CBA`, plus a small role tag `you · live` / `read-only`) + 8 tiles (38×38). **Only the local paladin's row is live/clickable; all others render at opacity .62** (read-only coverage view).

**pbar behavior (from the addon README — preserve):**
- Class buttons keep the PallyPower-compatible frame names `PallyPowerC1`–`C9` (order: Warrior, Rogue, Priest, Druid, Paladin, Hunter, Mage, Warlock, Shaman) so existing `/click` macros work unmodified. `C1` = first class actually present in the raid, not a fixed class.
- **Left-click** a class button = greater blessing on that class; **right-click** = normal blessing on current target.
- Class buttons are **blocked in combat**; hovering a class pops out **individual player buttons** for single-target casts (those work in combat). Shift-click forces a refresh.
- The old separate handle/RF/seal buttons are gone. The bar toggles the editor by other means (slash `/cbab`, or the roster/config buttons) — do not re-add the handle square.

**Command Bar (alternate, section 1a in HTML):** a fuller version with a header (brand + `Synced · 4 pally` pill + Solve/Sync/Report + Lock) and your identity line + one-line summary above the class-button row, with the hover popout demonstrated. The user chose the Combat Strip, but this shows the same components in a heavier layout if a docked/expanded mode is wanted. The **hover popout** = a floating card above the hovered class: title `Blessing · single target` + list of that class's raid members, each a mini button (26px tinted tile + name), with a downward caret.

### 2. Roster window (section 3a in HTML)
Width ~1040px. Fixes the old **double-scrollbar**: the tables live in **one** scroll area; the Solve rail on the right is fixed.

- **Title bar**: brand chip + `CBA Buff` + `Roster` subtitle + close `✕`.
- **Profile toolbar** (one row): `PROFILE` label + selector pill `Default 25m ▾` + `New` / `Rename` / `Delete` (Delete uses red border `#4a2f2c`, text `#d99a8f`) + spacer + **Pets in pbar** toggle (teal ON) + `Open pbar` (gold-outline: border `rgba(231,178,76,.55)`, fill `rgba(231,178,76,.1)`, text `#f0c774`) + divider + `Export` / `Import`.
- **Body**: main scroll (left, `max-height 600px, overflow-y auto`) + fixed rail (right, 308px).
- **Paladins table** — grid `1.5fr 78px 92px 1.3fr 1.25fr`, columns: Name / Tank / Spec / Assignment / Aura. Each row (fill per `rowBg`, border `#1c2730`, radius 9): drag handle `⋮⋮` + name (Paladin pink); Tank = blue pill `rgba(67,166,230,.14)` border `.4` text `#7cc0ef`, or `—`; Spec text; Assignment = blessing chip (tinted, dot + name + `▾`); Aura = dark dropdown pill (`{aura} ▾`). Then a dashed **`+ Add paladin`** row.
- **Tanks table** — grid `1.3fr 96px repeat(4,1fr)`, columns: Name / Class / 1st / 2nd / 3rd / 4th (buff priority high→low). Name; Class (class-colored); four blessing chips (tinted, dot + name).
- **Solve rail** (right, fill `rgba(0,0,0,.18)`, left border `#1e2a33`):
  - `Solve plan` (gold filled) + `Push to raid` (blue: border `#35506a`, fill `rgba(53,140,208,.14)`, text `#7cc0ef`).
  - Three stat chips: `4 overrides` (gold), `0 errors` (teal), `3 warns` (red).
  - **Resolved** list — per paladin: blessing dot + name (pink) + `Greater {Blessing} · {detail}`.
  - **Warnings** list — red-tinted rows (dot + text), e.g. "Bakalmao — no capability reported (not seen since login)".
  - **Class headcount** chips at bottom — class abbrev (class-colored) + count.

### 3. Config window (section 4a in HTML)
Fixed **860×600**. Fixes the old overflow by splitting settings into a **left category rail**; only one group shows at a time so nothing spills.

- **Title bar**: brand + `CBA Buff` + `Config` + close.
- **Sidebar (216px)**: `SETTINGS` label + nav buttons (colored dot + label). **Active** = fill `rgba(231,178,76,.12)`, border `rgba(231,178,76,.4)`, text `#f0d79a`; inactive text `#aab4bb`, transparent. Categories & dot colors: **Warnings** `#E1553F`, **Paladin bar** `#E7B24C`, **Alert window** `#43A6E6`, **Hunter pets** `#ABD473`, **Debug** `#8E7BE6`. Version string pinned at the bottom.
- **Content**: header (section title Rajdhani 22px + subtitle) then setting rows (fill `rgba(255,255,255,.014)`, border `#1c2730`, radius 10). Row = label + optional description (left) and a control (right):
  - **Toggle** — 40×22 pill. ON: track `rgba(53,208,160,.22)` border `.5`, knob `#35D0A0` glowing, knob right. OFF: track `#131b22` border `#33434f`, knob `#4a5660`, knob left.
  - **Number stepper** — `[–]  value unit  [+]`, value in gold (`#f0d79a`), unit muted. Steppers 26×34.
  - **Button** — gold-outline style.
  - **Note** — full-width callout (gold dot + muted text) for profile-wide warnings (e.g. Hunter-pets note).
- **Footer**: `Reset section` (ghost) + spacer + `Done` (gold filled).

**Config contents (exact rows):**
- **Warnings**: Enabled (toggle, ON) · Expiring threshold (number, 120 s) · Sound (ON) · Screen text (ON) · Whisper responsible paladin (OFF; desc "Leader only · max 1 / 60s · never in combat").
- **Paladin bar**: Open pbar (button) · Show bar (ON) · Locked (OFF) · Compact (ON) · Scale (number, 200 %).
- **Alert window**: Preview alert (button) · Auto-hide when clean (ON) · Suppress in combat (ON) · Locked (OFF) · X offset (0 px) · Y offset (200 px).
- **Hunter pets**: NOTE "Saved on the active PROFILE, not this character. Changing it alters the plan every paladin receives on the next solve / push — it is not a personal display setting." · Pets enabled (this profile) (ON).
- **Debug**: Enabled (OFF) · Verbose (OFF; desc "Also echo the log to chat").

### 4. Alert window (sections 5a/5b in HTML)
Compact floating popup, width ~412px. Positioned by the config X/Y offset. Auto-hides when clean.

- **Active (5a)** — border `#3a2b2b`, red top hairline, red glow. Header: `!` badge (red) + `BUFF ALERTS` + count badge `4` (red) + `⚙` + `✕`. Then alert rows (fill `color-mix(severity 8%, #101820)`, border `color-mix(severity 30%)`, **3px left border in severity color**): raider name (class-colored) + severity tag (`Missing` red / `Expiring` amber); second line = blessing chip `Greater {Blessing}` + `by {Paladin}` (pink); trailing = countdown (only for expiring, e.g. `42s`, `1:58`) + target button `⌖`. Footer: `Post raid warning` (amber-outline, `officer only` note) + spacer + `Snooze 30s`.
- **Clean (5b)** — border `#24382f`, teal top hairline + glow. Header shows a teal `✓` badge. Centered content: large teal check tile + `All blessings up` + `Nobody's missing anything. Hiding in 3s…`. Reflects the **Auto-hide when clean** setting.

---

## Interactions & Behavior
- **pbar chevron** cycles Minimized → Your casts → Expanded (and back).
- **Class button**: left-click greater / right-click normal / hover → single-target popout / shift-click refresh. Combat-locked for class-wide casts; single-target casts allowed in combat.
- **Roster**: Solve plan runs the deterministic solver (out of combat); Push to raid broadcasts; rows editable; drag handle reorders; Export/Import round-trips the full profile string.
- **Config**: clicking a sidebar category swaps the content panel (state = active section). Toggles/steppers mutate settings live.
- **Alert**: appears on gaps, auto-hides when clean (if enabled), suppressed in combat (if enabled); `Post raid warning` is manual + officer-only (never automatic); `⌖` targets the raider.
- **All controls** animate with the hover/press states in Design Tokens (.12s ease).

## State Management
- **Active profile / split** (25-slot roster, want-lists, tank flags, assignment) — account-wide; scored by name overlap on raid formation.
- **Assignment epoch** — deterministic winner across concurrent pushes; survives reload/zone.
- **Capability cache** — each paladin's talents, broadcast to guild/raid.
- **Live buff tracking** — `UnitAura` on raid1..25 by spell ID; drives the coverage tiles and alerts.
- **UI state** — pbar size (min/compact/expanded), config active section, window lock/position, per-window show/hide.
- **Config flags** — warnings (enabled/sound/screen text/threshold/whisper), pbar (show/lock/compact/scale), alert (auto-hide/suppress-combat/lock/x/y), pets (profile-wide), debug (enabled/verbose).

## Assets
- **No image assets are shipped.** Icons render from the Wowhead CDN in the HTML only — source the identical textures natively in the addon (`GetSpellTexture`, class icon atlas) as described in *Icons*.
- **Fonts**: Rajdhani + Barlow (Google Fonts) are used in the mock only; substitute in-addon fonts.

## Screenshots
The `screenshots/` folder has reference captures of each surface:
- `1-combat-strip.png` — pbar expanded (all-paladins coverage)
- `2-combat-strip-compact.png` — pbar "your casts" + multiple-assignments
- `3-roster.png` — Roster window (tables + Solve rail)
- `4-config.png` — Config window (sidebar + Warnings section)
- `5-alert.png` — Alert window (active alerts)

## Files
- `CBA Buff Redesign.dc.html` — the full HTML design reference. It is organized as stacked sections (newest at top): **Turn 5** Alert (5a/5b), **Turn 4** Config (4a), **Turn 3** Roster (3a), **Turn 2** Combat Strip states (2a–2d), **Turn 1** the three original pbar directions (1a Command Bar, **1b Combat Strip — chosen**, 1c Raid Matrix). Open it in a browser; hover controls to see interaction states.
- Reference the existing addon UI in `github.com/herodope/cbabuff` → `UI/`, `Core.lua`, `Roster.lua`, `Track.lua`, `Solve.lua`.
