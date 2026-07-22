local ADDON, CBAB = ...

-- The paladin bar (pbar): a PallyPower-style grid, one row per paladin,
-- one column per populated class plus Pets and Aura. Frame names
-- PallyPowerC1..PallyPowerC9 and PallyPowerRF are a hard compatibility
-- requirement (spec 11.2) -- existing raider macros click these names
-- directly. This is the ONLY place in the addon the PallyPower name
-- appears; every string a user reads says CBA Buff. Those compat-named
-- buttons ARE the local player's own row (row 1) -- every other paladin's
-- row uses ordinary, non-compat-named pooled frames.
--
--   /click PallyPowerC1 LeftButton Down    -> greater blessing on class 1
--   /click PallyPowerRF RightButton Down   -> seal
--
-- Class columns are compacted to only POPULATED classes in a fixed
-- priority order (verified against PallyPower's own ClassID table for its
-- BCC/TBC branch): Warrior, Rogue, Priest, Druid, Paladin, Hunter, Mage,
-- Warlock, Shaman. So "C1" is whichever of those is the first class
-- actually present in the raid, not a fixed class -- replicating this
-- compaction is what makes an existing macro land on the right class.
local CLASS_PRIORITY = { "WARRIOR", "ROGUE", "PRIEST", "DRUID", "PALADIN", "HUNTER", "MAGE", "WARLOCK", "SHAMAN" }

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
-- known rank at cast time. This is what makes every grid cell safe to
-- click regardless of whose row it's under (see the click-semantics note
-- above the cell builders, below): the click always casts using the
-- CLICKING player's own spellbook, using whichever blessing/aura that
-- row's plan says belongs in that column. If the clicking player doesn't
-- know that spell, the cast is a silent no-op -- there is no way for one
-- client to cast as another player, full stop.
-- ============================================================

local function spellNameFor(blessingId, isGreater)
	local blessing = CBAB.Blessings[blessingId]
	local ids = isGreater and blessing.greaterIDs or blessing.normalIDs
	return CBAB:GetSpellName(ids[1])
end

local function auraSpellNameFor(auraId)
	return CBAB:GetSpellName(CBAB.Auras[auraId].ids[1])
end

-- Class-colored, title-cased label for the persistent column-header text.
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

local function getTrackMissing()
	if debugMode then return {} end
	return CBAB.Track:Missing()
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
-- attribute targets -- this is what the grid's green check means: every
-- live member of the class currently holds the blessing, from ANY caster.
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

local function syncStatusFor(paladinName)
	if paladinName == UnitName("player") then return "self" end
	local assignment = getAssignment()
	local myEpoch = (assignment and assignment.epoch) or 0
	local theirEpoch = CBAB.Comm:EpochTable()[paladinName]
	if theirEpoch == nil then return "unknown" end
	if theirEpoch >= myEpoch then return "synced" end
	return "stale"
end

local SYNC_LABEL = {
	self = "|cff888888(you)|r",
	synced = "|cff33ff33sync: Y|r",
	stale = "|cffff4444sync: N|r",
	unknown = "|cff888888sync: ?|r",
}

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

local function petsDisplayEnabled()
	local profile = CBAB.DB:Profile()
	return profile ~= nil and profile.wants ~= nil and profile.wants.petsEnabled == true
end

-- ============================================================
-- Frame creation. RegisterForClicks("AnyDown") is required for the
-- `/click X LeftButton Down` macro form the task's own examples use --
-- secure buttons don't respond to simulated Down clicks otherwise.
--
-- Classic/TBC frames can call SetBackdrop() directly without a
-- BackdropTemplate (that requirement is Legion+/retail only).
-- ============================================================

