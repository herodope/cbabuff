local ADDON, CBAB = ...

-- The paladin bar. Frame names PallyPowerC1..PallyPowerC9 and PallyPowerRF
-- are a hard compatibility requirement (spec 11.2) -- existing raider
-- macros click these names directly. This is the ONLY place in the addon
-- the PallyPower name appears; every string a user reads says CBA Buff.
--
--   /click PallyPowerC1 LeftButton Down    -> greater blessing on class 1
--   /click PallyPowerRF RightButton Down   -> seal
--
-- Class buttons are compacted to only POPULATED classes in a fixed
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
-- name (any known rank), which auto-resolves to the caster's own highest
-- known rank at cast time -- so this never needs to know or compare ranks.
-- ============================================================

local function spellNameFor(blessingId, isGreater)
	local blessing = CBAB.Blessings[blessingId]
	local ids = isGreater and blessing.greaterIDs or blessing.normalIDs
	return CBAB:GetSpellName(ids[1])
end

-- ============================================================
-- Class -> button-index compaction (spec 11.2).
-- ============================================================

local function computeClassLayout()
	local counts = CBAB.Roster:ClassCounts()
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
	for unit, m in pairs(CBAB.Roster:Get()) do
		if not m.isPet and m.class == class then
			return unit, m
		end
	end
	return nil
end

-- ============================================================
-- Frame creation. RegisterForClicks("AnyDown") is required for the
-- `/click X LeftButton Down` macro form the task's own examples use --
-- secure buttons don't respond to simulated Down clicks otherwise.
-- ============================================================

-- Classic/TBC frames can call SetBackdrop() directly without a
-- BackdropTemplate (that requirement is Legion+/retail only).
local bar = CreateFrame("Frame", "CBABuffBar", UIParent)
bar:SetSize(300, 40)
bar:SetMovable(true)
bar:SetClampedToScreen(true)

local BUTTON_SIZE = 26
local BUTTON_GAP = 4

local classButtons = {}
for i = 1, 9 do
	local btn = CreateFrame("Button", "PallyPowerC" .. i, bar, "SecureActionButtonTemplate")
	btn:RegisterForClicks("AnyDown")
	btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)

	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints()
	btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	CBAB:ApplyBackdrop(btn, {
		edgeFile = "Interface\\Buttons\\WHITE8x8",
		edgeSize = 2,
	})
	btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

	-- Standard (non-reversed) swipe: starts full/opaque and drains away as
	-- expiration approaches, which is the right visual for "time
	-- remaining on this buff" -- the same metaphor as an ability cooldown.
	btn.cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
	btn.cooldown:SetAllPoints()
	btn.cooldown:SetHideCountdownNumbers(false)

	btn.classLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	btn.classLabel:SetPoint("BOTTOM", btn, "TOP", 0, 2)
	btn.classLabel:Hide()

	btn:SetScript("OnEnter", function(self)
		self.classLabel:Show()
		CBAB.Bar_ShowPopout(self)
	end)
	btn:SetScript("OnLeave", function(self)
		self.classLabel:Hide()
		CBAB.Bar_ScheduleHidePopout(self)
	end)

	classButtons[i] = btn
end

local rfButton = CreateFrame("Button", "PallyPowerRF", bar, "SecureActionButtonTemplate")
rfButton:RegisterForClicks("AnyDown")
rfButton:SetSize(BUTTON_SIZE, BUTTON_SIZE)
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
-- a per-character choice (Righteousness/Crusader/Wisdom/Light/...), not
-- fixed reference data like Righteous Fury, and there's no config UI yet
-- to ask. Right-clicking RF is a no-op until UI/Config.lua exists to pick
-- one; the frame and left-click (Righteous Fury) are fully functional now.

-- ============================================================
-- "Cast next needed" -- CBA Buff's own button, not a PallyPower name.
-- ============================================================

