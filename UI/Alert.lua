local ADDON, CBAB = ...

-- The alert window (spec 11.3) and the three warning layers (spec 11.4).
-- Everything here is driven by CBAB events -- BUFF_STATE_CHANGED,
-- ASSIGNMENT_CHANGED, ROSTER_CHANGED, UNIT_PET -- never polled.

-- ============================================================
-- Secure attribute writes: same combat-safe pattern as UI/Bar.lua. Rows
-- are click-to-cast and therefore secure buttons; nothing here ever calls
-- SetAttribute while InCombatLockdown().
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
-- Window + row pool
-- ============================================================

local window = CreateFrame("Frame", "CBABuffAlert", UIParent)
window:SetSize(280, 20)
window:SetMovable(true)
window:SetResizable(false) -- resizing goes through the custom grip below, not native frame resize
window:SetClampedToScreen(true)
CBAB:ApplyBackdrop(window, {
	bgFile = "Interface\\Buttons\\WHITE8x8",
	edgeFile = "Interface\\Buttons\\WHITE8x8",
	edgeSize = 1,
})
window:SetBackdropColor(0, 0, 0, 0.6)
window:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
window:Hide() -- no background when empty (spec 11.3): nothing renders until there's a row

-- ============================================================
-- Chrome: title, lock/unlock (synced with Config's checkbox through the
-- shared ui.alert.locked field, same pattern as UI/Bar.lua), close, and a
-- resize grip. Locking disables both dragging and resizing at once, same
-- wording and behaviour as the bar's lock.
-- ============================================================

local TITLE_HEIGHT = 18
local WINDOW_PADDING = 20 -- window width minus row width
local TEXT_MARGIN = 12 -- row width minus text width
local MIN_WINDOW_WIDTH = 160

local titleBar = CreateFrame("Frame", nil, window)
titleBar:SetPoint("TOPLEFT", 0, 0)
titleBar:SetPoint("TOPRIGHT", 0, 0)
titleBar:SetHeight(TITLE_HEIGHT)
titleBar:EnableMouse(true)

local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
titleText:SetPoint("LEFT", 6, 0)
titleText:SetText("Alerts")

local closeButton = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
closeButton:SetSize(16, 16)
closeButton:SetPoint("RIGHT", 0, 0)

local lockButton = CreateFrame("Button", nil, titleBar, "UIPanelButtonTemplate")
lockButton:SetSize(44, 16)
lockButton:SetPoint("RIGHT", closeButton, "LEFT", -4, 0)

local resizeGrip = CreateFrame("Button", nil, window)
resizeGrip:SetSize(12, 12)
resizeGrip:SetPoint("BOTTOMRIGHT", -2, 2)
resizeGrip.tex = resizeGrip:CreateTexture(nil, "OVERLAY")
resizeGrip.tex:SetAllPoints()
resizeGrip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")

local function refreshChrome()
	local locked = CBAB.DB:Char().ui.alert.locked
	lockButton:SetText(locked and "Unlock" or "Lock")
	resizeGrip:SetShown(not locked)
end
CBAB.Alert_RefreshChrome = refreshChrome

lockButton:SetScript("OnClick", function()
	local charDB = CBAB.DB:Char()
	charDB.ui.alert.locked = not charDB.ui.alert.locked
	refreshChrome()
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
titleBar:RegisterForDrag("LeftButton")
titleBar:SetScript("OnDragStart", startDrag)
titleBar:SetScript("OnDragStop", stopDrag)

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
	CBAB.Alert_LayoutRows()
end)

-- ============================================================
-- Force-show (spec ask): Config's "Show alert now" button bypasses both
-- autoHide and the empty-window suppression so the window can be seen and
-- positioned/resized even with nothing currently wrong.
-- ============================================================

local forceShown = false

local previewText = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
previewText:SetPoint("TOPLEFT", 6, -(TITLE_HEIGHT + 2))
previewText:SetText("No active alerts (preview)")
previewText:Hide()

function CBAB.Alert_SetForceShown(shown)
	forceShown = shown and true or false
	CBAB.Alert_Refresh()
end

function CBAB.Alert_IsForceShown()
	return forceShown
end