local bar = CreateFrame("Frame", "CBABuffBar", UIParent)
bar:SetMovable(true)
bar:SetResizable(false) -- resizing goes through the custom grip + SetScale, not native frame resize
bar:SetClampedToScreen(true)
CBAB:ApplyBackdrop(bar, {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
bar:SetBackdropColor(0, 0, 0, 0.75)

local PADDING = 8
local TITLE_HEIGHT = 18
local TOOLBAR_HEIGHT = 24
local LABEL_HEIGHT = 12
local NAME_ROW_HEIGHT = 14
local SUMMARY_ROW_HEIGHT = 12
local ROW_GAP = 2
local ROW_BLOCK_GAP = 8
local BUTTON_SIZE = 26
local BUTTON_GAP = 4
local TITLE_MIN_WIDTH = 170
local RESIZE_GRIP_SIZE = 14

-- ============================================================
-- Title row: drag handle + tooltip (spec 11.2's "summary lives in a
-- tooltip, not a page"), title text, Lock/Unlock, Close.
-- ============================================================

local titleBar = CreateFrame("Frame", nil, bar)
titleBar:SetPoint("TOPLEFT", PADDING, -PADDING)
titleBar:SetHeight(TITLE_HEIGHT)
titleBar:EnableMouse(true)

local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
titleText:SetPoint("LEFT", 14, 0)
titleText:SetText("CBA Buff")

local closeButton = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
closeButton:SetSize(16, 16)
closeButton:SetPoint("RIGHT", 0, 0)
closeButton:SetScript("OnClick", function() CBAB.Bar_SetShown(false) end)

local lockButton = CreateFrame("Button", nil, titleBar, "UIPanelButtonTemplate")
lockButton:SetSize(44, 16)
lockButton:SetPoint("RIGHT", closeButton, "LEFT", -4, 0)

local function refreshChrome()
	local locked = CBAB.DB:Char().ui.bar.locked
	lockButton:SetText(locked and "Unlock" or "Lock")
end
CBAB.Bar_RefreshChrome = refreshChrome

lockButton:SetScript("OnClick", function()
	local charDB = CBAB.DB:Char()
	charDB.ui.bar.locked = not charDB.ui.bar.locked
	refreshChrome()
end)

local handle = CreateFrame("Button", nil, titleBar)
handle:SetSize(10, TITLE_HEIGHT)
handle:SetPoint("LEFT", 0, 0)
handle.tex = handle:CreateTexture(nil, "ARTWORK")
handle.tex:SetAllPoints()
handle.tex:SetColorTexture(0.5, 0.5, 0.5, 0.6)

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

titleBar:RegisterForDrag("LeftButton")
titleBar:SetScript("OnDragStart", startDrag)
titleBar:SetScript("OnDragStop", stopDrag)

-- ============================================================
-- Resize grip: drag to change the bar's own scale (same value the
-- Config page's "Scale (%)" field edits, spec 11.5).
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
-- Toolbar row: Solve (live-data solve, spec 11.1), Sync (manual HELLO
-- request/pull, spec 8), Report (raid-chat summary, spec 11.4 "manual
-- button, never automatic"), plus the RF/Seal button and the "cast next
-- needed" button -- both single per-player utilities, not part of the
-- per-class grid, so they live here rather than inside any paladin's row.
-- Static row, laid out once at creation -- never needs a per-refresh pass.
-- ============================================================

local toolbarAnchor = CreateFrame("Frame", nil, bar)
toolbarAnchor:SetSize(1, 1)
toolbarAnchor:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -ROW_GAP)

local solveButton = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
solveButton:SetSize(64, TOOLBAR_HEIGHT - 4)
solveButton:SetText("Solve")
solveButton:SetPoint("TOPLEFT", toolbarAnchor, "TOPLEFT", 0, 0)
solveButton:SetScript("OnClick", function()
	if debugMode then
		CBAB:Print("pbar debug mode is on -- /cbab pbar to turn it off before solving live data")
		return
	end
	CBAB.Solve:RunLive()
end)

local syncButton = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
syncButton:SetSize(56, TOOLBAR_HEIGHT - 4)
syncButton:SetText("Sync")
syncButton:SetPoint("LEFT", solveButton, "RIGHT", 4, 0)
syncButton:SetScript("OnClick", function() CBAB.Comm:Hello() end)

local reportButton = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
reportButton:SetSize(64, TOOLBAR_HEIGHT - 4)
reportButton:SetText("Report")
reportButton:SetPoint("LEFT", syncButton, "RIGHT", 4, 0)

local rfButton = CreateFrame("Button", "PallyPowerRF", bar, "SecureActionButtonTemplate")
rfButton:RegisterForClicks("AnyDown")
rfButton:SetSize(BUTTON_SIZE, BUTTON_SIZE)
rfButton:SetPoint("LEFT", reportButton, "RIGHT", 10, 0)
rfButton.icon = rfButton:CreateTexture(nil, "ARTWORK")
rfButton.icon:SetAllPoints()
rfButton.icon:SetTexture(CBAB:GetSpellIcon(25780)) -- Righteous Fury's own icon, not guessed
CBAB:ApplyBackdrop(rfButton, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2 })
rfButton:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

-- Righteous Fury (left) / Seal of the assigned type (right), both on self.
setAttributeSafe(rfButton, "type1", "spell")
setAttributeSafe(rfButton, "spell1", CBAB:GetSpellName(25780)) -- Righteous Fury
setAttributeSafe(rfButton, "unit1", "player")
setAttributeSafe(rfButton, "type2", "spell")
setAttributeSafe(rfButton, "unit2", "player")
-- spell2 (seal) is deliberately left unset: which seal a paladin wants is
-- a per-character choice, not fixed reference data like Righteous Fury,
-- and there's no config UI yet to ask.

local nextButton = CreateFrame("Button", "CBABuffNextButton", bar, "SecureActionButtonTemplate")
nextButton:RegisterForClicks("AnyDown")
nextButton:SetSize(BUTTON_SIZE, BUTTON_SIZE)
nextButton:SetPoint("LEFT", rfButton, "RIGHT", 4, 0)
nextButton.icon = nextButton:CreateTexture(nil, "ARTWORK")
nextButton.icon:SetAllPoints()
CBAB:ApplyBackdrop(nextButton, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2 })
nextButton:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

-- Measured once (static row) for the width floor layoutGrid() uses below.
local TOOLBAR_CONTENT_WIDTH = 268

-- ============================================================
-- Grid anchor: everything below the toolbar row is laid out fresh on
-- every refresh pass (row count and column count both change), using an
-- absolute cursor from this anchor rather than sibling-relative chains --
-- the same style UI/RosterPage.lua uses for its own growing sections.
-- ============================================================

local gridAnchor = CreateFrame("Frame", nil, bar)
gridAnchor:SetSize(1, 1)
gridAnchor:SetPoint("TOPLEFT", toolbarAnchor, "TOPLEFT", 0, -(TOOLBAR_HEIGHT + ROW_GAP))

local WARN_COLOR = { 1, 0.6, 0, 1 }
local MISSING_COLOR = { 0.9, 0.1, 0.1, 1 }
local GOOD_COLOR = { 0.1, 0.8, 0.1, 1 }
local NEUTRAL_COLOR = { 0.4, 0.4, 0.4, 1 }

-- ============================================================
-- Cell builder: one secure button per (row, column). Click semantics --
-- class cells are nocombat-gated macros (spec 11.2, same as the original
-- single-row design); pets/aura cells are plain spell attributes, always
-- clickable like the popout/next buttons, since they're single-target or
-- self-target rather than class-wide. Every cell, in every row, casts
-- using the CLICKING player's own spellbook (see the spellNameFor comment
-- above) -- the row it's under only determines WHICH blessing/aura gets
-- requested, never who casts it.
--
-- A small non-secure "edit" overlay sits on top of every cell, hidden by
-- default. A paladin row's Manual checkbox shows it for that row's cells;
-- while shown it captures the click instead of the secure button
-- underneath (a separate, always-insecure sibling frame, not a branch in
-- the secure button's own script -- the only safe way to make a secure
-- button's click behaviour conditional without tainting it).
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

-- Forward-declared: refreshVisualState is defined much further down (it
-- needs the row pool to exist first), but every cell -- created here, well
-- before that -- needs to call it on a shift-click (spec 11.2's
-- force-refresh). Bound once per cell at CREATION time via this upvalue
-- rather than in a one-off loop over gridRows after the fact, which would
-- silently miss every row created later through getGridRow().
local refreshVisualState

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
-- compat is scoped to the C1-C9/RF set only (spec 11.2).
local function createCell(parent, kind)
	cellSerial = cellSerial + 1
	local btn = CreateFrame("Button", "CBABuffGridCell" .. cellSerial, parent, "SecureActionButtonTemplate")
	btn:RegisterForClicks("AnyDown")
	btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints()
	btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	CBAB:ApplyBackdrop(btn, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2 })
	btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
	btn.cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
	btn.cooldown:SetAllPoints()
	btn.cooldown:SetHideCountdownNumbers(false)
	attachCheckmark(btn)
	attachTooltip(btn)
	attachEditOverlay(btn, kind)
	bindShiftRefresh(btn)
	return btn
