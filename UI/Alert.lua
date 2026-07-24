local ADDON, CBAB = ...
local Theme = CBAB.Theme

-- The alert window (spec 11.3) and the three warning layers (spec 11.4).
-- Everything here is driven by CBAB events -- BUFF_STATE_CHANGED,
-- ASSIGNMENT_CHANGED, ROSTER_CHANGED, UNIT_PET -- never polled.
--
-- Reskinned per the design handoff (UI/redesign/design_handoff_cba_buff/
-- README.md, "4. Alert window", HTML sections 5a/5b, screenshots/5-alert.png)
-- on top of UI/Theme.lua, same as UI/Bar.lua, UI/RosterPage.lua and
-- UI/Config.lua already build on. All detection/warning/secure-attribute
-- logic below (computeRows, describeRow, the three warning layers, the
-- setAttributeSafe/pendingWrites combat-lockdown queue) is byte-for-byte
-- unchanged from the pre-redesign version; only frame creation/styling and
-- the row's visual shape are new.
--
-- Four decisions the HTML reference doesn't translate literally into the
-- WoW UI API:
--   - The header's gear glyph becomes a plain "Lock"/"Unlock" text button
--     (spec 11.3 requires exactly this control, synced with Config's own
--     checkbox via ui.alert.locked) rather than a "⚙" icon -- same reason
--     UI/Bar.lua's own chevron renders as the ASCII "v" rather than "⌄":
--     Rajdhani/stock WoW fonts don't ship these Unicode glyphs, so a literal
--     gear/check/target glyph would render as a blank tofu box in-game. The
--     header's "!"/close "✕" become the native UIPanelCloseButton texture
--     and a plain "!" (ASCII, renders fine); the row's "⌖" target control
--     becomes a small "TGT" text button; the header/clean-state checkmark
--     uses the native Interface\Buttons\UI-CheckBox-Check texture (tinted
--     via SetVertexColor) instead of a "✓" glyph.
--   - Rows resize by two-point (LEFT+RIGHT) anchoring their text/chip
--     children directly to the row's own edges rather than recomputing
--     pixel widths on every resize-grip drag (the pre-redesign file's own
--     approach, kept here only for the resize grip's width math itself) --
--     WoW stretches a FontString/Frame anchored on both horizontal edges
--     automatically, so the whole row reflows for free.
--   - "Snooze 30s" (HTML footer) has no equivalent in the pre-redesign
--     logic or SPEC.md 11.3/11.4 -- it's new, deliberately minimal: it just
--     force-hides the window for 30s the same way combat-suppression
--     already does (see updateVisibility), rather than touching any
--     detection/warning logic.
--   - `ui.alert.width`'s stored default moves from 280 to 412 (Data/
--     Defaults.lua) to match this layout's wider two-line rows; existing
--     characters who already resized their own window keep their own value,
--     since defaults only ever seed a first run.

-- ============================================================
-- Secure attribute writes: same combat-safe pattern as UI/Bar.lua. Rows
-- (and the per-row target button) are click-to-cast/click-to-target and
-- therefore secure buttons; nothing here ever calls SetAttribute while
-- InCombatLockdown().
-- ============================================================

local pendingWrites = {}