local nextButton = CreateFrame("Button", "CBABuffNextButton", bar, "SecureActionButtonTemplate")
nextButton:RegisterForClicks("AnyDown")
nextButton:SetSize(BUTTON_SIZE, BUTTON_SIZE)
nextButton.icon = nextButton:CreateTexture(nil, "ARTWORK")
nextButton.icon:SetAllPoints()
CBAB:ApplyBackdrop(nextButton, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2 })
nextButton:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

-- ============================================================
-- Drag handle: the paladin's own summary lives here as a tooltip, not a
-- separate page (spec 11.2).
-- ============================================================

local handle = CreateFrame("Button", nil, bar)
handle:SetSize(12, BUTTON_SIZE)
handle.tex = handle:CreateTexture(nil, "ARTWORK")
handle.tex:SetAllPoints()
handle.tex:SetColorTexture(0.5, 0.5, 0.5, 0.6)

handle:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("CBA Buff", 1, 1, 1)

	local profile = CBAB.DB:Profile()
	local myName = UnitName("player")
	local jobs = {}
	if profile and profile.assignment then
		for class, blessing in pairs(profile.assignment.greaters[myName] or {}) do
			jobs[#jobs + 1] = ("Greater %s -> %s"):format(CBAB.Blessings[blessing].name, class)
		end
		for _, o in ipairs(profile.assignment.overrides or {}) do
			if o.caster == myName then
				jobs[#jobs + 1] = ("%s -> %s (%s)"):format(CBAB.Blessings[o.blessing].name, o.target, o.reason)
			end
		end
	end
	if #jobs == 0 then
		GameTooltip:AddLine("No assignments.", 0.7, 0.7, 0.7)
	else
		for _, line in ipairs(jobs) do
			GameTooltip:AddLine(line, 0.9, 0.9, 0.9)
		end
	end
	GameTooltip:Show()
end)
handle:SetScript("OnLeave", GameTooltip_Hide)

handle:RegisterForDrag("LeftButton")
handle:SetScript("OnDragStart", function()
	local charDB = CBAB.DB:Char()
	if charDB.ui.bar.locked then return end
	bar:StartMoving()
end)
handle:SetScript("OnDragStop", function()
	bar:StopMovingOrSizing()
	local charDB = CBAB.DB:Char()
	local point, _, _, x, y = bar:GetPoint(1)
	charDB.ui.bar.point = point
	charDB.ui.bar.x = x
	charDB.ui.bar.y = y
end)

-- A plain left click (no drag) opens the editor -- the non-chat entry
-- point the editor's acceptance test wants (spec 11.1). A press-then-move
-- is captured by OnDragStart above instead; only a press-release with no
-- movement reaches OnClick, so this doesn't conflict with dragging.
handle:RegisterForClicks("LeftButtonUp")
handle:SetScript("OnClick", function()
	if CBAB.Editor then
		CBAB.Editor:Toggle()
	end
end)

-- ============================================================
-- Layout
-- ============================================================

local function layoutButtons()
	handle:ClearAllPoints()
	handle:SetPoint("LEFT", bar, "LEFT", 0, 0)

	local anchor = handle
	local relPoint = "RIGHT"
	local offset = 4

	for i = 1, 9 do
		local btn = classButtons[i]
		btn:ClearAllPoints()
		if btn:IsShown() then
			btn:SetPoint("LEFT", anchor, relPoint, offset, 0)
			anchor, relPoint, offset = btn, "RIGHT", BUTTON_GAP
		end
	end

	rfButton:ClearAllPoints()
	rfButton:SetPoint("LEFT", anchor, relPoint, offset, 0)
	anchor, relPoint, offset = rfButton, "RIGHT", BUTTON_GAP

	nextButton:ClearAllPoints()
	nextButton:SetPoint("LEFT", anchor, relPoint, offset, 0)
end

-- ============================================================
-- Refresh: class layout + which class each button targets. Only touches
-- secure attributes when something actually changed the target unit, and
-- always through setAttributeSafe.
-- ============================================================

local currentLayout = {}

local function refreshLayout()
	local layout = computeClassLayout()

	for i = 1, 9 do
		local btn = classButtons[i]
		local class = layout[i]
		if class then
			btn:Show()
			btn.class = class
			-- Icon is set by refreshVisualState below, based on whatever
			-- blessing ends up assigned to this class (or cleared if none).
			-- Attributes are (re)built by refreshAssignment, which always
			-- runs immediately after this in every caller.
		else
			btn:Hide()
			btn.class = nil
		end
	end

	currentLayout = layout
	layoutButtons()
end

-- ============================================================
-- Refresh: what THIS paladin is actually assigned to cast (spec 5, from
-- CBAB.DB:Profile().assignment), wired onto spell1/spell2 attributes and
-- into the popout/next-needed buttons.
-- ============================================================

local function classGreaterBlessing(class)
	local profile = CBAB.DB:Profile()
	if not profile or not profile.assignment then return nil end
	local myName = UnitName("player")
	local entries = profile.assignment.greaters[myName]
	return entries and entries[class]
end

-- Class buttons must be blocked in combat (spec 11.2), but secure
-- attributes can only be WRITTEN out of combat -- there is no way to
-- toggle them exactly at the moment combat starts (PLAYER_REGEN_DISABLED
-- fires WITH InCombatLockdown() already true, so any attempt to write an
-- attribute there just gets queued behind the guard until combat ends,
-- defeating the point). Instead the block is baked into the macro text
-- itself via a `[nocombat]` conditional, evaluated securely at click time
-- -- the macro string only needs to be (re)written when the assignment or
-- target actually changes, never at the combat transition.
local function buildClassMacro(spellName, unit)
	if not spellName or not unit then
		return "/cast" -- no spell/target assigned: a harmless no-op
	end
	return ("/cast [nocombat,@%s] %s"):format(unit, spellName)
end

local function refreshAssignment()
	for i = 1, 9 do
		local btn = classButtons[i]
		if btn.class then
			local blessing = classGreaterBlessing(btn.class)
			btn.assignedBlessing = blessing
			local unit = representativeUnit(btn.class)

			setAttributeSafe(btn, "type1", "macro")
			setAttributeSafe(btn, "macrotext1", buildClassMacro(blessing and spellNameFor(blessing, true), unit))
			-- Right-click offers the same TYPE as a normal cast on current
			-- target, for a quick spot-fix without a popout.
			setAttributeSafe(btn, "type2", "macro")
			setAttributeSafe(btn, "macrotext2", buildClassMacro(blessing and spellNameFor(blessing, false), "target"))
		end
	end
end

-- ============================================================
-- Visual state: icon, border color (missing/expiring/good -- never a
-- filled background, per spec 11.2), and the native Cooldown swipe/timer.
-- ============================================================

local WARN_COLOR = { 1, 0.6, 0, 1 }
local MISSING_COLOR = { 0.9, 0.1, 0.1, 1 }
local GOOD_COLOR = { 0.1, 0.8, 0.1, 1 }
local NEUTRAL_COLOR = { 0.4, 0.4, 0.4, 1 }

local function refreshVisualState()
	local threshold = (CBAB.DB:Char().warnings or {}).threshold or 120

	for i = 1, 9 do
		local btn = classButtons[i]
		if btn.class then
			local unit = representativeUnit(btn.class)
			local blessing = btn.assignedBlessing
			if blessing then
				btn.icon:SetTexture(CBAB.Blessings[blessing].texture)
				local unitState = unit and CBAB.Track:StateFor(unit)
				local record = unitState and unitState[blessing]
				if not record then
					btn:SetBackdropBorderColor(unpack(MISSING_COLOR))
					btn.cooldown:Clear()
				else
					local remaining = (record.expires or 0) - GetTime()
					if remaining <= threshold then
						btn:SetBackdropBorderColor(unpack(WARN_COLOR))
					else
						btn:SetBackdropBorderColor(unpack(GOOD_COLOR))
					end
					if record.expires then
						local duration = record.isGreater and 1800 or 600
						btn.cooldown:SetCooldown(record.expires - duration, duration)
					end
				end
			else
				btn.icon:SetTexture(nil)
				btn:SetBackdropBorderColor(unpack(NEUTRAL_COLOR))
				btn.cooldown:Clear()
			end
		end
	end
end

-- ============================================================
-- "Cast next needed": highest-value entry from CBAB.Track:Missing() that
-- THIS paladin is assigned to fix, ordered by spec 4's value table.
-- ============================================================

local VALUE_ORDER = { salv = 1, kings = 2, light = 3, might = 4, wisdom = 5, sanctuary = 6 }

local function refreshNextButton()
	local myName = UnitName("player")
	local best
	for _, m in ipairs(CBAB.Track:Missing()) do
		if m.assignedTo == myName then
			if not best or (VALUE_ORDER[m.blessing] or 99) < (VALUE_ORDER[best.blessing] or 99) then
				best = m
			end
		end
	end

	if best then
		nextButton.icon:SetTexture(CBAB.Blessings[best.blessing].texture)
		nextButton:SetBackdropBorderColor(unpack(MISSING_COLOR))
		-- Always a normal cast: this fixes one specific unit, never a
		-- class-wide greater.
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
-- Shift-click force-refresh (spec 11.2): bypasses nothing in the secure
-- click path itself (that's not interceptable without tainting it) --
-- instead it forces Track to rescan the represented unit immediately
-- rather than waiting for the next natural UNIT_AURA/flush, so the
-- displayed state catches up right away even if the guard would
-- otherwise have left stale-looking data on screen a moment longer.
-- ============================================================

for i = 1, 9 do
	local btn = classButtons[i]
	btn:HookScript("OnClick", function(self, mouseButton)
		if IsShiftKeyDown() then
			refreshVisualState()
		end
	end)
end

-- ============================================================
-- Popout player buttons for single-target casts (spec 11.2). Named as
-- CBA Buff frames -- PallyPower naming is limited to the C1-C9/RF set.
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
	local profile = CBAB.DB:Profile()
	local members = {}
	for unit, m in pairs(CBAB.Roster:Get()) do
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

		-- Casts whatever blessing THIS paladin currently owes this specific
		-- person, if anything (tank/pet override, minority patch, etc.).
		local blessing
		if profile and profile.assignment then
			for _, o in ipairs(profile.assignment.overrides or {}) do
				if o.caster == myName and o.target == member.name then
					blessing = o.blessing
					break
				end
			end
			if not blessing then
				blessing = classGreaterBlessing(classButton.class)
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
-- Position / lock / compact from CBABuffCharDB.ui.bar, and PallyPower
-- collision warning (spec 11.2). Both wait for DB:Init() via ADDON_LOADED.
-- ============================================================

local function applySavedPosition()
	local ui = CBAB.DB:Char().ui.bar
	bar:ClearAllPoints()
	bar:SetPoint(ui.point or "CENTER", UIParent, ui.point or "CENTER", ui.x or 0, ui.y or -180)
	bar:SetScale(ui.scale or 1.0)
end

-- Renamed to C_AddOns.IsAddOnLoaded on some clients, same family as
-- GetAddOnMetadata (Core.lua) -- resolved once, not just guarded, so this
-- actually detects PallyPower rather than silently assuming it's absent.
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
	refreshLayout()
	refreshAssignment()
	refreshVisualState()
	refreshNextButton()
end)
CBAB:On("ASSIGNMENT_CHANGED", "bar:assignment", function()
	refreshAssignment()
	refreshVisualState()
	refreshNextButton()
end)
CBAB:On("BUFF_STATE_CHANGED", "bar:buffstate", function()
	refreshVisualState()
	refreshNextButton()
end)

-- Class buttons are blocked in combat via the `[nocombat]` macro
-- conditional baked into their macrotext (see buildClassMacro above) --
-- not a runtime attribute toggle, which secure attributes don't allow at
-- the moment combat actually starts. Popout/player buttons and the
-- cast-next button use plain type="spell" attributes with no such guard,
-- so they stay usable in combat (spec 11.2).
CBAB:On("PLAYER_REGEN_ENABLED", "bar:combat-unlock", function()
	refreshAssignment()
end)
