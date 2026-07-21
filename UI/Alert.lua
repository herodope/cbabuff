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

	for unit, blessings in pairs(assigned) do
		local m = roster[unit]
		if m then
			-- Pet suppression (spec 11.3): no row when pets are off, or
			-- when this specific pet doesn't exist or is dead.
			local suppressed = m.isPet and (not petsEnabled or not UnitExists(unit) or UnitIsDead(unit))

			if not suppressed then
				local unitState = CBAB.Track:StateFor(unit)
				for blessingId, casterName in pairs(blessings) do
					local record = unitState[blessingId]
					local status, remaining
					if not record then
						status = "missing"
					else
						remaining = (record.expires or 0) - GetTime()
						if remaining <= threshold then
							status = "expiring"
						end
					end

					if status then
						local info = reasonFor[unit] and reasonFor[unit][blessingId]
						local reason = info and info.reason or "greater"
						local class = info and info.class or m.class

						if reason == "greater" then
							local key = ("greater:%s:%s:%s"):format(class, blessingId, status)
							local row = group(key, function()
								return {
									kind = "greater", blessing = blessingId, assignedTo = casterName,
									status = status, class = class, units = {},
								}
							end)
							row.units[#row.units + 1] = unit
							if remaining and (not row.soonestRemaining or remaining < row.soonestRemaining) then
								row.soonestRemaining = remaining
							end
						else
							local key = ("individual:%s:%s"):format(unit, blessingId)
							group(key, function()
								return {
									kind = "individual", blessing = blessingId, assignedTo = casterName,
									status = status, reason = reason, units = { unit },
									soonestRemaining = remaining,
								}
							end)
						end
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
CBAB:ApplyBackdrop(window, {
	bgFile = "Interface\\Buttons\\WHITE8x8",
	edgeFile = "Interface\\Buttons\\WHITE8x8",
	edgeSize = 1,
})
window:SetBackdropColor(0, 0, 0, 0.6)
window:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
window:Hide() -- no background when empty (spec 11.3): nothing renders until there's a row

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

local function populateWindow(rows)
	local myName = UnitName("player")

	for i, data in ipairs(rows) do
		local row = getRowFrame(i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", window, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
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

	window:SetSize(280, math.max(1, #rows) * ROW_HEIGHT)
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
	if hasRows then
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
	CBAB:Off("ADDON_LOADED", "alert:init")
end)