local function setAttributeSafe(button, attr, value)
	if InCombatLockdown() then
		pendingWrites[#pendingWrites + 1] = { button = button, attr = attr, value = value }
	else
		button:SetAttribute(attr, value)
	end
end

CBAB:On("PLAYER_REGEN_ENABLED", "alert:flush-attrs", function()
	if #pendingWrites == 0 then return end
	local writes = pendingWrites
	pendingWrites = {}
	for _, w in ipairs(writes) do
		w.button:SetAttribute(w.attr, w.value)
	end
end)

local function spellNameFor(blessingId, isGreater)
	local blessing = CBAB.Blessings[blessingId]
	local ids = isGreater and blessing.greaterIDs or blessing.normalIDs
	return CBAB:GetSpellName(ids[1])
end

-- ============================================================
-- Problem detection: cross-references the active assignment against
-- tracked buff state, same technique as CBAB.Track:Missing() but also
-- classifying "expiring" (has it, but under the warning threshold) and
-- grouping by CAUSE rather than by player (spec 11.3):
--   - class-wide greaters group into ONE row per (class, blessing, status)
--   - overrides (tank/pet/minority) are inherently per-individual and
--     never grouped, since collapsing different tanks together would
--     lose who specifically needs what
-- ============================================================

local function classLabel(class)
	return class:sub(1, 1) .. class:sub(2):lower() .. "s"
end

local function formatRemaining(seconds)
	seconds = math.max(0, math.floor(seconds))
	return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

-- ============================================================
-- Group-size awareness (rule 1: a unit can only ever hold ONE blessing at a
-- time, so a plan that assigns several -- e.g. every class-wide Salvation
-- greater lands on the Paladin class too, or a plan solved for a bigger
-- raid than is actually live -- can never be fully satisfied at once, and
-- the alert must not nag about more than the single best of them). Nothing
-- here mutates the stored assignment; it only decides what's actually
-- possible and preferred given who is live right now.
-- ============================================================

local function paladinCanCast(m, blessingId)
	if not CBAB.Blessings[blessingId].talentGated then return true end
	local record = CBAB.Cap:Get(m.nameRealm)
	return record ~= nil and record[blessingId] == true
end

-- Whether ANY live paladin (not just the one the stored plan names) is
-- actually able to cast this blessing right now.
local function feasibleBlessing(blessingId, roster)
	for _, m in pairs(roster) do
		if not m.isPet and m.class == "PALADIN" and paladinCanCast(m, blessingId) then
			return true
		end
	end
	return false
end

-- The plan's stored caster if they're actually here; otherwise whoever live
-- and capable can stand in -- preferring the recipient casting on
-- themselves, matching how a shrunk group naturally has to resolve it.
local function effectiveCaster(blessingId, storedCaster, unit, roster)
	for _, m in pairs(roster) do
		if not m.isPet and m.name == storedCaster then
			return storedCaster
		end
	end
	local self = roster[unit]
	if self and not self.isPet and self.class == "PALADIN" and paladinCanCast(self, blessingId) then
		return self.name
	end
	for _, m in pairs(roster) do
		if not m.isPet and m.class == "PALADIN" and paladinCanCast(m, blessingId) then
			return m.name
		end
	end
	return storedCaster
end

local function blessingRank(blessingId)
	for i, id in ipairs(CBAB.BlessingValueOrder) do
		if id == blessingId then return i end
	end
	return #CBAB.BlessingValueOrder + 1
end

-- Tanks and pets have an explicit ordered preference (spec 5.5/5.6); anyone
-- else falls back to the raid-wide importance order (spec 4).
local function wantListFor(m, profile, rosterByName)
	if m.isPet then
		return profile.wants and profile.wants.pet
	end
	if m.isTank then
		local entry = rosterByName[m.name]
		if entry and entry.tankWantOverride and #entry.tankWantOverride > 0 then
			return entry.tankWantOverride
		end
		return profile.wants.tanks and profile.wants.tanks[m.class]
	end
	return nil
end

-- Lower is better. Want-listed entries always beat unlisted ones; within
-- each group, list position (or the general importance order) breaks ties.
local function candidateScore(blessingId, wantList)
	if wantList then
		for i, id in ipairs(wantList) do
			if id == blessingId then return i end
		end
		return 1000 + blessingRank(blessingId)
	end
	return blessingRank(blessingId)
end

local function computeRows()
	local profile = CBAB.DB:Profile()
	if not profile or not profile.assignment then return {} end
	local assignment = profile.assignment
	local roster = CBAB.Roster:Get()
	local threshold = (CBAB.DB:Char().warnings or {}).threshold or 120
	local petsEnabled = profile.wants and profile.wants.petsEnabled

	local nameToUnit = {}
	for unit, m in pairs(roster) do
		nameToUnit[m.name] = unit
	end

	-- [unit][blessingId] = casterName, plus a parallel reason/class map --
	-- same cross-reference CBAB.Track:Missing() builds (rule 4: an
	-- override replaces its own caster's class-wide greater on that unit).
	local assigned, reasonFor = {}, {}

	for casterName, entries in pairs(assignment.greaters or {}) do
		for class, blessing in pairs(entries) do
			for unit, m in pairs(roster) do
				if not m.isPet and m.class == class then
					assigned[unit] = assigned[unit] or {}
					assigned[unit][blessing] = casterName
					reasonFor[unit] = reasonFor[unit] or {}
					reasonFor[unit][blessing] = { reason = "greater", class = class }
				end
			end
		end
	end

	for _, o in ipairs(assignment.overrides or {}) do
		local unit = nameToUnit[o.target] or o.target
		local m = unit and roster[unit]
		if unit and m then
			assigned[unit] = assigned[unit] or {}
			local casterGreaters = assignment.greaters[o.caster]
			local replaced = casterGreaters and casterGreaters[m.class]
			if replaced then
				assigned[unit][replaced] = nil
			end
			assigned[unit][o.blessing] = o.caster
			reasonFor[unit] = reasonFor[unit] or {}
			reasonFor[unit][o.blessing] = { reason = o.reason, class = m.class }
		end
	end

	local groups, order = {}, {}
	local function group(key, build)
		local row = groups[key]
		if not row then
			row = build()
			groups[key] = row
			order[#order + 1] = key
		end
		return row
	end

	local rosterByName = {}
	for _, r in ipairs(profile.roster or {}) do
		rosterByName[r.name] = r
	end

	for unit, blessingsForUnit in pairs(assigned) do
		local m = roster[unit]
		if m then
			-- Pet suppression (spec 11.3): no row when pets are off, or
			-- when this specific pet doesn't exist or is dead.
			local suppressed = m.isPet and (not petsEnabled or not UnitExists(unit) or UnitIsDead(unit))

			if not suppressed then
				local unitState = CBAB.Track:StateFor(unit)

				-- Rule 1: at most one of this unit's candidate blessings can
				-- ever actually be active. If it's already holding one of
				-- them, that's the whole story -- fine, or expiring, but
				-- never "also missing" the rest.
				local heldBlessing, heldRecord
				for blessingId in pairs(blessingsForUnit) do
					local record = unitState[blessingId]
					if record then
						heldBlessing, heldRecord = blessingId, record
						break
					end
				end

				local chosenBlessing, chosenStatus, chosenRemaining, chosenCaster

				if heldBlessing then
					local remaining = (heldRecord.expires or 0) - GetTime()
					if remaining <= threshold then
						chosenBlessing, chosenStatus, chosenRemaining = heldBlessing, "expiring", remaining
						chosenCaster = blessingsForUnit[heldBlessing]
					end
				else
					-- Nothing held yet -- of the candidates actually
					-- castable by someone live right now, surface only the
					-- single best one (spec: "only display things that are
					-- possible based on current group").
					local wantList = wantListFor(m, profile, rosterByName)
					local bestScore
					for blessingId in pairs(blessingsForUnit) do
						if feasibleBlessing(blessingId, roster) then
							local score = candidateScore(blessingId, wantList)
							if not bestScore or score < bestScore then
								chosenBlessing, bestScore = blessingId, score
							end
						end
					end
					if chosenBlessing then
						chosenStatus = "missing"
						chosenCaster = blessingsForUnit[chosenBlessing]
					end
				end

				if chosenBlessing then
					chosenCaster = effectiveCaster(chosenBlessing, chosenCaster, unit, roster)
					local info = reasonFor[unit] and reasonFor[unit][chosenBlessing]
					local reason = info and info.reason or "greater"
					local class = info and info.class or m.class

					if reason == "greater" then
						local key = ("greater:%s:%s:%s"):format(class, chosenBlessing, chosenStatus)
						local row = group(key, function()
							return {
								kind = "greater", blessing = chosenBlessing, assignedTo = chosenCaster,
								status = chosenStatus, class = class, units = {},
							}
						end)
						row.units[#row.units + 1] = unit
						if chosenRemaining and (not row.soonestRemaining or chosenRemaining < row.soonestRemaining) then
							row.soonestRemaining = chosenRemaining
						end
					else
						local key = ("individual:%s:%s"):format(unit, chosenBlessing)
						group(key, function()
							return {
								kind = "individual", blessing = chosenBlessing, assignedTo = chosenCaster,
								status = chosenStatus, reason = reason, units = { unit },
								soonestRemaining = chosenRemaining,
							}
						end)
					end
				end
			end
		end
	end

	local rows = {}
	for _, key in ipairs(order) do
		rows[#rows + 1] = groups[key]
	end
	return rows
end

local function describeRow(row)
	local blessingName = CBAB.Blessings[row.blessing].name
	if row.kind == "greater" then
		if row.status == "missing" then
			return ("%s -- no Greater %s"):format(classLabel(row.class), blessingName)
		end
		return ("%s expiring %s (%s)"):format(blessingName, formatRemaining(row.soonestRemaining), classLabel(row.class))
	end

	local unit = row.units[1]
	local m = CBAB.Roster:Get()[unit]
	local label
	if m and m.isPet then
		label = ("%s's pet"):format(m.owner or "?")
	elseif row.reason == "tank" then
		label = ("%s (tank)"):format(m and m.name or unit)
	else
		label = m and m.name or unit
	end

	if row.status == "missing" then
		return ("%s -- missing %s"):format(label, blessingName)
	end
	return ("%s -- %s expiring %s"):format(label, blessingName, formatRemaining(row.soonestRemaining))
end

-- ============================================================
-- Small visual helpers local to this file.
-- ============================================================

-- 6-hex (no '#', no alpha) class color -- same helper as UI/RosterPage.lua's
-- own classHex, duplicated locally rather than exported from Theme since
-- it's a plain RAID_CLASS_COLORS lookup, not a design token.
local function classHex(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c and c.colorStr then return c.colorStr:sub(3) end
	return (Theme.Colors.textSecondary):gsub("#", "")
end

-- Theme.MixHex returns 3 bare values -- calling it directly as a non-last
-- argument (e.g. `SetBackdropColor(Theme.MixHex(...), 1)`) would silently
-- truncate to just the red channel (see Theme.HexA's own doc comment for
-- why). This wrapper is the same fix, for the color-mix-into-dark recipe
-- this file needs for severity-tinted row fills.
local function MixHexA(hexA, pct, hexB, alpha)
	local r, g, b = Theme.MixHex(hexA, pct, hexB)
	return r, g, b, alpha or 1
end

local function severityColor(status)
	return (status == "missing") and Theme.Colors.red or Theme.Colors.gold
end

local function severityLabel(status)
	return (status == "missing") and "Missing" or "Expiring"
end

-- ============================================================
-- Layout constants (design handoff README.md, "4. Alert window").
-- ============================================================

local WINDOW_WIDTH_DEFAULT = 412
local MIN_WINDOW_WIDTH = 300
local HEADER_HEIGHT = 50
local ROW_PAD = 10
local ROW_HEIGHT = 56
local ROW_GAP = 7
local FOOTER_HEIGHT = 50
local CLEAN_HEIGHT = 150
local SNOOZE_DURATION = 30
local CLEAN_HIDE_DELAY = 3

-- Literal hex, not Theme.Colors keys -- the handoff's alert-specific border/
-- badge shades that don't reuse an existing named token (same posture as
-- UI/Config.lua's literal per-category dot colors).
local BORDER_ACTIVE = "#3a2b2b"
local BORDER_CLEAN = "#24382f"
local BADGE_ICON_RED = "#f0857a"
local BADGE_ICON_TEAL = "#5fe0b8"

-- ============================================================
-- Window chrome: fill/hairline/glow/shadow recipe shared with the other
-- three surfaces (UI/RosterPage.lua, UI/Config.lua), sized/colored per the
-- handoff's ~412px popup. Height is entirely content-driven (see render()
-- below); only width persists/resizes.
-- ============================================================

local window = CreateFrame("Frame", "CBABuffAlert", UIParent)
window:SetSize(WINDOW_WIDTH_DEFAULT, HEADER_HEIGHT + CLEAN_HEIGHT)
window:SetMovable(true)
window:SetResizable(false) -- width-only resize goes through the custom grip below
window:SetClampedToScreen(true)
CBAB:ApplyBackdrop(window, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
Theme.ApplyFill(window, Theme.Colors.barFillTop, Theme.Colors.barFillBottom, 1)
window:SetBackdropBorderColor(Theme.HexA(BORDER_CLEAN, 1))
Theme.ApplyDropShadow(window, { pad = 14, yOffset = 8, alpha = 0.5 })
Theme.ApplyTopHairline(window, Theme.Colors.teal)
Theme.ApplyGlow(window, Theme.Colors.teal, { alpha = 0.08, pad = 14 })
window:Hide() -- no background when empty (spec 11.3): nothing renders until there's a row or a preview

local forceShown = false
local lastRows = {}
local snoozedUntil
local cleanSince

-- ============================================================
-- Header: state badge, title, count badge (active only), Lock/Unlock,
-- close, and a bottom divider.
-- ============================================================

local header = CreateFrame("Frame", nil, window)
header:SetPoint("TOPLEFT", 0, -3) -- clears the 3px top hairline
header:SetPoint("TOPRIGHT", 0, -3)
header:SetHeight(HEADER_HEIGHT)
header:EnableMouse(true)
header:RegisterForDrag("LeftButton")

local headerDivider = header:CreateTexture(nil, "ARTWORK")
headerDivider:SetHeight(1)
headerDivider:SetPoint("BOTTOMLEFT", 0, 0)
headerDivider:SetPoint("BOTTOMRIGHT", 0, 0)
headerDivider:SetColorTexture(Theme.Hex(Theme.Colors.divider))

local badge = CreateFrame("Frame", nil, header)
badge:SetSize(24, 24)
badge:SetPoint("LEFT", 15, 0)
CBAB:ApplyBackdrop(badge, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })

local badgeText = badge:CreateFontString(nil, "OVERLAY")
Theme.StyleText(badgeText, "SectionHeader")
badgeText:SetPoint("CENTER")
badgeText:SetText("!")

local badgeCheck = badge:CreateTexture(nil, "OVERLAY")
badgeCheck:SetSize(12, 12)
badgeCheck:SetPoint("CENTER")
badgeCheck:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
badgeCheck:Hide()

local titleText = header:CreateFontString(nil, "OVERLAY")
Theme.StyleText(titleText, "SectionHeader", { color = "goldText", spacing = 1.5 })
titleText:SetPoint("LEFT", badge, "RIGHT", 11, 0)
titleText:SetText(("Buff Alerts"):upper())

local countBadge = CreateFrame("Frame", nil, header)
countBadge:SetSize(24, 15)
countBadge:SetPoint("LEFT", titleText, "RIGHT", 8, 0)
CBAB:ApplyBackdrop(countBadge, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
countBadge:SetBackdropColor(Theme.HexA(Theme.Colors.red, 0.14))
countBadge:SetBackdropBorderColor(Theme.HexA(Theme.Colors.red, 0.4))

local countBadgeText = countBadge:CreateFontString(nil, "OVERLAY")
Theme.StyleText(countBadgeText, "ColumnLabel", { color = "redText" })
countBadgeText:SetPoint("CENTER")

local closeButton = CreateFrame("Button", nil, header, "UIPanelCloseButton")
closeButton:SetSize(20, 20)
closeButton:SetPoint("RIGHT", -6, 0)

local lockButton = Theme.CreateButton(header, { text = "Lock", width = 54, height = 22 })
lockButton:SetPoint("RIGHT", closeButton, "LEFT", -6, 0)

local resizeGrip = CreateFrame("Button", nil, window)
resizeGrip:SetSize(12, 12)
resizeGrip:SetPoint("BOTTOMRIGHT", -2, 2)
resizeGrip.tex = resizeGrip:CreateTexture(nil, "OVERLAY")
resizeGrip.tex:SetAllPoints()
resizeGrip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")

local function refreshChrome()
	local locked = CBAB.DB:Char().ui.alert.locked
	lockButton.label:SetText(locked and "Unlock" or "Lock")
	if locked then
		lockButton:SetBackdropColor(Theme.HexA(Theme.Colors.gold, 0.12))
		lockButton:SetBackdropBorderColor(Theme.HexA(Theme.Colors.gold, 0.4))
		lockButton.label:SetTextColor(Theme.C("goldText"))
	else
		lockButton:SetBackdropColor(Theme.Hex(Theme.Colors.controlFill))
		lockButton:SetBackdropBorderColor(Theme.Hex(Theme.Colors.borderControlAlt))
		lockButton.label:SetTextColor(Theme.C("textSecondary"))
	end
	resizeGrip:SetShown(not locked)
end
CBAB.Alert_RefreshChrome = refreshChrome

lockButton:SetScript("OnClick", function()
	local charDB = CBAB.DB:Char()
	charDB.ui.alert.locked = not charDB.ui.alert.locked
	refreshChrome()
end)

closeButton:SetScript("OnClick", function()
	forceShown = false
	window:Hide()
end)

local function startDrag()
	if CBAB.DB:Char().ui.alert.locked then return end
	window:StartMoving()
end
local function stopDrag()
	window:StopMovingOrSizing()
	local charDB = CBAB.DB:Char()
	local point, _, _, x, y = window:GetPoint(1)
	charDB.ui.alert.point = point
	charDB.ui.alert.x = x
	charDB.ui.alert.y = y
end
header:SetScript("OnDragStart", startDrag)
header:SetScript("OnDragStop", stopDrag)

resizeGrip:SetScript("OnMouseDown", function(self)
	if CBAB.DB:Char().ui.alert.locked then return end
	self.dragging = true
	self.startX = select(1, GetCursorPosition())
	self.startWidth = window:GetWidth()
end)
resizeGrip:SetScript("OnMouseUp", function(self)
	self.dragging = false
	CBAB.DB:Char().ui.alert.width = window:GetWidth()
end)
resizeGrip:SetScript("OnUpdate", function(self)
	if not self.dragging then return end
	local x = select(1, GetCursorPosition())
	local dx = (x - self.startX) / window:GetEffectiveScale()
	window:SetWidth(math.max(MIN_WINDOW_WIDTH, self.startWidth + dx))
end)

-- ============================================================
-- Force-show (spec 11.5's "Show alert (preview)" button): bypasses both
-- autoHide and the empty-window suppression so the window can be seen and
-- positioned/resized even with nothing currently wrong. Still respects
-- hideInCombat/snooze, same as a real alert would.
-- ============================================================

function CBAB.Alert_SetForceShown(shown)
	forceShown = shown and true or false
	CBAB.Alert_Refresh()
end

function CBAB.Alert_IsForceShown()
	return forceShown
end

-- ============================================================
-- Clean-state content: centered check tile + title + subtitle. Same frame
-- footprint whether it's genuinely clean or just an empty force-shown
-- preview -- only the subtitle text differs (see render() below).
-- ============================================================

local cleanContent = CreateFrame("Frame", nil, window)
cleanContent:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
cleanContent:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
cleanContent:SetHeight(CLEAN_HEIGHT)

local cleanTile = CreateFrame("Frame", nil, cleanContent)
cleanTile:SetSize(52, 52)
cleanTile:SetPoint("TOP", 0, -24)
CBAB:ApplyBackdrop(cleanTile, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
cleanTile:SetBackdropColor(Theme.HexA(Theme.Colors.teal, 0.12))
cleanTile:SetBackdropBorderColor(Theme.HexA(Theme.Colors.teal, 0.4))

local cleanCheck = cleanTile:CreateTexture(nil, "OVERLAY")
cleanCheck:SetSize(26, 26)
cleanCheck:SetPoint("CENTER")
cleanCheck:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
cleanCheck:SetVertexColor(Theme.Hex(Theme.Colors.teal))

local cleanTitle = cleanContent:CreateFontString(nil, "OVERLAY")
Theme.StyleText(cleanTitle, "SectionHeader", { color = "textPrimary" })
cleanTitle:SetPoint("TOP", cleanTile, "BOTTOM", 0, -12)
cleanTitle:SetText("All blessings up")

local cleanSubtitle = cleanContent:CreateFontString(nil, "OVERLAY")
Theme.StyleText(cleanSubtitle, "Body", { color = "textMuted" })
cleanSubtitle:SetPoint("TOP", cleanTitle, "BOTTOM", 0, -6)
cleanSubtitle:SetPoint("LEFT", cleanContent, "LEFT", 20, 0)
cleanSubtitle:SetPoint("RIGHT", cleanContent, "RIGHT", -20, 0)
cleanSubtitle:SetJustifyH("CENTER")
cleanSubtitle:SetWordWrap(true)

-- ============================================================
-- Row container + row pool. Rows anchor on BOTH horizontal edges (not a
-- fixed SetWidth), so dragging the resize grip reflows every row for free --
-- see file header.
-- ============================================================

local rowContainer = CreateFrame("Frame", nil, window)
rowContainer:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
rowContainer:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)

local function createRow(index)
	local row = CreateFrame("Button", "CBABuffAlertRow" .. index, rowContainer, "SecureActionButtonTemplate")
	row:RegisterForClicks("AnyDown")
	row:SetHeight(ROW_HEIGHT)
	CBAB:ApplyBackdrop(row, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	Theme.ApplyHoverHighlight(row, { hoverAlpha = 0.05, pressAlpha = 0.02 })

	-- 3px severity-colored left accent (README: "border-left:3px solid
	-- {severity}").
	row.accent = row:CreateTexture(nil, "ARTWORK")
	row.accent:SetWidth(3)
	row.accent:SetPoint("TOPLEFT", 1, -1)
	row.accent:SetPoint("BOTTOMLEFT", 1, 1)

	-- Everything but the accent/backdrop dims together for a non-mine row
	-- ("otherwise dim and informational", spec 11.3) -- the target button
	-- stays outside this group since targeting works regardless of who's
	-- assigned.
	row.inner = CreateFrame("Frame", nil, row)
	row.inner:SetAllPoints()

	row.nameText = row.inner:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(row.nameText, "Name")
	row.nameText:SetPoint("TOPLEFT", 14, -10)
	row.nameText:SetJustifyH("LEFT")

	row.sevTag = CreateFrame("Frame", nil, row.inner)
	row.sevTag:SetSize(66, 15)
	row.sevTag:SetPoint("LEFT", row.nameText, "RIGHT", 8, 0)
	CBAB:ApplyBackdrop(row.sevTag, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	row.sevTag.text = row.sevTag:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(row.sevTag.text, "ColumnLabel", { spacing = 0.5 })
	row.sevTag.text:SetPoint("CENTER")

	row.chip = CreateFrame("Frame", nil, row.inner)
	row.chip:SetSize(150, 20)
	row.chip:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -8)
	CBAB:ApplyBackdrop(row.chip, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	row.chip.dot = row.chip:CreateTexture(nil, "OVERLAY")
	row.chip.dot:SetSize(7, 7)
	row.chip.dot:SetPoint("LEFT", 7, 0)
	row.chip.text = row.chip:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(row.chip.text, "Body")
	row.chip.text:SetPoint("LEFT", row.chip.dot, "RIGHT", 6, 0)
	row.chip.text:SetJustifyH("LEFT")

	row.byText = row.inner:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(row.byText, "Body", { color = "textMuted" })
	row.byText:SetPoint("LEFT", row.chip, "RIGHT", 7, 0)
	row.byText:SetJustifyH("LEFT")

	row.countdownText = row.inner:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(row.countdownText, "NumericValue")
	row.countdownText:SetPoint("RIGHT", row, "RIGHT", -46, 0)
	row.countdownText:Hide()

	-- Target button (README: "⌖ targets the raider") -- its own secure
	-- button, sitting on top of the row's own cast-click area so a click on
	-- it never also fires the row's cast.
	row.targetBtn = CreateFrame("Button", nil, row, "SecureActionButtonTemplate")
	row.targetBtn:RegisterForClicks("AnyDown")
	row.targetBtn:SetSize(30, 30)
	row.targetBtn:SetPoint("RIGHT", -8, 0)
	CBAB:ApplyBackdrop(row.targetBtn, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	row.targetBtn:SetBackdropColor(Theme.Hex(Theme.Colors.controlFill))
	row.targetBtn:SetBackdropBorderColor(Theme.Hex(Theme.Colors.borderControlAlt))
	local targetLabel = row.targetBtn:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(targetLabel, "ColumnLabel", { color = "textSecondary" })
	targetLabel:SetPoint("CENTER")
	targetLabel:SetText("TGT")
	Theme.ApplyHoverHighlight(row.targetBtn)

	return row
end

local rowPool = {}
local function getRow(index)
	local row = rowPool[index]
	if not row then
		row = createRow(index)
		rowPool[index] = row
	end
	return row
end

-- Applies one computeRows() entry into a pooled row frame, including the
-- secure cast/target attributes.
local function applyRowData(row, data, myName)
	local isGreater = data.kind == "greater"
	local sevHex = severityColor(data.status)

	row:SetBackdropColor(MixHexA(sevHex, 8, Theme.Colors.fieldFill, 1))
	row:SetBackdropBorderColor(MixHexA(sevHex, 30, Theme.Colors.fieldFill, 1))
	row.accent:SetColorTexture(Theme.Hex(sevHex))

	local unit = data.units[1]
	local m = CBAB.Roster:Get()[unit]

	local who, whoClass
	if isGreater then
		who = classLabel(data.class)
		whoClass = data.class
	elseif m and m.isPet then
		who = ("%s's pet"):format(m.owner or "?")
		whoClass = nil
	elseif data.reason == "tank" then
		who = (m and m.name or unit) .. " |cff" .. (Theme.Colors.textMuted):gsub("#", "") .. "(tank)|r"
		whoClass = m and m.class
	else
		who = m and m.name or unit
		whoClass = m and m.class
	end

	row.nameText:SetText(who)
	row.nameText:SetTextColor(Theme.HexA(whoClass and classHex(whoClass) or Theme.Colors.textSecondary, 1))

	row.sevTag:SetBackdropColor(Theme.HexA(sevHex, 0.15))
	row.sevTag:SetBackdropBorderColor(Theme.HexA(sevHex, 0.35))
	row.sevTag.text:SetText(severityLabel(data.status))
	row.sevTag.text:SetTextColor(Theme.HexA(sevHex, 1))

	local tint = Theme.BlessingTint(data.blessing)
	row.chip:SetBackdropColor(tint.fill[1], tint.fill[2], tint.fill[3], 1)
	row.chip:SetBackdropBorderColor(tint.border[1], tint.border[2], tint.border[3], 1)
	row.chip.dot:SetColorTexture(tint.solid[1], tint.solid[2], tint.solid[3])
	row.chip.text:SetText((isGreater and "Greater " or "") .. CBAB.Blessings[data.blessing].name)
	row.chip.text:SetTextColor(tint.label[1], tint.label[2], tint.label[3], 1)

	row.byText:SetText("by " .. (data.assignedTo or "?"))

	if data.status == "expiring" and data.soonestRemaining then
		row.countdownText:SetText(formatRemaining(data.soonestRemaining))
		row.countdownText:SetTextColor(Theme.HexA(sevHex, 1))
		row.countdownText:Show()
	else
		row.countdownText:Hide()
	end

	local mine = data.assignedTo == myName
	row.inner:SetAlpha(mine and 1 or 0.62)

	if mine then
		setAttributeSafe(row, "type1", "spell")
		setAttributeSafe(row, "spell1", spellNameFor(data.blessing, isGreater))
		setAttributeSafe(row, "unit1", unit)
	else
		setAttributeSafe(row, "type1", nil)
		setAttributeSafe(row, "spell1", nil)
	end

	setAttributeSafe(row.targetBtn, "type1", "target")
	setAttributeSafe(row.targetBtn, "unit1", unit)
end

-- ============================================================
-- Footer: Post raid warning (officer-only, gold-outline per the handoff) +
-- Snooze 30s. Active-mode only -- hidden entirely in the clean state.
-- ============================================================

local footer = CreateFrame("Frame", nil, window)
footer:SetPoint("BOTTOMLEFT", 0, 0)
footer:SetPoint("BOTTOMRIGHT", 0, 0)
footer:SetHeight(FOOTER_HEIGHT)

local footerFill = footer:CreateTexture(nil, "BACKGROUND")
footerFill:SetAllPoints()
footerFill:SetColorTexture(Theme.HexA("000000", 0.2))

local footerDivider = footer:CreateTexture(nil, "ARTWORK")
footerDivider:SetHeight(1)
footerDivider:SetPoint("TOPLEFT", 0, 0)
footerDivider:SetPoint("TOPRIGHT", 0, 0)
footerDivider:SetColorTexture(Theme.Hex(Theme.Colors.divider))

local raidWarnButton = Theme.CreateButton(footer, {
	text = "Post raid warning", width = 148, height = 24, variant = "outline-gold",
	onClick = function()
		if not CBAB:Mode().coordinator then
			CBAB:Print("only the leader or an assist can post a raid warning")
			return
		end
		if #lastRows == 0 then
			CBAB:Print("nothing to warn about")
			return
		end
		local lines = {}
		for _, row in ipairs(lastRows) do
			lines[#lines + 1] = describeRow(row)
		end
		SendChatMessage("CBA Buff: " .. table.concat(lines, " | "), "RAID_WARNING")
	end,
})
raidWarnButton:SetPoint("LEFT", 15, 0)

local officerOnlyText = footer:CreateFontString(nil, "OVERLAY")
Theme.StyleText(officerOnlyText, "Body", { color = "textFaint" })
officerOnlyText:SetPoint("LEFT", raidWarnButton, "RIGHT", 8, 0)
officerOnlyText:SetText("officer only")

-- Purely a display-suppression convenience (see file header) -- never
-- touches computeRows/warnings, same as combat suppression already doesn't.
local snoozeButton = Theme.CreateButton(footer, {
	text = ("Snooze %ds"):format(SNOOZE_DURATION), width = 92, height = 24,
	onClick = function()
		snoozedUntil = GetTime() + SNOOZE_DURATION
		window:Hide()
		CBAB:After(SNOOZE_DURATION, function()
			if snoozedUntil and GetTime() >= snoozedUntil then
				snoozedUntil = nil
				CBAB.Alert_Refresh()
			end
		end)
	end,
})
snoozeButton:SetPoint("RIGHT", -15, 0)

-- ============================================================
-- Warning layer 1 (spec 11.4): local screen text + sound, for the
-- viewer's OWN assignments only. Edge-triggered on a problem key first
-- appearing, so it doesn't replay every single refresh while the same
-- problem persists.
-- ============================================================

local RAID_WARNING_SOUND = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959
local knownOwnProblems = {}

local function rowKey(row)
	return row.blessing .. ":" .. table.concat(row.units, ",")
end

local function checkOwnWarnings(rows)
	local charDB = CBAB.DB:Char()
	local warnings = charDB.warnings
	if not warnings.enabled then
		knownOwnProblems = {}
		return
	end

	local myName = UnitName("player")
	local current = {}

	for _, row in ipairs(rows) do
		if row.assignedTo == myName then
			local key = rowKey(row)
			current[key] = true
			if not knownOwnProblems[key] then
				if warnings.sound then
					PlaySound(RAID_WARNING_SOUND)
				end
				if warnings.screenText and RaidNotice_AddMessage and RaidWarningFrame then
					RaidNotice_AddMessage(RaidWarningFrame, describeRow(row), ChatTypeInfo["RAID_WARNING"])
				end
			end
		end
	end

	knownOwnProblems = current
end

-- ============================================================
-- Warning layer 2 (spec 11.4): whisper the responsible paladin. Off by
-- default; when a coordinator enables it, THEIR client does the
-- whispering (they're the one with raid-wide oversight). Throttled to
-- one whisper per paladin per 60s, and never sent in combat.
-- ============================================================

local WHISPER_INTERVAL = 60
local lastWhisperTime = {}

local function checkWhisperWarnings(rows)
	local charDB = CBAB.DB:Char()
	if not charDB.warnings.whisper then return end
	if not CBAB:Mode().coordinator then return end
	if InCombatLockdown() then return end

	local myName = UnitName("player")
	local now = GetTime()

	for _, row in ipairs(rows) do
		if row.assignedTo and row.assignedTo ~= myName then
			local last = lastWhisperTime[row.assignedTo]
			if not last or (now - last) >= WHISPER_INTERVAL then
				SendChatMessage("CBA Buff: " .. describeRow(row), "WHISPER", nil, row.assignedTo)
				lastWhisperTime[row.assignedTo] = now
			end
		end
	end
end

-- Warning layer 3 (spec 11.4, raid warning post) lives on raidWarnButton
-- above -- officer-only, manual, the only SendChatMessage(..., "RAID_WARNING")
-- call anywhere in this file. Automatic raid-channel spam is explicitly
-- prohibited by spec and not implemented anywhere.

-- ============================================================
-- Render: lays out the header/body/footer for the current row set and
-- resizes the window to fit. Height is always fully recomputed (no stored
-- height) -- only width persists, via the resize grip above.
-- ============================================================

local function render(rows)
	local hasRows = #rows > 0

	Theme.ApplyTopHairline(window, hasRows and Theme.Colors.red or Theme.Colors.teal)
	Theme.ApplyGlow(window, hasRows and Theme.Colors.red or Theme.Colors.teal, { alpha = 0.08, pad = 14 })
	window:SetBackdropBorderColor(Theme.HexA(hasRows and BORDER_ACTIVE or BORDER_CLEAN, 1))

	badge:SetBackdropColor(Theme.HexA(hasRows and Theme.Colors.red or Theme.Colors.teal, 0.16))
	badge:SetBackdropBorderColor(Theme.HexA(hasRows and Theme.Colors.red or Theme.Colors.teal, 0.45))
	badgeText:SetShown(hasRows)
	badgeCheck:SetShown(not hasRows)
	if hasRows then
		badgeText:SetTextColor(Theme.HexA(BADGE_ICON_RED, 1))
	else
		badgeCheck:SetVertexColor(Theme.Hex(BADGE_ICON_TEAL))
	end
	countBadge:SetShown(hasRows)
	if hasRows then countBadgeText:SetText(tostring(#rows)) end

	raidWarnButton:SetShown(hasRows and CBAB:Mode().coordinator and true or false)
	footer:SetShown(hasRows)
	rowContainer:SetShown(hasRows)
	cleanContent:SetShown(not hasRows)

	if hasRows then
		local myName = UnitName("player")
		for i, data in ipairs(rows) do
			local row = getRow(i)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", rowContainer, "TOPLEFT", ROW_PAD, -(ROW_PAD + (i - 1) * (ROW_HEIGHT + ROW_GAP)))
			row:SetPoint("TOPRIGHT", rowContainer, "TOPRIGHT", -ROW_PAD, -(ROW_PAD + (i - 1) * (ROW_HEIGHT + ROW_GAP)))
			applyRowData(row, data, myName)
			row:Show()
		end
		for i = #rows + 1, #rowPool do
			rowPool[i]:Hide()
		end

		local rowsHeight = #rows * ROW_HEIGHT + (#rows - 1) * ROW_GAP + ROW_PAD * 2
		rowContainer:SetHeight(rowsHeight)
		window:SetHeight(HEADER_HEIGHT + rowsHeight + FOOTER_HEIGHT)
	else
		for i = 1, #rowPool do
			rowPool[i]:Hide()
		end

		local ui = CBAB.DB:Char().ui.alert
		if forceShown then
			cleanSubtitle:SetText("Previewing -- nothing to report right now")
		elseif ui.autoHide then
			cleanSubtitle:SetText(("Nobody's missing anything. Hiding in %ds..."):format(CLEAN_HIDE_DELAY))
		else
			cleanSubtitle:SetText("Nobody's missing anything.")
		end

		window:SetHeight(HEADER_HEIGHT + CLEAN_HEIGHT)
	end
end

-- ============================================================
-- Show/hide timing (spec 11.3): reappears instantly on a problem, but
-- only hides after a short clean interval, so a one-flush blip doesn't
-- flicker the window. A pending hide is cancelled just by clearing
-- cleanSince -- no timer cancellation needed, the deferred check just
-- no-ops if it's no longer clean when it fires. Snooze suppresses
-- everything, the same way hideInCombat already does.
-- ============================================================

local function updateVisibility(hasRows)
	if snoozedUntil and GetTime() < snoozedUntil then
		window:Hide()
		return
	end

	if hasRows or forceShown then
		cleanSince = nil
		local ui = CBAB.DB:Char().ui.alert
		if ui.hideInCombat and InCombatLockdown() then
			window:Hide()
		else
			window:Show()
		end
		return
	end

	if not cleanSince then
		cleanSince = GetTime()
		CBAB:After(CLEAN_HIDE_DELAY, function()
			if cleanSince and (GetTime() - cleanSince) >= CLEAN_HIDE_DELAY - 0.05 then
				window:Hide()
			end
		end)
	end
end

-- ============================================================
-- Refresh: the single entry point every event below funnels into.
-- ============================================================

local function refresh()
	local rows = computeRows()
	lastRows = rows

	render(rows)
	updateVisibility(#rows > 0)

	checkOwnWarnings(rows)
	checkWhisperWarnings(rows)
end
CBAB.Alert_Refresh = refresh

CBAB:On("BUFF_STATE_CHANGED", "alert:refresh", refresh)
CBAB:On("ASSIGNMENT_CHANGED", "alert:refresh-assignment", refresh)
CBAB:On("ROSTER_CHANGED", "alert:refresh-roster", refresh)
CBAB:On("UNIT_PET", "alert:refresh-pet", refresh) -- re-arm on pet resurrect/summon (spec 11.3)

-- Suppressed in combat by default, toggleable (spec 11.3) -- re-evaluate
-- visibility (not the underlying data) the instant combat starts/ends.
CBAB:On("PLAYER_REGEN_DISABLED", "alert:combat-hide", function()
	if CBAB.DB:Char().ui.alert.hideInCombat then
		window:Hide()
	end
end)
CBAB:On("PLAYER_REGEN_ENABLED", "alert:combat-show", function()
	updateVisibility(#lastRows > 0)
end)

-- ============================================================
-- Position from CBABuffCharDB.ui.alert.
-- ============================================================

CBAB:On("ADDON_LOADED", "alert:init", function(loadedAddon)
	if loadedAddon ~= ADDON then return end
	local ui = CBAB.DB:Char().ui.alert
	window:ClearAllPoints()
	window:SetPoint(ui.point or "CENTER", UIParent, ui.point or "CENTER", ui.x or 0, ui.y or 200)
	window:SetScale(ui.scale or 1.0)
	window:SetWidth(ui.width or WINDOW_WIDTH_DEFAULT)
	refreshChrome()
	CBAB:Off("ADDON_LOADED", "alert:init")
end)
