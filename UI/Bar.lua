local ADDON, CBAB = ...
local Theme = CBAB.Theme

-- The paladin bar (pbar): a PallyPower-style grid, one row per paladin,
-- one column per populated class plus Pets and Aura. Frame names
-- PallyPowerC1..PallyPowerC9 are a hard compatibility requirement
-- (spec 11.2) -- existing raider macros click these names directly. This
-- is the ONLY place in the addon the PallyPower name appears; every string
-- a user reads says CBA Buff. Those compat-named buttons ARE the local
-- player's own row (row 1) -- every other paladin's row uses ordinary,
-- non-compat-named pooled frames.
--
--   /click PallyPowerC1 LeftButton Down    -> greater blessing on class 1
--
-- Class columns are compacted to only POPULATED classes in a fixed
-- priority order (verified against PallyPower's own ClassID table for its
-- BCC/TBC branch): Warrior, Rogue, Priest, Druid, Paladin, Hunter, Mage,
-- Warlock, Shaman. So "C1" is whichever of those is the first class
-- actually present in the raid, not a fixed class -- replicating this
-- compaction is what makes an existing macro land on the right class.
--
-- Visual design: UI/redesign/design_handoff_cba_buff/README.md ("Combat
-- Strip"). Righteous Fury/Seal tracking and the Solve/Sync/Report toolbar
-- from the pre-redesign bar are gone per that spec -- RF/Seal has no
-- replacement (README: "no RF or seal tracking"); Sync and Report moved to
-- UI/RosterPage.lua's Solve rail, alongside Solve/Push. The bar itself now
-- only has three visual states, cycled by one chevron (README §1: Combat
-- Strip states 2a-2d):
--   minimized -- status pill only (brand chip + dot + N/M or "K gaps")
--   compact   -- row 1 only (your own castable buttons), 44x44 tiles
--   expanded  -- every paladin's row, 38x38 tiles, others read-only
-- persisted as CBABuffCharDB.ui.bar.size ("minimized"|"compact"|"expanded").
local CLASS_PRIORITY = { "WARRIOR", "ROGUE", "PRIEST", "DRUID", "PALADIN", "HUNTER", "MAGE", "WARLOCK", "SHAMAN" }

local CLASS_ABBR = {
	WARRIOR = "WAR", ROGUE = "ROG", PRIEST = "PRI", DRUID = "DRU", PALADIN = "PAL",
	HUNTER = "HUN", MAGE = "MAG", WARLOCK = "WLK", SHAMAN = "SHM",
}

-- ============================================================
-- Secure attribute writes: ONLY legal out of combat. Every write in this
-- file goes through this pair so nothing ever touches SetAttribute while
-- InCombatLockdown() -- queued writes replay once combat drops.
-- ============================================================

local pendingWrites = {}

local function setAttributeSafe(button, attr, value)
	if InCombatLockdown() then
		pendingWrites[#pendingWrites + 1] = { button = button, attr = attr, value = value }
	else
		button:SetAttribute(attr, value)
	end
end

CBAB:On("PLAYER_REGEN_ENABLED", "bar:flush-attrs", function()
	if #pendingWrites == 0 then return end
	local writes = pendingWrites
	pendingWrites = {}
	for _, w in ipairs(writes) do
		w.button:SetAttribute(w.attr, w.value)
	end
end)

-- ============================================================
-- Spell name resolution: secure `spellN` attributes want the spell's own
-- name (any known rank), which auto-resolves to the CASTER'S OWN highest
-- known rank at cast time. This is what makes row 1's cells safe to click:
-- the click always casts using the CLICKING player's own spellbook, using
-- whichever blessing/aura row 1's plan says belongs in that column. If the
-- clicking player doesn't know that spell, the cast is a silent no-op --
-- there is no way for one client to cast as another player, full stop.
-- ============================================================

local function spellNameFor(blessingId, isGreater)
	local blessing = CBAB.Blessings[blessingId]
	local ids = isGreater and blessing.greaterIDs or blessing.normalIDs
	return CBAB:GetSpellName(ids[1])
end

local function auraSpellNameFor(auraId)
	return CBAB:GetSpellName(CBAB.Auras[auraId].ids[1])
end

-- Class-colored, title-cased label for tooltip text.
local function classDisplayLabel(class)
	local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	local displayName = class:sub(1, 1) .. class:sub(2):lower()
	if color and color.colorStr then
		return "|c" .. color.colorStr .. displayName .. "|r"
	end
	return displayName
end

-- ============================================================
-- /cbab pbar debug mode: lets the bar be laid out, populated, and clicked
-- on before a live group exists, since Roster.lua's cache is otherwise
-- only ever built from real grouped units on GROUP_ROSTER_UPDATE/UNIT_PET.
-- A synthetic roster/assignment stands in for CBAB.Roster/CBAB.DB while
-- active; every read in this file goes through the getX() wrappers below
-- rather than calling CBAB.Roster/CBAB.DB/CBAB.Track directly, so toggling
-- debugMode is the only thing that needs to change anywhere. Debug mode
-- only ever populates ROW 1 (the local player) -- it fakes class/tank
-- layout for testing the grid's columns, not a multi-paladin roster.
--
-- Real casts still only work for the player's OWN class button, since
-- that one targets the real "player" unit -- every other button targets a
-- fake unit token that resolves to nothing, by design.
-- ============================================================

local debugMode = false
local debugRoster, debugAssignment

local function buildDebugRoster()
	local _, myClass = UnitClass("player")
	local roster = {
		player = { name = UnitName("player"), class = myClass, unit = "player", isTank = false, isPet = false },
	}
	local n = 0
	for _, class in ipairs(CLASS_PRIORITY) do
		if class ~= myClass then
			n = n + 1
			local unit = "cbabDebugFake" .. n
			roster[unit] = {
				name = "Debug" .. class:sub(1, 1) .. class:sub(2):lower(),
				class = class,
				unit = unit,
				isTank = (class == "WARRIOR"),
				isPet = false,
			}
		end
	end
	return roster
end

local function buildDebugAssignment()
	local myName = UnitName("player")
	local greaters = { [myName] = {} }
	local n = 0
	for _, class in ipairs(CLASS_PRIORITY) do
		n = n + 1
		greaters[myName][class] = CBAB.BlessingOrder[((n - 1) % #CBAB.BlessingOrder) + 1]
	end
	return {
		epoch = 0,
		author = myName,
		timestamp = time(),
		greaters = greaters,
		overrides = { { caster = myName, target = "DebugWarrior", blessing = "light", reason = "tank" } },
		auras = { [myName] = "devotion" },
	}
end

local function getRosterCache()
	if debugMode then return debugRoster end
	return CBAB.Roster:Get()
end

local function getClassCounts()
	if debugMode then
		local counts = {}
		for _, m in pairs(debugRoster) do
			if not m.isPet then
				counts[m.class] = (counts[m.class] or 0) + 1
			end
		end
		return counts
	end
	return CBAB.Roster:ClassCounts()
end

local function getAssignment()
	if debugMode then return debugAssignment end
	local profile = CBAB.DB:Profile()
	return profile and profile.assignment
end

-- No real buff timers to fake meaningfully -- see file header.
local function getTrackStateFor(unit)
	if debugMode then return {} end
	return CBAB.Track:StateFor(unit)
end

-- Every paladin row lookup goes through this instead of CBAB.Roster:Paladins()
-- directly, so debug mode's synthetic roster is respected consistently.
local function getRosterPaladins()
	local list = {}
	for _, m in pairs(getRosterCache()) do
		if not m.isPet and m.class == "PALADIN" then
			list[#list + 1] = m
		end
	end
	return list
end

-- ============================================================
-- Class -> button-index compaction (spec 11.2).
-- ============================================================

local function computeClassLayout()
	local counts = getClassCounts()
	local layout = {} -- [buttonIndex] = classToken
	local cbNum = 0
	for _, class in ipairs(CLASS_PRIORITY) do
		if (counts[class] or 0) > 0 then
			cbNum = cbNum + 1
			layout[cbNum] = class
		end
	end
	return layout
end

local function representativeUnit(class)
	for unit, m in pairs(getRosterCache()) do
		if not m.isPet and m.class == class then
			return unit, m
		end
	end
	return nil
end

local function classMembers(class)
	local list = {}
	for unit, m in pairs(getRosterCache()) do
		if not m.isPet and m.class == class then
			list[#list + 1] = { unit = unit, name = m.name }
		end
	end
	return list
end

-- ============================================================
-- Grid data helpers: who gets a row, class-wide coverage ("does every
-- member of this class actually have it"), pet coverage, aura coverage,
-- and comm sync status. All layered on the getX() wrappers above so
-- debugMode stays consistent everywhere.
-- ============================================================

local function unitRemaining(unit, blessingId)
	local record = getTrackStateFor(unit)[blessingId]
	if not record or not record.expires then return nil end
	local remaining = record.expires - GetTime()
	if remaining <= 0 then return nil end
	return remaining
end

-- Full-class coverage, NOT just the one representative unit the secure
-- attribute targets -- this is what a green tile border means: every live
-- member of the class currently holds the blessing, from ANY caster.
local function classCoverage(class, blessingId)
	local members = classMembers(class)
	if #members == 0 or not blessingId then return false end
	for _, mem in ipairs(members) do
		if not unitRemaining(mem.unit, blessingId) then
			return false
		end
	end
	return true
end

local function petOverridesFor(paladinName)
	local assignment = getAssignment()
	local list = {}
	if not assignment then return list end
	for _, o in ipairs(assignment.overrides or {}) do
		if o.reason == "pet" and o.caster == paladinName then
			list[#list + 1] = o
		end
	end
	return list
end

-- Pet blessings are always normal-rank (greaters never reach pets, spec
-- 3.2), so there's one flat set of overrides to check, not a
-- greater/normal split. Returns nil if this paladin has no pets assigned
-- at all (the common case for every row except the salv carrier).
local function petCoverage(paladinName)
	local overrides = petOverridesFor(paladinName)
	if #overrides == 0 then return nil end
	local blessing = overrides[1].blessing
	local mixed, complete, minRemaining = false, true, nil
	for _, o in ipairs(overrides) do
		if o.blessing ~= blessing then mixed = true end
		local remaining = unitRemaining(o.target, o.blessing)
		if not remaining then
			complete = false
		elseif not minRemaining or remaining < minRemaining then
			minRemaining = remaining
		end
	end
	return { blessing = blessing, mixed = mixed, complete = complete, minRemaining = minRemaining, count = #overrides }
end

-- Auras are self-cast and have no fixed duration table (indefinite while
-- active, not on a spec 4-style timer) -- `indefinite=true` distinguishes
-- "on and has no timer" from "on with a countdown" for the caller.
local function auraCoverage(paladinName, auraId)
	if not auraId then return { complete = false } end
	local unit
	for u, m in pairs(getRosterCache()) do
		if not m.isPet and m.name == paladinName then
			unit = u
			break
		end
	end
	if not unit then return { complete = false } end
	local record = getTrackStateFor(unit)[auraId]
	if not record then return { complete = false } end
	if not record.expires or record.expires == 0 then
		return { complete = true, indefinite = true }
	end
	local remaining = record.expires - GetTime()
	if remaining <= 0 then return { complete = false } end
	return { complete = true, minRemaining = remaining }
end

-- Ordered row list: row 1 is always the local player (the compat-named
-- buttons live there), followed by every other paladin found in the
-- current plan or the live/synthetic roster, alphabetically.
local function paladinRowNames()
	local assignment = getAssignment()
	local myName = UnitName("player")
	local seen = { [myName] = true }
	local names = { myName }

	local others = {}
	local function consider(name)
		if name and not seen[name] then
			seen[name] = true
			others[#others + 1] = name
		end
	end
	if assignment then
		for casterName in pairs(assignment.greaters or {}) do consider(casterName) end
		for casterName in pairs(assignment.auras or {}) do consider(casterName) end
	end
	for _, m in ipairs(getRosterPaladins()) do consider(m.name) end

	table.sort(others)
	for _, n in ipairs(others) do names[#names + 1] = n end
	return names
end

local function petsDisplayEnabled()
	local profile = CBAB.DB:Profile()
	return profile ~= nil and profile.wants ~= nil and profile.wants.petsEnabled == true
end

-- Plain-text assignment summary for a paladin -- no longer shown inline on
-- the row (the expanded row header is now name + tag only, per the
-- reference design), but still needed for CBAB.PostReport's raid-chat
-- lines and worth keeping as a single source of truth for that wording.
local function paladinSummaryText(paladinName)
	local assignment = getAssignment()
	if not assignment then return "no assignment" end

	local seen, parts = {}, {}
	for _, blessing in pairs(assignment.greaters[paladinName] or {}) do
		if not seen[blessing] then
			seen[blessing] = true
			parts[#parts + 1] = "Greater " .. CBAB.Blessings[blessing].name
		end
	end

	local overrideCount = 0
	for _, o in ipairs(assignment.overrides or {}) do
		if o.caster == paladinName then overrideCount = overrideCount + 1 end
	end

	local text = (#parts > 0) and table.concat(parts, ", ") or "no greater slot"
	if overrideCount > 0 then
		text = text .. ("  +%d override(s)"):format(overrideCount)
	end
	local auraId = (assignment.auras or {})[paladinName]
	if auraId then
		text = text .. "  |  " .. CBAB.Auras[auraId].name
	end
	return text
end

-- ============================================================
-- Frame creation. RegisterForClicks("AnyDown") is required for the
-- `/click X LeftButton Down` macro form. Classic/TBC frames can call
-- SetBackdrop() directly without a BackdropTemplate (that requirement is
-- Legion+/retail only).
-- ============================================================

local bar = CreateFrame("Frame", "CBABuffBar", UIParent)
bar:SetMovable(true)
bar:SetResizable(false) -- resizing goes through the custom grip + SetScale, not native frame resize
bar:SetClampedToScreen(true)
bar:EnableMouse(true)
CBAB:ApplyBackdrop(bar, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
Theme.ApplyFill(bar, Theme.Colors.barFillTop, Theme.Colors.barFillBottom, 1)
Theme.ApplyDropShadow(bar, { pad = 12, yOffset = 8, alpha = 0.5 })
Theme.ApplyTopHairline(bar, Theme.Colors.gold)

local PADDING = 9
local BRAND_CHIP_SIZE = 20
local COMPACT_TILE = 44
local EXPANDED_TILE = 38
local BUTTON_GAP = 8
local DIVIDER_WIDTH = 1
local HEADER_ROW_HEIGHT = 15
local NAME_ROW_HEIGHT = 15
local TAG_ROW_HEIGHT = 11
local ROW_BLOCK_GAP = 5
local MANUAL_COLUMN_WIDTH = 60
local RESIZE_GRIP_SIZE = 12
local MIN_PILL_HEIGHT = 35
local BRAND_CLUSTER_WIDTH = 26 -- fixed-width left column for the dot+"CBA" label (compact/expanded)
local NAME_COL_WIDTH = 98

-- ============================================================
-- Drag: the whole bar is the drag surface now (README: the old
-- handle-square control is gone, "do not re-add" it). Buttons/cells
-- layered on top still get first claim on mouse events, so this only
-- fires from empty chrome -- the brand chip below gets it too, since it's
-- a plain (non-Button) texture region and won't intercept the drag.
-- ============================================================

local function startDrag()
	if CBAB.DB:Char().ui.bar.locked then return end
	bar:StartMoving()
end
local function stopDrag()
	bar:StopMovingOrSizing()
	local charDB = CBAB.DB:Char()
	local point, _, _, x, y = bar:GetPoint(1)
	charDB.ui.bar.point = point
	charDB.ui.bar.x = x
	charDB.ui.bar.y = y
end
bar:RegisterForDrag("LeftButton")
bar:SetScript("OnDragStart", startDrag)
bar:SetScript("OnDragStop", stopDrag)

-- Kept for Config.lua's "Locked" checkbox, which calls this after flipping
-- ui.bar.locked (spec: same lock wording/behaviour as before). The bar no
-- longer has its own visible lock button, but the drag gate above still
-- reads ui.bar.locked every time, so no visual refresh is actually needed
-- here -- kept as a safe no-op so Config.lua's existing call never errors.
function CBAB.Bar_RefreshChrome() end

-- ============================================================
-- Forward declarations: the chevron/brand chrome below needs these, but
-- their real bodies aren't defined until after the row pool exists.
-- ============================================================

local refreshGridStructure, refreshAssignment, refreshVisualState

-- ============================================================
-- Brand cluster: chip + status dot + vertical "CBA" label (README §1,
-- states 2a/2b/2d). WoW FontStrings can't rotate glyphs the way the
-- reference's `writing-mode: vertical-rl` does, so the vertical label is
-- approximated as three stacked lines instead of true rotated text.
-- ============================================================

local brandChip = CreateFrame("Frame", nil, bar)
brandChip:SetSize(BRAND_CHIP_SIZE, BRAND_CHIP_SIZE)
Theme.ApplyFill(brandChip, Theme.Colors.gold, Theme.Colors.goldDark, 0)
brandChip:EnableMouse(true)
brandChip:RegisterForDrag("LeftButton")
brandChip:SetScript("OnDragStart", startDrag)
brandChip:SetScript("OnDragStop", stopDrag)

local statusDot = bar:CreateTexture(nil, "OVERLAY")
statusDot:SetSize(8, 8)

local cbaLabel = bar:CreateFontString(nil, "OVERLAY")
Theme.StyleText(cbaLabel, "ColumnLabel", { color = "textFaint" })
cbaLabel:SetJustifyH("CENTER")
cbaLabel:SetText("C\nB\nA")
cbaLabel:SetSpacing(1)

local coverageText = bar:CreateFontString(nil, "OVERLAY")
Theme.StyleText(coverageText, "ButtonLabel")

local dividerA = bar:CreateTexture(nil, "ARTWORK")
dividerA:SetWidth(DIVIDER_WIDTH)
dividerA:SetColorTexture(Theme.Hex(Theme.Colors.divider))

local dividerB = bar:CreateTexture(nil, "ARTWORK")
dividerB:SetWidth(DIVIDER_WIDTH)
dividerB:SetColorTexture(Theme.Hex(Theme.Colors.divider))

brandChip:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("CBA Buff", 1, 1, 1)
	if debugMode then
		GameTooltip:AddLine("|cffff8800pbar debug mode|r", 1, 0.6, 0)
	end
	GameTooltip:Show()
end)
brandChip:SetScript("OnLeave", GameTooltip_Hide)

-- ============================================================
-- Chevron: cycles minimized -> compact -> expanded -> minimized.
-- ============================================================

local SIZE_CYCLE = { minimized = "compact", compact = "expanded", expanded = "minimized" }
local SIZE_TOOLTIP = { minimized = "Minimized", compact = "Your casts", expanded = "Expanded -- all paladins" }

local function currentSize()
	return CBAB.DB:Char().ui.bar.size or "compact"
end

local chevronButton = CreateFrame("Button", nil, bar)
CBAB:ApplyBackdrop(chevronButton, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
chevronButton:SetBackdropColor(Theme.Hex(Theme.Colors.controlFill))
chevronButton:SetBackdropBorderColor(Theme.Hex(Theme.Colors.borderControlAlt))
local chevronText = chevronButton:CreateFontString(nil, "OVERLAY")
chevronText:SetPoint("CENTER")
Theme.StyleText(chevronText, "ButtonLabel", { color = "textSecondary" })
chevronText:SetText("v")
Theme.ApplyInteractionState(chevronButton, chevronButton)

chevronButton:SetScript("OnClick", function()
	local charDB = CBAB.DB:Char()
	charDB.ui.bar.size = SIZE_CYCLE[currentSize()] or "compact"
	refreshGridStructure()
	refreshAssignment()
	refreshVisualState()
end)
chevronButton:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText(SIZE_TOOLTIP[currentSize()] or "Combat Strip")
	GameTooltip:AddLine("Click to cycle size", 0.7, 0.7, 0.7)
	GameTooltip:Show()
end)
chevronButton:SetScript("OnLeave", GameTooltip_Hide)

-- ============================================================
-- Resize grip: drag to change the bar's own scale (same value Config's
-- "Scale (%)" field edits).
-- ============================================================

local resizeGrip = CreateFrame("Button", nil, bar)
resizeGrip:SetSize(RESIZE_GRIP_SIZE, RESIZE_GRIP_SIZE)
resizeGrip:SetPoint("BOTTOMRIGHT", -2, 2)
resizeGrip.tex = resizeGrip:CreateTexture(nil, "OVERLAY")
resizeGrip.tex:SetAllPoints()
resizeGrip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")

resizeGrip:SetScript("OnMouseDown", function(self)
	if CBAB.DB:Char().ui.bar.locked then return end
	self.dragging = true
	self.startX = select(1, GetCursorPosition())
	self.startScale = bar:GetScale()
end)
resizeGrip:SetScript("OnMouseUp", function(self)
	self.dragging = false
	CBAB.DB:Char().ui.bar.scale = bar:GetScale()
end)
resizeGrip:SetScript("OnUpdate", function(self)
	if not self.dragging then return end
	local x = select(1, GetCursorPosition())
	local dx = (x - self.startX) / UIParent:GetEffectiveScale()
	local newScale = math.max(0.5, math.min(2.0, self.startScale + dx / 200))
	bar:SetScale(newScale)
end)

-- ============================================================
-- Grid anchor: everything below the brand cluster is laid out fresh on
-- every refresh pass (row count, column count, and tile size all change
-- with state), using an absolute cursor from this anchor.
-- ============================================================

local gridAnchor = CreateFrame("Frame", nil, bar)
gridAnchor:SetSize(1, 1)

local STATUS_GOOD = "teal"
local STATUS_WARN = "gold"
local STATUS_MISSING = "red"
local STATUS_NEUTRAL = "borderControlAlt"

local function statusColor(key)
	if key == "teal" then return Theme.Hex(Theme.Colors.teal) end
	if key == "gold" then return Theme.Hex(Theme.Colors.gold) end
	if key == "red" then return Theme.Hex(Theme.Colors.red) end
	return Theme.Hex(Theme.Colors[key])
end

-- ============================================================
-- Cell builder: one secure button per (row, column). Click semantics --
-- class cells are nocombat-gated macros (spec 11.2, same as before);
-- pets/aura cells are plain spell attributes, always clickable like the
-- popout buttons, since they're single-target or self-target rather than
-- class-wide. Every LIVE cell (row 1, or any row while expanded is self)
-- casts using the CLICKING player's own spellbook (see spellNameFor above)
-- -- the row only determines WHICH blessing/aura gets requested, never who
-- casts it. Non-self rows in the expanded view are read-only coverage
-- (README: "only Bakalmao (you) is clickable") -- their cells still show
-- real status/tooltip, but never receive spell/macro attributes, so a
-- click on them is a harmless no-op. That's the one functional change
-- from the pre-redesign grid, where every row's cells cast identically
-- regardless of whose row it was under.
-- ============================================================

local cellSerial = 0

local function attachCheckmark(cell)
	local tex = cell:CreateTexture(nil, "OVERLAY")
	tex:SetSize(10, 10)
	tex:SetPoint("BOTTOMRIGHT", 1, -1)
	tex:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
	tex:Hide()
	cell.checkTex = tex
end

local function attachTooltip(cell)
	cell:SetScript("OnEnter", function(self)
		if not self.tooltipLines or #self.tooltipLines == 0 then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		for i, line in ipairs(self.tooltipLines) do
			if i == 1 then
				GameTooltip:SetText(line, 1, 1, 1)
			else
				GameTooltip:AddLine(line, 0.9, 0.9, 0.9)
			end
		end
		GameTooltip:Show()
	end)
	cell:SetScript("OnLeave", GameTooltip_Hide)
end

-- Forward-declared: the shared edit dropdown is built after the row
-- pooling functions below (it needs CBAB.BlessingOrder/AuraOrder only,
-- but is kept next to the row code it serves for readability).
local openGridEdit

local function bindShiftRefresh(cell)
	cell:HookScript("OnClick", function(self, mouseButton)
		if IsShiftKeyDown() then
			refreshVisualState()
		end
	end)
end

local function attachEditOverlay(cell, kind)
	local overlay = CreateFrame("Button", nil, cell)
	overlay:SetAllPoints(cell)
	overlay:SetFrameLevel(cell:GetFrameLevel() + 5)
	overlay:Hide()
	overlay.kind = kind
	overlay:SetScript("OnClick", function(self)
		openGridEdit(self, self.paladinName, self.kind, self.class)
	end)
	local tex = overlay:CreateTexture(nil, "OVERLAY")
	tex:SetAllPoints()
	tex:SetColorTexture(0.2, 0.6, 1, 0.35)
	cell.editOverlay = overlay
end

-- kind: "class" | "pets" | "aura". Pooled (never destroyed), pooling
-- naming uses a running serial rather than PallyPower-reserved names --
-- compat is scoped to the C1-C9 set only (spec 11.2).
local function createCell(parent, kind)
	cellSerial = cellSerial + 1
	local btn = CreateFrame("Button", "CBABuffGridCell" .. cellSerial, parent, "SecureActionButtonTemplate")
	btn:RegisterForClicks("AnyDown")
	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetPoint("TOPLEFT", 3, -3)
	btn.icon:SetPoint("BOTTOMRIGHT", -3, 3)
	btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	CBAB:ApplyBackdrop(btn, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	btn:SetBackdropColor(Theme.HexA(Theme.Colors.tileDark, 0.5))
	btn:SetBackdropBorderColor(statusColor(STATUS_NEUTRAL))
	btn.cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
	btn.cooldown:SetAllPoints()
	btn.cooldown:SetHideCountdownNumbers(false)
	attachCheckmark(btn)
	attachTooltip(btn)
	attachEditOverlay(btn, kind)
	bindShiftRefresh(btn)
	Theme.ApplyInteractionState(btn, btn.icon)
	return btn
end

-- ============================================================
-- Row 1 -- the local player. Class cells MUST be the PallyPowerC1..9
-- compat buttons (spec 11.2); pets/aura cells are ordinary pooled cells.
-- Row 1 additionally keeps the popout behaviour (single-target buttons on
-- hover) -- see CBAB.Bar_ShowPopout further down -- so its class cells get
-- their OWN OnEnter/OnLeave instead of attachTooltip's generic one.
-- ============================================================

local classButtons = {}
for i = 1, 9 do
	local btn = CreateFrame("Button", "PallyPowerC" .. i, bar, "SecureActionButtonTemplate")
	btn:RegisterForClicks("AnyDown")

	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetPoint("TOPLEFT", 3, -3)
	btn.icon:SetPoint("BOTTOMRIGHT", -3, 3)
	btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	CBAB:ApplyBackdrop(btn, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	btn:SetBackdropColor(Theme.HexA(Theme.Colors.tileDark, 0.5))
	btn:SetBackdropBorderColor(statusColor(STATUS_NEUTRAL))

	btn.cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
	btn.cooldown:SetAllPoints()
	btn.cooldown:SetHideCountdownNumbers(false)

	attachCheckmark(btn)
	attachEditOverlay(btn, "class")
	bindShiftRefresh(btn)
	Theme.ApplyInteractionState(btn, btn.icon)

	btn:SetScript("OnEnter", function(self) CBAB.Bar_ShowPopout(self) end)
	btn:SetScript("OnLeave", function(self) CBAB.Bar_ScheduleHidePopout(self) end)

	classButtons[i] = btn
end

local selfPetsCell = createCell(bar, "pets")
local selfAuraCell = createCell(bar, "aura")

-- Shared class-header row (expanded state only, README §2d): one
-- FontString per populated column, pooled by index like everything else.
local classHeaderLabels = {}
local function getClassHeaderLabel(index)
	local fs = classHeaderLabels[index]
	if not fs then
		fs = bar:CreateFontString(nil, "OVERLAY")
		Theme.StyleText(fs, "ColumnLabel")
		fs:SetJustifyH("CENTER")
		classHeaderLabels[index] = fs
	end
	return fs
end

-- Small persistent column labels above the Pets/Aura cells (this addon's
-- own extension beyond the pure reference design, which has no pet/aura
-- concept) -- kept in both compact and expanded states so the column is
-- still identifiable without the full class-header row.
local petsLabel = bar:CreateFontString(nil, "OVERLAY")
Theme.StyleText(petsLabel, "ColumnLabel", { color = "textFaint" })
petsLabel:SetText("PETS")
local auraLabel = bar:CreateFontString(nil, "OVERLAY")
Theme.StyleText(auraLabel, "ColumnLabel", { color = "textFaint" })
auraLabel:SetText("AURA")

-- ============================================================
-- Row header widgets: name + tag, assignment summary line, and the
-- per-row Manual-override checkbox. Only shown in the expanded state
-- (README: the compact "your casts" pill has no room/need for them --
-- it's just tiles). Shared builder for row 1 and every pooled row below.
-- ============================================================

local function createRowHeader(parent)
	local nameText = parent:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(nameText, "Name")
	nameText:SetJustifyH("LEFT")

	local tagText = parent:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(tagText, "ColumnLabel", { color = "textFaint" })
	tagText:SetJustifyH("LEFT")

	local summaryText = parent:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(summaryText, "Body", { color = "textMuted" })
	summaryText:SetJustifyH("LEFT")
	summaryText:SetWordWrap(false)

	local manualButton = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	manualButton:SetSize(16, 16)

	local manualLabel = parent:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(manualLabel, "ColumnLabel", { color = "textFaint" })
	manualLabel:SetText("manual")

	return nameText, tagText, summaryText, manualButton, manualLabel
end

-- ============================================================
-- Row pool. Row 1 wraps the compat buttons above into the same shape
-- every other row uses, so the refresh/layout passes below can treat all
-- rows uniformly. Rows 2+ are created on demand and never destroyed --
-- unused rows are hidden, not freed, same pooling convention as the
-- popout buttons further down.
-- ============================================================

-- Whether the local viewer is allowed to toggle Manual for this row: any
-- paladin may edit their OWN assignment (spec 8's "local override" right),
-- while editing someone ELSE's row is a coordinator-only plan edit. Manual
-- editing is only ever offered in the expanded state (see refreshGridStructure).
local function canEditRow(row)
	return row.paladinName == UnitName("player") or CBAB:Mode().coordinator
end

local function applyManualVisibility(row, expanded)
	local show = expanded and row.manualMode and canEditRow(row)
	for _, cell in pairs(row.cells) do
		if cell.editOverlay then cell.editOverlay:SetShown(show) end
	end
end

local function bindManualToggle(row)
	row.manualButton:SetScript("OnClick", function(self)
		row.manualMode = self:GetChecked() and true or false
		applyManualVisibility(row, currentSize() == "expanded")
	end)
end

local row1 = { cells = {} }
for i = 1, 9 do row1.cells[i] = classButtons[i] end
row1.cells.pets = selfPetsCell
row1.cells.aura = selfAuraCell
row1.nameText, row1.tagText, row1.summaryText, row1.manualButton, row1.manualLabel = createRowHeader(bar)
bindManualToggle(row1)

local gridRows = { [1] = row1 }

local function createGridRow(index)
	local row = { cells = {} }
	for i = 1, 9 do row.cells[i] = createCell(bar, "class") end
	row.cells.pets = createCell(bar, "pets")
	row.cells.aura = createCell(bar, "aura")
	row.nameText, row.tagText, row.summaryText, row.manualButton, row.manualLabel = createRowHeader(bar)
	bindManualToggle(row)
	return row
end

local function getGridRow(index)
	local row = gridRows[index]
	if not row then
		row = createGridRow(index)
		gridRows[index] = row
	end
	return row
end

-- ============================================================
-- Manual-override edit dropdown: ONE shared UIDropDownMenuTemplate,
-- retargeted per click via `pendingEdit` rather than one dropdown per
-- cell. Writes straight to profile.assignment, the same table Solve.lua
-- and UI/RosterPage.lua already write to directly. Editing your OWN row
-- (paladinName == UnitName("player")) marks the change a spec 8 "local
-- override"; editing someone else's row is a coordinator plan edit that
-- travels on the next Solve/Push cycle, not its own epoch bump.
-- ============================================================

local gridEditDropdown = CreateFrame("Frame", "CBABuffGridEditDropdown", bar, "UIDropDownMenuTemplate")
UIDropDownMenu_SetWidth(gridEditDropdown, 120)

local pendingEdit

local function applyGridEdit(key)
	local profile = CBAB.DB:Profile()
	if not profile or not profile.assignment or not pendingEdit then return end
	local a = profile.assignment
	a.overrides = a.overrides or {}
	a.auras = a.auras or {}

	if pendingEdit.kind == "class" then
		a.greaters[pendingEdit.paladinName] = a.greaters[pendingEdit.paladinName] or {}
		a.greaters[pendingEdit.paladinName][pendingEdit.class] = key
	elseif pendingEdit.kind == "pets" then
		local kept = {}
		for _, o in ipairs(a.overrides) do
			if o.reason ~= "pet" or o.caster ~= pendingEdit.paladinName then
				kept[#kept + 1] = o
			end
		end
		if key then
			for _, pet in ipairs(CBAB.Roster:HunterPets()) do
				kept[#kept + 1] = { caster = pendingEdit.paladinName, target = pet.unit, blessing = key, reason = "pet", owner = pet.owner }
			end
		end
		a.overrides = kept
	elseif pendingEdit.kind == "aura" then
		a.auras[pendingEdit.paladinName] = key
	end

	if pendingEdit.paladinName == UnitName("player") then
		a.source = "local"
		a.localRevision = (a.localRevision or 0) + 1
	end

	profile.modified = time()
	CBAB:Fire("ASSIGNMENT_CHANGED")
end

UIDropDownMenu_Initialize(gridEditDropdown, function(self, level)
	local clearInfo = UIDropDownMenu_CreateInfo()
	clearInfo.text = "Clear"
	clearInfo.func = function() applyGridEdit(nil) end
	UIDropDownMenu_AddButton(clearInfo, level)

	local order = (pendingEdit and pendingEdit.kind == "aura") and CBAB.AuraOrder or CBAB.BlessingOrder
	local data = (pendingEdit and pendingEdit.kind == "aura") and CBAB.Auras or CBAB.Blessings
	for _, key in ipairs(order) do
		local info = UIDropDownMenu_CreateInfo()
		info.text = data[key].name
		info.func = function() applyGridEdit(key) end
		UIDropDownMenu_AddButton(info, level)
	end
end)

openGridEdit = function(anchorFrame, paladinName, kind, class)
	if not paladinName then return end
	pendingEdit = { paladinName = paladinName, kind = kind, class = class }
	ToggleDropDownMenu(1, nil, gridEditDropdown, anchorFrame, 0, 0)
end

-- ============================================================
-- Assignment pass: secure attributes + icon + tinted fill + editOverlay
-- targeting, for every cell in every active row. Class buttons must be
-- blocked in combat (spec 11.2, `[nocombat]`); pets/aura cells stay
-- castable in combat, same as the popout buttons (they're single/self-
-- target, not class-wide). `isLive` gates whether real spell/macro
-- attributes get written at all -- false for every non-self row in the
-- expanded state (see the cell-builder comment above for why).
-- ============================================================

local function applyBlessingFill(cell, blessingId)
	local tint = blessingId and Theme.BlessingTint(blessingId)
	if tint then
		cell:SetBackdropColor(tint.fill[1], tint.fill[2], tint.fill[3], 1)
	else
		cell:SetBackdropColor(Theme.HexA(Theme.Colors.tileDark, 0.5))
	end
end

local function buildClassMacro(spellName, unit)
	if not spellName or not unit then
		return "/cast" -- no spell/target assigned: a harmless no-op
	end
	return ("/cast [nocombat,@%s] %s"):format(unit, spellName)
end

local function setClassCell(cell, paladinName, class, isLive)
	local assignment = getAssignment()
	local blessing = assignment and assignment.greaters[paladinName] and assignment.greaters[paladinName][class]
	cell.assignedKey = blessing
	cell.icon:SetTexture(blessing and CBAB.Blessings[blessing].texture or nil)
	applyBlessingFill(cell, blessing)

	if isLive then
		local unit = representativeUnit(class)
		setAttributeSafe(cell, "type1", "macro")
		setAttributeSafe(cell, "macrotext1", buildClassMacro(blessing and spellNameFor(blessing, true), unit))
		setAttributeSafe(cell, "type2", "macro")
		setAttributeSafe(cell, "macrotext2", buildClassMacro(blessing and spellNameFor(blessing, false), "target"))
	else
		setAttributeSafe(cell, "type1", nil)
		setAttributeSafe(cell, "macrotext1", nil)
		setAttributeSafe(cell, "type2", nil)
		setAttributeSafe(cell, "macrotext2", nil)
	end

	cell.editOverlay.paladinName = paladinName
	cell.editOverlay.class = class
end

local function setPetsCell(cell, paladinName, isLive)
	local coverage = petCoverage(paladinName)
	local blessing = coverage and coverage.blessing
	cell.assignedKey = blessing
	cell.icon:SetTexture(blessing and CBAB.Blessings[blessing].texture or nil)
	applyBlessingFill(cell, blessing)

	if isLive then
		local firstPet = petOverridesFor(paladinName)[1]
		setAttributeSafe(cell, "type1", "spell")
		setAttributeSafe(cell, "spell1", blessing and spellNameFor(blessing, false) or nil)
		setAttributeSafe(cell, "unit1", firstPet and firstPet.target or nil)
		setAttributeSafe(cell, "type2", "spell")
		setAttributeSafe(cell, "spell2", blessing and spellNameFor(blessing, false) or nil)
		setAttributeSafe(cell, "unit2", "target")
	else
		setAttributeSafe(cell, "type1", nil)
		setAttributeSafe(cell, "spell1", nil)
		setAttributeSafe(cell, "unit1", nil)
		setAttributeSafe(cell, "type2", nil)
		setAttributeSafe(cell, "spell2", nil)
		setAttributeSafe(cell, "unit2", nil)
	end

	cell.editOverlay.paladinName = paladinName
end

local function setAuraCell(cell, paladinName, isLive)
	local assignment = getAssignment()
	local auraId = assignment and (assignment.auras or {})[paladinName]
	cell.assignedKey = auraId
	cell.icon:SetTexture(auraId and CBAB.Auras[auraId].texture or nil)
	applyBlessingFill(cell, nil) -- auras have no blessing color; keep the neutral tile look

	if isLive then
		setAttributeSafe(cell, "type1", "spell")
		setAttributeSafe(cell, "spell1", auraId and auraSpellNameFor(auraId) or nil)
		setAttributeSafe(cell, "unit1", "player")
	else
		setAttributeSafe(cell, "type1", nil)
		setAttributeSafe(cell, "spell1", nil)
		setAttributeSafe(cell, "unit1", nil)
	end

	cell.editOverlay.paladinName = paladinName
end

-- currentLayout: [buttonIndex] = classToken, refreshed by refreshGridStructure
-- below and read here every assignment/visual pass.
local currentLayout = {}

refreshAssignment = function()
	local myName = UnitName("player")
	local expanded = currentSize() == "expanded"
	for index, row in pairs(gridRows) do
		if row.paladinName then
			local isLive = (row.paladinName == myName) or not expanded
			for slot, class in pairs(currentLayout) do
				setClassCell(row.cells[slot], row.paladinName, class, isLive)
			end
			setPetsCell(row.cells.pets, row.paladinName, isLive)
			setAuraCell(row.cells.aura, row.paladinName, isLive)
		end
	end
end

-- ============================================================
-- Visual pass: border colour (missing/expiring/good, layered over the
-- blessing-tinted fill the assignment pass just set), the green check
-- overlay (full-class coverage, not just the one representative unit the
-- secure attribute targets), the Cooldown swipe/timer, and tooltip text.
-- Also tallies the minimized-state coverage pill from row 1's cells.
-- ============================================================

local minimizedTotal, minimizedCovered = 0, 0

local function clearCellVisual(cell)
	cell:SetBackdropBorderColor(statusColor(STATUS_NEUTRAL))
	cell.cooldown:Clear()
	cell.checkTex:Hide()
	cell.tooltipLines = nil
end

local function applyClassVisual(cell, paladinName, class, isSelf)
	local blessing = cell.assignedKey
	if not blessing then
		clearCellVisual(cell)
		cell.tooltipLines = { ("%s -> %s"):format(paladinName, classDisplayLabel(class)), "no greater assigned" }
		return
	end

	local complete = classCoverage(class, blessing)
	cell.checkTex:SetShown(complete)
	if isSelf then
		minimizedTotal = minimizedTotal + 1
		if complete then minimizedCovered = minimizedCovered + 1 end
	end

	local threshold = (CBAB.DB:Char().warnings or {}).threshold or 120
	local unit = representativeUnit(class)
	local record = unit and getTrackStateFor(unit)[blessing]
	local statusLine

	if not record then
		cell:SetBackdropBorderColor(statusColor(STATUS_MISSING))
		cell.cooldown:Clear()
		statusLine = "missing"
	else
		local remaining = (record.expires or 0) - GetTime()
		if remaining <= threshold then
			cell:SetBackdropBorderColor(statusColor(STATUS_WARN))
		else
			cell:SetBackdropBorderColor(statusColor(STATUS_GOOD))
		end
		if record.expires then
			local duration = record.isGreater and 1800 or 600
			cell.cooldown:SetCooldown(record.expires - duration, duration)
			statusLine = ("%ds remaining (representative member)"):format(math.max(0, math.floor(remaining)))
		end
	end

	cell.tooltipLines = {
		("%s -> %s"):format(paladinName, classDisplayLabel(class)),
		"Greater " .. CBAB.Blessings[blessing].name,
		complete and "|cff33ff33entire class covered|r" or "|cffff4444not all class members covered|r",
		statusLine,
	}
end

local function applyPetsVisual(cell, paladinName)
	local coverage = petCoverage(paladinName)
	if not coverage then
		clearCellVisual(cell)
		cell.tooltipLines = { paladinName .. " -> Pets", "no pets assigned" }
		return
	end

	cell.checkTex:SetShown(coverage.complete)
	local threshold = (CBAB.DB:Char().warnings or {}).threshold or 120

	if not coverage.minRemaining then
		cell:SetBackdropBorderColor(statusColor(STATUS_MISSING))
		cell.cooldown:Clear()
	else
		if coverage.minRemaining <= threshold then
			cell:SetBackdropBorderColor(statusColor(STATUS_WARN))
		else
			cell:SetBackdropBorderColor(statusColor(STATUS_GOOD))
		end
		cell.cooldown:SetCooldown(GetTime() + coverage.minRemaining - 600, 600)
	end

	cell.tooltipLines = {
		paladinName .. " -> Pets",
		("%s%s on %d pet(s)"):format(CBAB.Blessings[coverage.blessing].name, coverage.mixed and " (mixed)" or "", coverage.count),
		coverage.complete and "|cff33ff33all pets covered|r" or "|cffff4444missing on at least one pet|r",
	}
end

local function applyAuraVisual(cell, paladinName)
	local assignment = getAssignment()
	local auraId = assignment and (assignment.auras or {})[paladinName]
	if not auraId then
		clearCellVisual(cell)
		cell.tooltipLines = { paladinName .. " -> Aura", "no aura assigned" }
		return
	end

	local coverage = auraCoverage(paladinName, auraId)
	cell.checkTex:SetShown(coverage.complete)

	local statusLine
	if not coverage.complete then
		cell:SetBackdropBorderColor(statusColor(STATUS_MISSING))
		cell.cooldown:Clear()
		statusLine = "not active"
	elseif coverage.indefinite then
		cell:SetBackdropBorderColor(statusColor(STATUS_GOOD))
		cell.cooldown:Clear()
		statusLine = "active (no fixed duration)"
	else
		local threshold = (CBAB.DB:Char().warnings or {}).threshold or 120
		if coverage.minRemaining <= threshold then
			cell:SetBackdropBorderColor(statusColor(STATUS_WARN))
		else
			cell:SetBackdropBorderColor(statusColor(STATUS_GOOD))
		end
		statusLine = ("%ds remaining"):format(math.max(0, math.floor(coverage.minRemaining)))
	end

	cell.tooltipLines = { paladinName .. " -> Aura", CBAB.Auras[auraId].name, statusLine }
end

-- Updates the coverage pill's text/color/border and, when the bar is
-- actually in the minimized state, its width -- called from both
-- refreshGridStructure (initial layout) and refreshVisualState (every
-- BUFF_STATE_CHANGED tick). Doing the resize here rather than only in
-- refreshGridStructure matters because BUFF_STATE_CHANGED -- a buff
-- falling off mid-raid, changing "8/8" to "1 gap" -- only calls
-- refreshVisualState, not the full structure pass; without this, the pill
-- would show stale/clipped text width until the next roster or assignment
-- change happened to also fire.
local function refreshCoveragePill()
	local gaps = minimizedTotal - minimizedCovered
	if minimizedTotal == 0 then
		coverageText:SetText("--")
		coverageText:SetTextColor(Theme.C("textFaint"))
		statusDot:SetColorTexture(Theme.Hex(Theme.Colors.textFaint))
	elseif gaps == 0 then
		coverageText:SetText(("%d/%d"):format(minimizedCovered, minimizedTotal))
		coverageText:SetTextColor(Theme.C("tealText"))
		statusDot:SetColorTexture(Theme.Hex(Theme.Colors.teal))
	else
		coverageText:SetText(("%d gap%s"):format(gaps, gaps == 1 and "" or "s"))
		coverageText:SetTextColor(Theme.C("redText"))
		statusDot:SetColorTexture(Theme.Hex(Theme.Colors.red))
	end
	bar:SetBackdropBorderColor(Theme.Hex(gaps > 0 and Theme.Colors.borderGaps or Theme.Colors.borderControl))

	if currentSize() == "minimized" then
		local contentWidth = PADDING + BRAND_CHIP_SIZE + 8 + 8 + 8 + coverageText:GetStringWidth()
			+ 8 + DIVIDER_WIDTH + 8 + 24 + PADDING
		bar:SetSize(contentWidth, MIN_PILL_HEIGHT)
	end
end

-- Assigns the upvalue forward-declared above (bindShiftRefresh already
-- closes over it), rather than `local function`, which would create a
-- second, shadowing local instead of filling in the forward reference.
refreshVisualState = function()
	local myName = UnitName("player")
	minimizedTotal, minimizedCovered = 0, 0
	for index, row in pairs(gridRows) do
		if row.paladinName then
			local isSelf = row.paladinName == myName
			for slot, class in pairs(currentLayout) do
				applyClassVisual(row.cells[slot], row.paladinName, class, isSelf)
			end
			applyPetsVisual(row.cells.pets, row.paladinName)
			applyAuraVisual(row.cells.aura, row.paladinName)
		end
	end
	refreshCoveragePill()
end

-- ============================================================
-- Structure pass: which paladins get a row, which classes get a column,
-- tile size, and the full layout for whichever of the three states is
-- active. Runs on both ROSTER_CHANGED (class columns can change) and
-- ASSIGNMENT_CHANGED (the row list itself is partly assignment-driven --
-- see paladinRowNames).
-- ============================================================

local function hideRow(row)
	row.paladinName = nil
	row.manualMode = false
	row.manualButton:SetChecked(false)
	row.nameText:Hide()
	row.tagText:Hide()
	row.summaryText:Hide()
	row.manualButton:Hide()
	row.manualLabel:Hide()
	for _, cell in pairs(row.cells) do
		cell:Hide()
		if cell.editOverlay then cell.editOverlay:Hide() end
	end
end

refreshGridStructure = function()
	currentLayout = computeClassLayout()
	local size = currentSize()
	local rowNames = paladinRowNames()
	local showPets = petsDisplayEnabled()
	local myName = UnitName("player")

	-- Brand cluster, common to every state.
	brandChip:ClearAllPoints()
	brandChip:SetPoint("TOPLEFT", PADDING, -PADDING)
	statusDot:ClearAllPoints()
	statusDot:SetPoint("LEFT", brandChip, "RIGHT", 8, 0)

	if size == "minimized" then
		-- Pill: chip + dot + coverage text + divider + chevron. No grid.
		brandChip:Show()
		for i = 1, #gridRows do hideRow(gridRows[i]) end
		for _, fs in pairs(classHeaderLabels) do fs:Hide() end
		petsLabel:Hide()
		auraLabel:Hide()
		cbaLabel:Hide()

		coverageText:ClearAllPoints()
		coverageText:SetPoint("LEFT", statusDot, "RIGHT", 8, 0)
		coverageText:Show()

		dividerA:ClearAllPoints()
		dividerA:SetPoint("LEFT", coverageText, "RIGHT", 8, 0)
		dividerA:SetHeight(20)
		dividerA:Show()
		dividerB:Hide()

		chevronButton:ClearAllPoints()
		chevronButton:SetPoint("LEFT", dividerA, "RIGHT", 8, 0)
		chevronButton:SetSize(24, 24)
		chevronButton:Show()
		chevronText:SetText("v")

		resizeGrip:Hide()
		refreshCoveragePill() -- also sizes the bar itself (see its own comment)
		return
	end

	resizeGrip:Show()
	coverageText:Hide()

	local expanded = (size == "expanded")
	local tileSize = expanded and EXPANDED_TILE or COMPACT_TILE
	-- Fixed Y for the top of the content row -- everything below anchors
	-- off `bar`/`gridAnchor`'s TOPLEFT with explicit offsets from here on,
	-- rather than chaining vertical-centering ("LEFT"-to-"LEFT") anchors
	-- through differently-sized neighbors. That matters because the total
	-- bar height computed at the bottom of this function assumes content
	-- starts exactly at rowTop -- a centered chain would silently drift
	-- that starting point depending on the brand cluster's own measured
	-- size and desync the height math for the (potentially very tall)
	-- expanded grid.
	local rowTop = -PADDING

	-- Brand cluster: dot above a stacked vertical "CBA" label, no chip
	-- (README §2b/2c/2d -- the gold chip is minimized-only, see the
	-- minimized branch above). Fixed-width column so nothing below depends
	-- on this cluster's own measured text size.
	brandChip:Hide()
	local clusterCenterY = rowTop - tileSize / 2
	statusDot:ClearAllPoints()
	statusDot:SetPoint("CENTER", bar, "TOPLEFT", PADDING + BRAND_CLUSTER_WIDTH / 2, clusterCenterY + 8)
	cbaLabel:ClearAllPoints()
	cbaLabel:SetPoint("CENTER", bar, "TOPLEFT", PADDING + BRAND_CLUSTER_WIDTH / 2, clusterCenterY - 6)
	cbaLabel:Show()

	dividerA:ClearAllPoints()
	dividerA:SetPoint("TOPLEFT", bar, "TOPLEFT", PADDING + BRAND_CLUSTER_WIDTH, rowTop)
	dividerA:SetHeight(tileSize)
	dividerA:Show()

	-- Column x-offsets, shared by every row, measured from the grid anchor
	-- (just right of the first divider, pinned to rowTop).
	gridAnchor:ClearAllPoints()
	gridAnchor:SetPoint("TOPLEFT", dividerA, "TOPRIGHT", 10, 0)

	local columnX, x = {}, 0
	for i = 1, 9 do
		if currentLayout[i] then
			columnX[i] = x
			x = x + tileSize + BUTTON_GAP
		end
	end
	local petsX
	if showPets then
		petsX = x
		x = x + tileSize + BUTTON_GAP
	end
	local auraX = x
	local gridContentWidth = x + tileSize

	dividerB:ClearAllPoints()
	dividerB:SetHeight(tileSize)

	-- Manual column only exists in the expanded state.
	local manualWidth = expanded and MANUAL_COLUMN_WIDTH or 0
	local headerY = 0

	if expanded then
		-- Class-header row: one label per populated column, indented past
		-- the name column (README §2d: "indented 104px to clear the name
		-- column" -- 98px name width here, so a matching indent).
		for i = 1, 9 do
			local fs = getClassHeaderLabel(i)
			if currentLayout[i] then
				fs:SetText(CLASS_ABBR[currentLayout[i]])
				fs:SetTextColor(Theme.ClassColor(currentLayout[i]))
				fs:SetWidth(tileSize)
				fs:ClearAllPoints()
				fs:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", NAME_COL_WIDTH + columnX[i], headerY)
				fs:Show()
			else
				fs:Hide()
			end
		end
		headerY = headerY - HEADER_ROW_HEIGHT - 2
	else
		for _, fs in pairs(classHeaderLabels) do fs:Hide() end
	end

	petsLabel:ClearAllPoints()
	auraLabel:ClearAllPoints()
	if showPets then
		petsLabel:SetWidth(tileSize)
		petsLabel:SetJustifyH("CENTER")
		petsLabel:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", (expanded and NAME_COL_WIDTH or 0) + petsX, headerY)
		petsLabel:Show()
	else
		petsLabel:Hide()
	end
	auraLabel:SetWidth(tileSize)
	auraLabel:SetJustifyH("CENTER")
	auraLabel:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", (expanded and NAME_COL_WIDTH or 0) + auraX, headerY)
	auraLabel:Show()
	if expanded then headerY = headerY - HEADER_ROW_HEIGHT end

	local rowsToShow = expanded and rowNames or { rowNames[1] }
	local y = headerY
	for i, paladinName in ipairs(rowsToShow) do
		local row = getGridRow(i)
		row.paladinName = paladinName
		local isSelf = paladinName == myName

		if expanded then
			row.nameText:ClearAllPoints()
			row.nameText:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", 0, y)
			row.nameText:SetTextColor(Theme.ClassColor("PALADIN"))
			row.nameText:SetText(paladinName)
			row.nameText:Show()

			row.tagText:ClearAllPoints()
			row.tagText:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", 0, y - NAME_ROW_HEIGHT)
			row.tagText:SetText(isSelf and "you . live" or "read-only")
			row.tagText:Show()

			local canEdit = canEditRow(row)
			row.manualButton:ClearAllPoints()
			row.manualButton:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", NAME_COL_WIDTH + gridContentWidth + 10, y)
			row.manualButton:SetEnabled(canEdit)
			if not canEdit then
				row.manualMode = false
				row.manualButton:SetChecked(false)
			end
			row.manualButton:Show()
			row.manualLabel:ClearAllPoints()
			row.manualLabel:SetPoint("LEFT", row.manualButton, "RIGHT", 2, 0)
			row.manualLabel:Show()
			applyManualVisibility(row, true)

			row.summaryText:ClearAllPoints()
			row.summaryText:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", 0, y - NAME_ROW_HEIGHT - TAG_ROW_HEIGHT)
			row.summaryText:Hide() -- name/tag replace the old summary line in the expanded row header
		else
			row.nameText:Hide()
			row.tagText:Hide()
			row.summaryText:Hide()
			row.manualButton:Hide()
			row.manualLabel:Hide()
			applyManualVisibility(row, false)
		end

		local cellY = expanded and (y - NAME_ROW_HEIGHT - TAG_ROW_HEIGHT - 2) or y
		local nameColOffset = expanded and NAME_COL_WIDTH or 0

		for slot = 1, 9 do
			local cell = row.cells[slot]
			cell:ClearAllPoints()
			if currentLayout[slot] then
				cell.class = currentLayout[slot]
				cell:SetSize(tileSize, tileSize)
				cell:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", nameColOffset + columnX[slot], cellY)
				cell:Show()
			else
				cell.class = nil
				cell:Hide()
			end
		end

		row.cells.pets:ClearAllPoints()
		row.cells.pets:SetSize(tileSize, tileSize)
		if showPets then
			row.cells.pets:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", nameColOffset + petsX, cellY)
			row.cells.pets:Show()
		else
			row.cells.pets:Hide()
		end

		row.cells.aura:ClearAllPoints()
		row.cells.aura:SetSize(tileSize, tileSize)
		row.cells.aura:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", nameColOffset + auraX, cellY)
		row.cells.aura:Show()

		-- Non-self rows in the expanded view read as coverage only --
		-- dimmed to match README's opacity ~.62 on those rows.
		local rowAlpha = (expanded and not isSelf) and 0.62 or 1
		for _, cell in pairs(row.cells) do cell:SetAlpha(rowAlpha) end
		row.nameText:SetAlpha(rowAlpha)
		row.tagText:SetAlpha(rowAlpha)

		if expanded then
			y = y - NAME_ROW_HEIGHT - TAG_ROW_HEIGHT - tileSize - ROW_BLOCK_GAP
		else
			y = y - tileSize
		end
	end

	for i = #rowsToShow + 1, #gridRows do
		hideRow(gridRows[i])
	end

	local rightContentWidth = gridContentWidth + (expanded and NAME_COL_WIDTH or 0) + manualWidth
	dividerB:ClearAllPoints()
	dividerB:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", rightContentWidth + 10, 0)
	if not expanded then
		dividerB:Show()
		chevronButton:ClearAllPoints()
		chevronButton:SetPoint("LEFT", dividerB, "RIGHT", 10, 0)
		chevronButton:SetSize(30, tileSize)
	else
		dividerB:Hide()
		chevronButton:ClearAllPoints()
		chevronButton:SetPoint("TOPRIGHT", -PADDING, -PADDING)
		chevronButton:SetSize(26, 22)
	end
	chevronButton:Show()
	chevronText:SetText(expanded and "^" or "v")

	-- Both formulas assume content starts exactly at rowTop (= -PADDING) --
	-- true by construction now that the brand cluster is a fixed-width
	-- column and gridAnchor is pinned via TOPLEFT rather than centered
	-- against it (see the comment above rowTop's declaration).
	local totalWidth = PADDING + BRAND_CLUSTER_WIDTH + DIVIDER_WIDTH + 10 + rightContentWidth + 10 + PADDING
	if not expanded then
		totalWidth = totalWidth + DIVIDER_WIDTH + 10 + 30
	end
	local totalHeight = PADDING + (expanded and (-y) or tileSize) + PADDING

	bar:SetSize(math.max(totalWidth, MIN_PILL_HEIGHT * 3), math.max(totalHeight, MIN_PILL_HEIGHT))
end

-- ============================================================
-- Popout player buttons for single-target casts (spec 11.2). Row 1 (the
-- local player) only -- other rows show their per-class summary via the
-- grid cell's own tooltip instead.
-- ============================================================

local popoutButtons = {}

local function getPopoutButton(index)
	local btn = popoutButtons[index]
	if not btn then
		btn = CreateFrame("Button", "CBABuffPopout" .. index, bar, "SecureActionButtonTemplate")
		btn:RegisterForClicks("AnyDown")
		btn.icon = btn:CreateTexture(nil, "ARTWORK")
		btn.icon:SetAllPoints()
		CBAB:ApplyBackdrop(btn, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
		btn:SetBackdropBorderColor(Theme.Hex(Theme.Colors.borderControlAlt))
		popoutButtons[index] = btn
	end
	return btn
end

function CBAB.Bar_ShowPopout(classButton)
	if not classButton.class or not classButton:IsShown() then return end

	local myName = UnitName("player")
	local assignment = getAssignment()
	local members = {}
	for unit, m in pairs(getRosterCache()) do
		if not m.isPet and m.class == classButton.class then
			members[#members + 1] = { unit = unit, name = m.name }
		end
	end
	table.sort(members, function(a, b) return a.unit < b.unit end)

	local popSize = classButton:GetWidth() - 6
	for i, member in ipairs(members) do
		local btn = getPopoutButton(i)
		btn:SetSize(popSize, popSize)
		btn:ClearAllPoints()
		btn:SetPoint("BOTTOM", classButton, "TOP", 0, 4 + (i - 1) * (popSize + 2))
		btn:Show()

		local blessing
		if assignment then
			for _, o in ipairs(assignment.overrides or {}) do
				if o.caster == myName and o.target == member.name then
					blessing = o.blessing
					break
				end
			end
			if not blessing then
				blessing = assignment.greaters[myName] and assignment.greaters[myName][classButton.class]
			end
		end

		btn.icon:SetTexture(blessing and CBAB.Blessings[blessing].texture or nil)
		setAttributeSafe(btn, "type1", "spell")
		setAttributeSafe(btn, "spell1", blessing and spellNameFor(blessing, false) or nil)
		setAttributeSafe(btn, "unit1", member.unit)

		btn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(member.name)
			GameTooltip:Show()
			CBAB.Bar_ShowPopout(classButton)
		end)
		btn:SetScript("OnLeave", function()
			GameTooltip_Hide()
			CBAB.Bar_ScheduleHidePopout(classButton)
		end)
	end

	for i = #members + 1, #popoutButtons do
		popoutButtons[i]:Hide()
	end
end

function CBAB.Bar_ScheduleHidePopout()
	CBAB:After(0.4, function()
		for _, btn in ipairs(popoutButtons) do
			if btn:IsMouseOver() then return end
		end
		for _, cb in ipairs(classButtons) do
			if cb:IsMouseOver() then return end
		end
		for _, btn in ipairs(popoutButtons) do
			btn:Hide()
		end
	end)
end

-- ============================================================
-- Show/hide: Config's "Show bar" checkbox toggles this (the bar has no
-- visible close button of its own anymore, matching the reference
-- design's minimal chrome -- README: only brand/dot/tiles/chevron).
-- ============================================================

function CBAB.Bar_SetShown(shown)
	CBAB.DB:Char().ui.bar.shown = shown
	if shown then
		bar:Show()
	else
		bar:Hide()
	end
end

-- ============================================================
-- Position / lock / scale from CBABuffCharDB.ui.bar, and PallyPower
-- collision warning (spec 11.2). Both wait for DB:Init() via ADDON_LOADED.
-- ============================================================

local function applySavedPosition()
	local ui = CBAB.DB:Char().ui.bar
	bar:ClearAllPoints()
	bar:SetPoint(ui.point or "CENTER", UIParent, ui.point or "CENTER", ui.x or 0, ui.y or -180)
	bar:SetScale(ui.scale or 1.0)
	-- Full refresh immediately at ADDON_LOADED rather than waiting for the
	-- first ROSTER_CHANGED, so the bar's chrome is visible even before any
	-- group exists.
	refreshGridStructure()
	refreshAssignment()
	refreshVisualState()
	CBAB.Bar_SetShown(ui.shown ~= false)
end

-- Renamed to C_AddOns.IsAddOnLoaded on some clients, same family as
-- GetAddOnMetadata (Core.lua) -- resolved once, not just guarded.
local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded

local function checkPallyPowerCollision()
	local isLoaded = IsAddOnLoaded and IsAddOnLoaded("PallyPower")
	if not isLoaded then return end

	local charDB = CBAB.DB:Char()
	if charDB.warnedPallyPowerCollision then return end
	charDB.warnedPallyPowerCollision = true

	StaticPopupDialogs["CBAB_PALLYPOWER_COLLISION"] = {
		text = "CBA Buff and PallyPower are both loaded. Both addons use the same "
			.. "secure button names (PallyPowerC1-C9) for macro compatibility, so "
			.. "raid macros clicking those names will behave unpredictably with "
			.. "both active. Disable one.",
		button1 = OKAY or "OK",
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
	}
	StaticPopup_Show("CBAB_PALLYPOWER_COLLISION")
end

CBAB:On("ADDON_LOADED", "bar:init", function(loadedAddon)
	if loadedAddon ~= ADDON then return end
	applySavedPosition()
	checkPallyPowerCollision()
	CBAB:Off("ADDON_LOADED", "bar:init")
end)

CBAB:On("ROSTER_CHANGED", "bar:roster", function()
	refreshGridStructure()
	refreshAssignment()
	refreshVisualState()
end)
CBAB:On("ASSIGNMENT_CHANGED", "bar:assignment", function()
	refreshGridStructure()
	refreshAssignment()
	refreshVisualState()
end)
CBAB:On("BUFF_STATE_CHANGED", "bar:buffstate", function()
	refreshVisualState()
end)

-- Class cells are blocked in combat via the `[nocombat]` macro conditional
-- baked into their macrotext (buildClassMacro above) -- not a runtime
-- attribute toggle, which secure attributes don't allow at the moment
-- combat actually starts. Pets/aura/popout attributes have no such guard,
-- so they stay usable in combat (spec 11.2).
CBAB:On("PLAYER_REGEN_ENABLED", "bar:combat-unlock", function()
	refreshAssignment()
end)

-- ============================================================
-- /cbab pbar: toggles debug mode (file header above). Lets the bar be
-- laid out, populated with a synthetic multi-class/tank roster and
-- assignment, and clicked on before a live group exists. Toggling off
-- immediately re-reads real CBAB.Roster/CBAB.DB/CBAB.Track state rather
-- than waiting for the next live event.
-- ============================================================

CBAB.SlashCommands.pbar = function()
	debugMode = not debugMode
	if debugMode then
		debugRoster = buildDebugRoster()
		debugAssignment = buildDebugAssignment()
		CBAB.Bar_SetShown(true)
		CBAB:Print("pbar debug mode |cff00ff00ON|r -- bar now shows a synthetic roster/assignment on row 1. "
			.. "Only your own class's button targets a real unit; every other button targets a fake "
			.. "one and won't actually cast. Run |cff3399ff/cbab pbar|r again to turn it off.")
	else
		debugRoster, debugAssignment = nil, nil
		CBAB:Print("pbar debug mode |cffff4444OFF|r -- back to live roster/assignment data.")
	end
	refreshGridStructure()
	refreshAssignment()
	refreshVisualState()
end

-- ============================================================
-- /cbab bar: toggles bar visibility -- the other half of Config's "Show
-- bar" checkbox.
-- ============================================================

CBAB.SlashCommands.bar = function()
	local shown = CBAB.DB:Char().ui.bar.shown ~= false
	CBAB.Bar_SetShown(not shown)
	CBAB:Print(shown and "paladin bar hidden -- /cbab bar or Config's \"Show bar\" brings it back"
		or "paladin bar shown")
end

function CBAB.Bar_Toggle()
	CBAB.SlashCommands.bar()
end

-- ============================================================
-- Raid-chat assignment report (spec 11.4). Was a pbar toolbar button
-- pre-redesign; the Combat Strip has no toolbar, so this is now called
-- from UI/RosterPage.lua's Solve rail instead. The function itself is
-- unchanged -- only its entry point moved.
-- ============================================================

function CBAB.PostReport()
	if not CBAB:Mode().coordinator then
		CBAB:Print("only the leader or an assist can post a raid report")
		return
	end
	local channel = CBAB.Comm:GroupChannel()
	if not channel then
		CBAB:Print("not in a group -- nothing to report to")
		return
	end
	local assignment = getAssignment()
	if not assignment then
		CBAB:Print("no assignment to report")
		return
	end

	SendChatMessage(("-- CBA Buff assignment (epoch %d) --"):format(assignment.epoch), channel)
	for _, name in ipairs(paladinRowNames()) do
		local line = ("%s: %s"):format(name, paladinSummaryText(name))
		if #line > 250 then line = line:sub(1, 247) .. "..." end
		SendChatMessage(line, channel)
	end
end