end

-- ============================================================
-- Row 1 -- the local player. Class cells MUST be the PallyPowerC1..9
-- compat buttons (spec 11.2); pets/aura cells are ordinary pooled cells.
-- Row 1 additionally keeps the original single-row popout behaviour
-- (single-target buttons on hover) that predates the grid -- see
-- CBAB.Bar_ShowPopout further down -- so its class cells get their OWN
-- OnEnter/OnLeave instead of attachTooltip's generic one.
-- ============================================================

local classButtons = {}
for i = 1, 9 do
	local btn = CreateFrame("Button", "PallyPowerC" .. i, bar, "SecureActionButtonTemplate")
	btn:RegisterForClicks("AnyDown")
	btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)

	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints()
	btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	CBAB:ApplyBackdrop(btn, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2 })
	btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

	btn.cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
	btn.cooldown:SetAllPoints()
	btn.cooldown:SetHideCountdownNumbers(false)

	-- Column header: class name, always visible, sits just above the button.
	btn.classLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	btn.classLabel:SetPoint("BOTTOM", btn, "TOP", 0, 1)

	attachCheckmark(btn)
	attachEditOverlay(btn, "class")
	bindShiftRefresh(btn)

	btn:SetScript("OnEnter", function(self) CBAB.Bar_ShowPopout(self) end)
	btn:SetScript("OnLeave", function(self) CBAB.Bar_ScheduleHidePopout(self) end)

	classButtons[i] = btn