closeButton:SetScript("OnClick", function()
	forceShown = false
	window:Hide()
end)

-- ============================================================
-- Window + row pool
-- ============================================================

local ROW_HEIGHT = 18
local rowPool = {}

local function getRowFrame(index)
	local row = rowPool[index]
	if not row then
		row = CreateFrame("Button", "CBABuffAlertRow" .. index, window, "SecureActionButtonTemplate")
		row:RegisterForClicks("AnyDown")
		row:SetSize(260, ROW_HEIGHT)
		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		row.text:SetPoint("LEFT", 6, 0)
		row.text:SetJustifyH("LEFT")
		row.text:SetWidth(248)
		rowPool[index] = row
	end
	return row
end

-- Reflows every pooled row (including hidden ones, so they're already
-- correct if reused) to the window's current width -- called after a
-- refresh and live while dragging the resize grip.
function CBAB.Alert_LayoutRows()
	local rowWidth = math.max(20, window:GetWidth() - WINDOW_PADDING)
	for _, row in pairs(rowPool) do
		row:SetWidth(rowWidth)
		row.text:SetWidth(math.max(10, rowWidth - TEXT_MARGIN))
	end
end

local function populateWindow(rows)
	local myName = UnitName("player")

	for i, data in ipairs(rows) do
		local row = getRowFrame(i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", window, "TOPLEFT", 0, -(TITLE_HEIGHT + (i - 1) * ROW_HEIGHT))
		row:Show()
		row.text:SetText(describeRow(data))

		local mine = data.assignedTo == myName
		if mine then
			row.text:SetTextColor(1, 1, 1)
			-- Greater rows cast on any affected unit (class-wide); override
			-- rows are always a normal cast on that one specific unit.
			setAttributeSafe(row, "type1", "spell")
			setAttributeSafe(row, "spell1", spellNameFor(data.blessing, data.kind == "greater"))
			setAttributeSafe(row, "unit1", data.units[1])
		else
			row.text:SetTextColor(0.55, 0.55, 0.55)
			setAttributeSafe(row, "type1", nil)
			setAttributeSafe(row, "spell1", nil)
		end
	end

	for i = #rows + 1, #rowPool do
		rowPool[i]:Hide()
	end

	CBAB.Alert_LayoutRows()
	previewText:SetShown(#rows == 0 and forceShown)
	window:SetHeight(TITLE_HEIGHT + math.max(#rows, 1) * ROW_HEIGHT)
end

-- ============================================================
-- Show/hide timing (spec 11.3): reappears instantly on a problem, but
-- only hides after a short clean interval, so a one-flush blip doesn't
-- flicker the window. A pending hide is cancelled just by clearing
-- cleanSince -- no timer cancellation needed, the deferred check just
-- no-ops if it's no longer clean when it fires.
-- ============================================================

local CLEAN_HIDE_DELAY = 3
local cleanSince

local function updateVisibility(hasRows)
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

-- ============================================================
-- Warning layer 3 (spec 11.4): raid warning post. Officer-only, and the
-- ONLY way this ever fires is this one manual button -- nothing else in
-- this file calls SendChatMessage on RAID_WARNING. Automatic raid-channel
-- spam is explicitly prohibited by spec and not implemented anywhere.
-- ============================================================

local lastRows = {}

local raidWarnButton = CreateFrame("Button", "CBABuffAlertRaidWarnButton", window, "UIPanelButtonTemplate")
raidWarnButton:SetSize(56, 18)
raidWarnButton:SetPoint("BOTTOMRIGHT", window, "TOPRIGHT", 0, 2)
raidWarnButton:SetText("Post")
raidWarnButton:Hide()
raidWarnButton:SetScript("OnClick", function()
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
end)

-- ============================================================
-- Refresh: the single entry point every event below funnels into.
-- ============================================================

local function refresh()
	local rows = computeRows()
	lastRows = rows

	populateWindow(rows)
	updateVisibility(#rows > 0)
	raidWarnButton:SetShown(CBAB:Mode().coordinator and #rows > 0)

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
	window:SetWidth(ui.width or 280)
	CBAB.Alert_LayoutRows()
	refreshChrome()
	CBAB:Off("ADDON_LOADED", "alert:init")
end)
