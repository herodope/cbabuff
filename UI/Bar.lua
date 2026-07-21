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

-- Class-colored, title-cased label for the persistent under-button text
-- (spec 11.2, amended -- see the class button loop below).
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
-- debugMode is the only thing that needs to change anywhere.
--
-- Real casts still only work for the player's OWN class button, since
-- that one targets the real "player" unit -- every other button targets a
-- fake unit token that resolves to nothing, by design (this is a layout/
-- assignment-display test, not a way to cast on people who aren't there).
-- Buff-state coloring (Track.lua) isn't faked: every button reads as
-- "missing" (red border), which is still a real, useful signal that the
-- icon/layout/click-through work, just not a buff-timer simulation.
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
				-- One fake tank so the tank-override path is visible too.
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

-- ============================================================
-- Frame creation. RegisterForClicks("AnyDown") is required for the
-- `/click X LeftButton Down` macro form the task's own examples use --
-- secure buttons don't respond to simulated Down clicks otherwise.
--
-- The bar is a real window now, not loose floating buttons: a backdrop
-- panel, a title row (drag handle, title text, Lock/Unlock, Close), a
-- persistent class-name label under every button (amends SPEC.md 11.2's
-- original hover-only choice), and a resize grip. None of this touches
-- secure attributes -- sizing/backdrop/label text are always safe to
-- change regardless of combat, only SetAttribute needs the combat guard.
-- ============================================================

-- Classic/TBC frames can call SetBackdrop() directly without a
-- BackdropTemplate (that requirement is Legion+/retail only).
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
local LABEL_HEIGHT = 12
local ROW_GAP = 2
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

-- The handle sliver keeps its original tooltip/click-to-open-editor
-- behaviour (below); the rest of the title row is ALSO draggable, since a
-- real title bar is draggable across its whole span, not just one sliver.
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

	-- Always visible now, not hover-only (amends SPEC.md 11.2).
	btn.classLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	btn.classLabel:SetPoint("BOTTOM", btn, "TOP", 0, 1)

	btn:SetScript("OnEnter", function(self)
		CBAB.Bar_ShowPopout(self)
	end)
	btn:SetScript("OnLeave", function(self)
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
-- Handle tooltip: the paladin's own summary lives here, not a separate
-- page (spec 11.2). The handle frame itself was created earlier as part
-- of the title row.
-- ============================================================

handle:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("CBA Buff", 1, 1, 1)

	local assignment = getAssignment()
	local myName = UnitName("player")
	local jobs = {}
	if assignment then
		for class, blessing in pairs(assignment.greaters[myName] or {}) do
			jobs[#jobs + 1] = ("Greater %s -> %s"):format(CBAB.Blessings[blessing].name, class)
		end
		for _, o in ipairs(assignment.overrides or {}) do
			if o.caster == myName then
				jobs[#jobs + 1] = ("%s -> %s (%s)"):format(CBAB.Blessings[o.blessing].name, o.target, o.reason)
			end
		end
	end
	if debugMode then
		GameTooltip:AddLine("|cffff8800pbar debug mode|r", 1, 0.6, 0)
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

-- Dragging is handled by titleBar (above, spanning the whole title row);
-- the handle keeps only its tooltip and click-to-open-editor behaviour.

-- A plain left click (no drag) opens the editor -- the non-chat entry
-- point the editor's acceptance test wants (spec 11.1). A press-then-move
-- is captured by OnDragStart above instead; only a press-release with no
-- movement reaches OnClick, so this doesn't conflict with dragging.
handle:RegisterForClicks("LeftButtonUp")
handle:SetScript("OnClick", function()
	-- The standalone assignment editor was folded into the roster page
	-- (spec 11.1/11.6), so this opens that instead.
	if CBAB.RosterPage then
		CBAB.RosterPage:Toggle()
	end
end)

-- ============================================================
-- Layout: button row sits below the title row; the whole panel is
-- resized to fit however many class buttons are actually shown (spec
-- 11.2's compaction), with a minimum width so the title row's chrome
-- (title/Lock/Close) never gets clipped by a short button row.
-- ============================================================

local buttonRowAnchor = CreateFrame("Frame", nil, bar)
buttonRowAnchor:SetSize(1, 1)
buttonRowAnchor:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -(ROW_GAP + LABEL_HEIGHT))

local function layoutButtons()
	local anchor = buttonRowAnchor
	local relPoint = "LEFT"
	local offset = 0

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

	-- Content width = however far the button row actually extends, past
	-- buttonRowAnchor's left edge.
	local buttonRowWidth = (nextButton:GetRight() or 0) - (buttonRowAnchor:GetLeft() or 0)
	if buttonRowWidth <= 0 then
		-- GetRight()/GetLeft() aren't reliable before the first layout
		-- pass has actually rendered a frame; fall back to a plain sum.
		buttonRowWidth = BUTTON_SIZE + BUTTON_GAP + BUTTON_SIZE + BUTTON_GAP + BUTTON_SIZE
		for i = 1, 9 do
			if classButtons[i]:IsShown() then
				buttonRowWidth = buttonRowWidth + BUTTON_SIZE + BUTTON_GAP
			end
		end
	end

	local contentWidth = math.max(buttonRowWidth, TITLE_MIN_WIDTH)
	titleBar:ClearAllPoints()
	titleBar:SetPoint("TOPLEFT", PADDING, -PADDING)
	titleBar:SetWidth(contentWidth)

	bar:SetSize(
		contentWidth + PADDING * 2,
		PADDING + TITLE_HEIGHT + ROW_GAP + LABEL_HEIGHT + BUTTON_SIZE + PADDING
	)
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
			-- classLabel's text was previously never actually set anywhere
			-- (a pre-existing gap -- the hover label always rendered blank).
			-- Now persistent, it needs setting here every layout pass.
			btn.classLabel:SetText(classDisplayLabel(class))
			-- Icon is set by refreshVisualState below, based on whatever
			-- blessing ends up assigned to this class (or cleared if none).
			-- Attributes are (re)built by refreshAssignment, which always
			-- runs immediately after this in every caller.
		else
			btn:Hide()
			btn.class = nil
			btn.classLabel:SetText("")
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
	local assignment = getAssignment()
	if not assignment then return nil end
	local myName = UnitName("player")
	local entries = assignment.greaters[myName]
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
				local unitState = unit and getTrackStateFor(unit)
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

		-- Casts whatever blessing THIS paladin currently owes this specific
		-- person, if anything (tank/pet override, minority patch, etc.).
		local blessing
		if assignment then
			for _, o in ipairs(assignment.overrides or {}) do
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
-- Show/hide: the Close button on the title row sets this, /cbab bar and
-- Config's "Show bar" checkbox both toggle it too (per session request,
-- both a slash command AND a Config checkbox get you back if you close
-- it). Older SavedVariables predate this field, so nil reads as shown.
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
	-- first ROSTER_CHANGED. Without this the 9 class buttons stayed in
	-- their default file-scope SHOWN-but-empty state (nine blank squares,
	-- no icon, no label), because refreshLayout -- which hides unpopulated
	-- buttons and sets the class labels -- had never run. Roster.lua's
	-- PLAYER_ENTERING_WORLD rebuild then fires a ROSTER_CHANGED right after
	-- login to fill in the real classes.
	refreshLayout()
	refreshAssignment()
	refreshVisualState()
	refreshNextButton()
	refreshChrome()
	CBAB.Bar_SetShown(ui.shown ~= false)
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
		CBAB:Print("pbar debug mode |cff00ff00ON|r -- bar now shows a synthetic roster/assignment. "
			.. "Only your own class's button targets a real unit; every other button targets a fake "
			.. "one and won't actually cast. Run |cff3399ff/cbab pbar|r again to turn it off.")
	else
		debugRoster, debugAssignment = nil, nil
		CBAB:Print("pbar debug mode |cffff4444OFF|r -- back to live roster/assignment data.")
	end
	refreshLayout()
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