end

local selfPetsCell = createCell(bar, "pets")
selfPetsCell.classLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
selfPetsCell.classLabel:SetPoint("BOTTOM", selfPetsCell, "TOP", 0, 1)
selfPetsCell.classLabel:SetText("Pets")

local selfAuraCell = createCell(bar, "aura")
selfAuraCell.classLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
selfAuraCell.classLabel:SetPoint("BOTTOM", selfAuraCell, "TOP", 0, 1)
selfAuraCell.classLabel:SetText("Aura")

-- ============================================================
-- Row header widgets: name + sync indicator, assignment summary line, and
-- the per-row Manual-override checkbox. Shared builder for row 1 and
-- every pooled row below it.
-- ============================================================

local function createRowHeader(parent)
	local nameText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	nameText:SetJustifyH("LEFT")

	local summaryText = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	summaryText:SetJustifyH("LEFT")
	summaryText:SetWordWrap(false)

	local manualButton = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	manualButton:SetSize(16, 16)

	local manualLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	manualLabel:SetText("manual")

	return nameText, summaryText, manualButton, manualLabel
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
-- while editing someone ELSE's row is a coordinator-only plan edit.
local function canEditRow(row)
	return row.paladinName == UnitName("player") or CBAB:Mode().coordinator
end

local function applyManualVisibility(row)
	local show = row.manualMode and canEditRow(row)
	for _, cell in pairs(row.cells) do
		if cell.editOverlay then cell.editOverlay:SetShown(show) end
	end
end

local function bindManualToggle(row)
	row.manualButton:SetScript("OnClick", function(self)
		row.manualMode = self:GetChecked() and true or false
		applyManualVisibility(row)
	end)
end

local row1 = { cells = {} }
for i = 1, 9 do row1.cells[i] = classButtons[i] end
row1.cells.pets = selfPetsCell
row1.cells.aura = selfAuraCell
row1.nameText, row1.summaryText, row1.manualButton, row1.manualLabel = createRowHeader(bar)
bindManualToggle(row1)

local gridRows = { [1] = row1 }

local function createGridRow(index)
	local row = { cells = {} }
	for i = 1, 9 do row.cells[i] = createCell(bar, "class") end
	row.cells.pets = createCell(bar, "pets")
	row.cells.aura = createCell(bar, "aura")
	row.nameText, row.summaryText, row.manualButton, row.manualLabel = createRowHeader(bar)
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
-- Assignment pass: secure attributes + icon + editOverlay targeting, for
-- every cell in every active row. Class buttons must be blocked in combat
-- (spec 11.2, `[nocombat]`); pets/aura cells stay castable in combat, same
-- as the popout/next buttons (they're single/self-target, not class-wide).
-- ============================================================

local function buildClassMacro(spellName, unit)
	if not spellName or not unit then
		return "/cast" -- no spell/target assigned: a harmless no-op
	end
	return ("/cast [nocombat,@%s] %s"):format(unit, spellName)
end

local function setClassCell(cell, paladinName, class)
	local assignment = getAssignment()
	local blessing = assignment and assignment.greaters[paladinName] and assignment.greaters[paladinName][class]
	cell.assignedKey = blessing
	cell.icon:SetTexture(blessing and CBAB.Blessings[blessing].texture or nil)

	local unit = representativeUnit(class)
	setAttributeSafe(cell, "type1", "macro")
	setAttributeSafe(cell, "macrotext1", buildClassMacro(blessing and spellNameFor(blessing, true), unit))
	setAttributeSafe(cell, "type2", "macro")
	setAttributeSafe(cell, "macrotext2", buildClassMacro(blessing and spellNameFor(blessing, false), "target"))

	cell.editOverlay.paladinName = paladinName
	cell.editOverlay.class = class
end

local function setPetsCell(cell, paladinName)
	local coverage = petCoverage(paladinName)
	local blessing = coverage and coverage.blessing
	cell.assignedKey = blessing
	cell.icon:SetTexture(blessing and CBAB.Blessings[blessing].texture or nil)

	local firstPet = petOverridesFor(paladinName)[1]
	setAttributeSafe(cell, "type1", "spell")
	setAttributeSafe(cell, "spell1", blessing and spellNameFor(blessing, false) or nil)
	setAttributeSafe(cell, "unit1", firstPet and firstPet.target or nil)
	setAttributeSafe(cell, "type2", "spell")
	setAttributeSafe(cell, "spell2", blessing and spellNameFor(blessing, false) or nil)
	setAttributeSafe(cell, "unit2", "target")

	cell.editOverlay.paladinName = paladinName
end

local function setAuraCell(cell, paladinName)
	local assignment = getAssignment()
	local auraId = assignment and (assignment.auras or {})[paladinName]
	cell.assignedKey = auraId
	cell.icon:SetTexture(auraId and CBAB.Auras[auraId].texture or nil)

	setAttributeSafe(cell, "type1", "spell")
	setAttributeSafe(cell, "spell1", auraId and auraSpellNameFor(auraId) or nil)
	setAttributeSafe(cell, "unit1", "player")

	cell.editOverlay.paladinName = paladinName
end

-- currentLayout: [buttonIndex] = classToken, refreshed by refreshGridStructure
-- below and read here every assignment/visual pass.
local currentLayout = {}

local function refreshAssignment()
	for index, row in pairs(gridRows) do
		if row.paladinName then
			for slot, class in pairs(currentLayout) do
				setClassCell(row.cells[slot], row.paladinName, class)
			end
			setPetsCell(row.cells.pets, row.paladinName)
			setAuraCell(row.cells.aura, row.paladinName)
		end
	end
end

-- ============================================================
-- Visual pass: border colour (missing/expiring/good -- never a filled
-- background, per spec 11.2), the green check overlay (spec: full-class
-- coverage, not just the one representative unit the secure attribute
-- targets), the Cooldown swipe/timer, and tooltip text.
-- ============================================================

local function clearCellVisual(cell)
	cell:SetBackdropBorderColor(unpack(NEUTRAL_COLOR))
	cell.cooldown:Clear()
	cell.checkTex:Hide()
	cell.tooltipLines = nil
end

local function applyClassVisual(cell, paladinName, class)
	local blessing = cell.assignedKey
	if not blessing then
		clearCellVisual(cell)
		cell.tooltipLines = { ("%s -> %s"):format(paladinName, classDisplayLabel(class)), "no greater assigned" }
		return
	end

	local complete = classCoverage(class, blessing)
	cell.checkTex:SetShown(complete)

	local threshold = (CBAB.DB:Char().warnings or {}).threshold or 120
	local unit = representativeUnit(class)
	local record = unit and getTrackStateFor(unit)[blessing]
	local statusLine

	if not record then
		cell:SetBackdropBorderColor(unpack(MISSING_COLOR))
		cell.cooldown:Clear()
		statusLine = "missing"
	else
		local remaining = (record.expires or 0) - GetTime()
		if remaining <= threshold then
			cell:SetBackdropBorderColor(unpack(WARN_COLOR))
		else
			cell:SetBackdropBorderColor(unpack(GOOD_COLOR))
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
		cell:SetBackdropBorderColor(unpack(MISSING_COLOR))
		cell.cooldown:Clear()
	else
		if coverage.minRemaining <= threshold then
			cell:SetBackdropBorderColor(unpack(WARN_COLOR))
		else
			cell:SetBackdropBorderColor(unpack(GOOD_COLOR))
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
		cell:SetBackdropBorderColor(unpack(MISSING_COLOR))
		cell.cooldown:Clear()
		statusLine = "not active"
	elseif coverage.indefinite then
		cell:SetBackdropBorderColor(unpack(GOOD_COLOR))
		cell.cooldown:Clear()
		statusLine = "active (no fixed duration)"
	else
		local threshold = (CBAB.DB:Char().warnings or {}).threshold or 120
		if coverage.minRemaining <= threshold then
			cell:SetBackdropBorderColor(unpack(WARN_COLOR))
		else
			cell:SetBackdropBorderColor(unpack(GOOD_COLOR))
		end
		statusLine = ("%ds remaining"):format(math.max(0, math.floor(coverage.minRemaining)))
	end

	cell.tooltipLines = { paladinName .. " -> Aura", CBAB.Auras[auraId].name, statusLine }
end

-- Assigns the upvalue forward-declared above (bindShiftRefresh already
-- closes over it), rather than `local function`, which would create a
-- second, shadowing local instead of filling in the forward reference.
refreshVisualState = function()
	for index, row in pairs(gridRows) do
		if row.paladinName then
			for slot, class in pairs(currentLayout) do
				applyClassVisual(row.cells[slot], row.paladinName, class)
			end
			applyPetsVisual(row.cells.pets, row.paladinName)
			applyAuraVisual(row.cells.aura, row.paladinName)
		end
	end
end

-- ============================================================
-- Structure pass: which paladins get a row, which classes get a column,
-- and the full top-to-bottom / left-to-right layout. Runs on both
-- ROSTER_CHANGED (class columns can change) and ASSIGNMENT_CHANGED (the
-- row list itself is partly assignment-driven -- see paladinRowNames).
-- ============================================================

local function hideRow(row)
	row.paladinName = nil
	row.manualMode = false
	row.manualButton:SetChecked(false)
	row.nameText:Hide()
	row.summaryText:Hide()
	row.manualButton:Hide()
	row.manualLabel:Hide()
	for _, cell in pairs(row.cells) do
		cell:Hide()
		if cell.editOverlay then cell.editOverlay:Hide() end
	end
end

local function refreshGridStructure()
	currentLayout = computeClassLayout()
	local rowNames = paladinRowNames()
	local showPets = petsDisplayEnabled()

	-- Column x-offsets, shared by every row.
	local columnX, x = {}, 0
	for i = 1, 9 do
		if currentLayout[i] then
			columnX[i] = x
			x = x + BUTTON_SIZE + BUTTON_GAP
		end
	end
	local petsX
	if showPets then
		petsX = x
		x = x + BUTTON_SIZE + BUTTON_GAP
	end
	local auraX = x
	local gridContentWidth = x + BUTTON_SIZE

	-- Computed up front (not after the row loop) so the Manual column has a
	-- fixed, reserved position independent of how few columns a small raid
	-- has -- otherwise a 1-2 class grid would push the checkbox/label into
	-- negative x and off the window's left edge.
	local MANUAL_COLUMN_WIDTH = 60
	local contentWidth = math.max(gridContentWidth, TOOLBAR_CONTENT_WIDTH, TITLE_MIN_WIDTH) + MANUAL_COLUMN_WIDTH

	local y = 0
	for i, paladinName in ipairs(rowNames) do
		local row = getGridRow(i)
		row.paladinName = paladinName

		if i == 1 then
			y = y - LABEL_HEIGHT -- headroom for row 1's column labels
		end

		row.nameText:ClearAllPoints()
		row.nameText:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", 0, y)
		row.nameText:SetText(("|cffffffff%s|r  %s"):format(paladinName, SYNC_LABEL[syncStatusFor(paladinName)]))
		row.nameText:Show()

		local canEdit = canEditRow(row)
		row.manualButton:ClearAllPoints()
		row.manualButton:SetPoint("TOPRIGHT", gridAnchor, "TOPLEFT", contentWidth, y + 2)
		row.manualButton:SetEnabled(canEdit)
		if not canEdit then
			row.manualMode = false
			row.manualButton:SetChecked(false)
		end
		row.manualButton:Show()
		row.manualLabel:ClearAllPoints()
		row.manualLabel:SetPoint("RIGHT", row.manualButton, "LEFT", -2, 0)
		row.manualLabel:Show()
		applyManualVisibility(row)

		y = y - NAME_ROW_HEIGHT

		row.summaryText:ClearAllPoints()
		row.summaryText:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", 2, y)
		row.summaryText:SetText(paladinSummaryText(paladinName))
		row.summaryText:Show()
		y = y - SUMMARY_ROW_HEIGHT

		for slot = 1, 9 do
			local cell = row.cells[slot]
			cell:ClearAllPoints()
			if currentLayout[slot] then
				cell.class = currentLayout[slot]
				cell:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", columnX[slot], y)
				cell:Show()
				if i == 1 then
					cell.classLabel:SetText(classDisplayLabel(currentLayout[slot]))
				end
			else
				cell.class = nil
				cell:Hide()
			end
		end

		row.cells.pets:ClearAllPoints()
		if showPets then
			row.cells.pets:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", petsX, y)
			row.cells.pets:Show()
		else
			row.cells.pets:Hide()
		end

		row.cells.aura:ClearAllPoints()
		row.cells.aura:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", auraX, y)
		row.cells.aura:Show()

		y = y - BUTTON_SIZE - ROW_BLOCK_GAP
	end

	for i = #rowNames + 1, #gridRows do
		hideRow(gridRows[i])
	end

	titleBar:ClearAllPoints()
	titleBar:SetPoint("TOPLEFT", PADDING, -PADDING)
	titleBar:SetWidth(contentWidth)

	bar:SetSize(
		contentWidth + PADDING * 2,
		PADDING + TITLE_HEIGHT + ROW_GAP + TOOLBAR_HEIGHT + ROW_GAP + (-y) + PADDING
	)
end

-- ============================================================
-- "Cast next needed": highest-value entry from CBAB.Track:Missing() that
-- THIS paladin is assigned to fix, ordered by spec 4's value table.
-- Unchanged from the pre-grid design -- a single per-player utility, not
-- part of the per-paladin grid.
-- ============================================================

local VALUE_ORDER = { salv = 1, kings = 2, light = 3, might = 4, wisdom = 5, sanctuary = 6 }

local function refreshNextButton()
	local myName = UnitName("player")
	local best
	for _, m in ipairs(getTrackMissing()) do
		if m.assignedTo == myName then
			if not best or (VALUE_ORDER[m.blessing] or 99) < (VALUE_ORDER[best.blessing] or 99) then
				best = m
			end
		end
	end

	if best then
		nextButton.icon:SetTexture(CBAB.Blessings[best.blessing].texture)
		nextButton:SetBackdropBorderColor(unpack(MISSING_COLOR))
		setAttributeSafe(nextButton, "type1", "spell")
		setAttributeSafe(nextButton, "spell1", spellNameFor(best.blessing, false))
		setAttributeSafe(nextButton, "unit1", best.unit)
	else
		nextButton.icon:SetTexture(nil)
		nextButton:SetBackdropBorderColor(unpack(NEUTRAL_COLOR))
		setAttributeSafe(nextButton, "spell1", nil)
	end
end

-- ============================================================
-- Popout player buttons for single-target casts (spec 11.2). Row 1 (the
-- local player) only -- this predates the grid and stays scoped to the
-- compat row it was built for; other rows show their per-class summary
-- via the grid cell's own tooltip instead.
-- ============================================================

local popoutButtons = {}

local function getPopoutButton(index)
	local btn = popoutButtons[index]
	if not btn then
		btn = CreateFrame("Button", "CBABuffPopout" .. index, bar, "SecureActionButtonTemplate")
		btn:RegisterForClicks("AnyDown")
		btn:SetSize(BUTTON_SIZE - 6, BUTTON_SIZE - 6)
		btn.icon = btn:CreateTexture(nil, "ARTWORK")
		btn.icon:SetAllPoints()
		CBAB:ApplyBackdrop(btn, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
		popoutButtons[index] = btn
	end
	return btn
end

function CBAB.Bar_ShowPopout(classButton)
	if not classButton.class then return end

	local myName = UnitName("player")
	local assignment = getAssignment()
	local members = {}
	for unit, m in pairs(getRosterCache()) do
		if not m.isPet and m.class == classButton.class then
			members[#members + 1] = { unit = unit, name = m.name }
		end
	end
	table.sort(members, function(a, b) return a.unit < b.unit end)

	for i, member in ipairs(members) do
		local btn = getPopoutButton(i)
		btn:ClearAllPoints()
		btn:SetPoint("BOTTOM", classButton, "TOP", 0, 4 + (i - 1) * (BUTTON_SIZE - 4))
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
-- Handle tooltip: the local player's own summary (spec 11.2's "tooltip,
-- not a page") -- redundant with row 1's own name/summary line now that
-- the grid always shows it, but kept as a quick glance from the drag
-- handle without having to find row 1 in a tall grid.
-- ============================================================

handle:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("CBA Buff", 1, 1, 1)

	local myName = UnitName("player")
	if debugMode then
		GameTooltip:AddLine("|cffff8800pbar debug mode|r", 1, 0.6, 0)
	end
	GameTooltip:AddLine(paladinSummaryText(myName), 0.9, 0.9, 0.9)
	GameTooltip:Show()
end)
handle:SetScript("OnLeave", GameTooltip_Hide)

-- A plain left click (no drag) opens the roster page -- the non-chat entry
-- point the editor's acceptance test wants (spec 11.1). A press-then-move
-- is captured by OnDragStart above instead; only a press-release with no
-- movement reaches OnClick, so this doesn't conflict with dragging.
handle:RegisterForClicks("LeftButtonUp")
handle:SetScript("OnClick", function()
	if CBAB.RosterPage then
		CBAB.RosterPage:Toggle()
	end
end)

-- ============================================================
-- Report: raid-chat summary of the current assignment (spec 11.4 -- manual
-- button only, never automatic). Coordinator-gated, same as Push.
-- ============================================================

function CBAB.Bar_PostReport()
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

reportButton:SetScript("OnClick", CBAB.Bar_PostReport)

-- ============================================================
-- Show/hide: the Close button on the title row sets this, /cbab bar and
-- Config's "Show bar" checkbox both toggle it too.
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
-- Position / lock / compact from CBABuffCharDB.ui.bar, and PallyPower
-- collision warning (spec 11.2). Both wait for DB:Init() via ADDON_LOADED.
-- ============================================================

local function applySavedPosition()
	local ui = CBAB.DB:Char().ui.bar
	bar:ClearAllPoints()
	bar:SetPoint(ui.point or "CENTER", UIParent, ui.point or "CENTER", ui.x or 0, ui.y or -180)
	bar:SetScale(ui.scale or 1.0)
	-- Full refresh immediately at ADDON_LOADED rather than waiting for the
	-- first ROSTER_CHANGED, so the grid's chrome is visible even before any
	-- group exists.
	refreshGridStructure()
	refreshAssignment()
	refreshVisualState()
	refreshNextButton()
	refreshChrome()
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
			.. "secure button names (PallyPowerC1-C9, PallyPowerRF) for macro "
			.. "compatibility, so raid macros clicking those names will behave "
			.. "unpredictably with both active. Disable one.",
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
	refreshNextButton()
end)
CBAB:On("ASSIGNMENT_CHANGED", "bar:assignment", function()
	refreshGridStructure()
	refreshAssignment()
	refreshVisualState()
	refreshNextButton()
end)
CBAB:On("BUFF_STATE_CHANGED", "bar:buffstate", function()
	refreshVisualState()
	refreshNextButton()
end)

-- Class cells are blocked in combat via the `[nocombat]` macro conditional
-- baked into their macrotext (buildClassMacro above) -- not a runtime
-- attribute toggle, which secure attributes don't allow at the moment
-- combat actually starts. Pets/aura/popout/next-button attributes have no
-- such guard, so they stay usable in combat (spec 11.2).
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
	refreshNextButton()
end

-- ============================================================
-- /cbab bar: toggles bar visibility -- the other half of the Close
-- button's escape hatch, alongside Config's "Show bar" checkbox.
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
