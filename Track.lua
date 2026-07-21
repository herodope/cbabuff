local ADDON, CBAB = ...

-- CBAB.Track:Start()  CBAB.Track:Stop()
-- CBAB.Track:StateFor(unit) -> { [blessingID] = {expires, caster, isGreater} }
-- CBAB.Track:Missing() -> { {unit, blessing, assignedTo} }
--
-- This module exists specifically to avoid the three failure modes named
-- in spec 9: bucketing UNIT_AURA into a full roster rebuild, an
-- unconditional repeating timer, and matching auras by name/rank string.
-- Every design choice below traces back to one of those.

CBAB.Track = {}

local frame = CBAB.frame -- Core.lua's one and only event frame; no new frame here.

-- ============================================================
-- Aura API shim (spec 9): NOTHING outside this block may call
-- C_UnitAuras.* or UnitAura directly. Detected once at load.
-- ============================================================

local usingModernAPI = (C_UnitAuras ~= nil and C_UnitAuras.GetAuraDataByIndex ~= nil)

local shim = {}

if usingModernAPI then
	function shim.GetAura(unit, index, filter)
		local data = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
		if not data then return nil end
		return { spellId = data.spellId, expirationTime = data.expirationTime, source = data.sourceUnit }
	end
else
	function shim.GetAura(unit, index, filter)
		local name, _, _, _, _, expirationTime, source, _, _, spellId = UnitAura(unit, index, filter)
		if not name then return nil end
		return { spellId = spellId, expirationTime = expirationTime, source = source }
	end
end

-- ============================================================
-- Reverse lookup: spellID -> {blessingId, isGreater}. Built once from
-- Data/Spells.lua's pure data (spec: spell ID matching only, never name
-- or rank string).
-- ============================================================

local spellToBlessing = {}
for blessingId, blessing in pairs(CBAB.Blessings) do
	for _, spellId in ipairs(blessing.normalIDs) do
		spellToBlessing[spellId] = { id = blessingId, isGreater = false }
	end
	for _, spellId in ipairs(blessing.greaterIDs) do
		spellToBlessing[spellId] = { id = blessingId, isGreater = true }
	end
end

-- ============================================================
-- State
-- ============================================================

local started = false
local trackedUnits = {} -- units Track cares about at all (roster + pets)
local dirty = {} -- per-unit dirty set (spec 9: never a full rebuild)
local state = {} -- [unit] = { [blessingId] = {expires, caster, isGreater} }

local perf = {
	auraEventsReceived = 0,
	eventsCoalesced = 0,
	flushCount = 0,
	lastFlushMs = 0,
}

-- ============================================================
-- Scanning a single dirty unit (only ever done for the unit that actually
-- changed -- spec 9's per-unit dirty set, not a roster-wide rescan).
-- ============================================================

local function scanUnit(unit)
	local unitState = {}
	local index = 1
	while true do
		local aura = shim.GetAura(unit, index, "HELPFUL")
		if not aura then break end
		if aura.spellId then
			local blessing = spellToBlessing[aura.spellId]
			if blessing then
				unitState[blessing.id] = {
					expires = aura.expirationTime,
					caster = aura.source,
					isGreater = blessing.isGreater,
				}
			end
		end
		index = index + 1
	end
	return unitState
end

-- ============================================================
-- Coalesced flush (spec 9): a single OnUpdate on the shared frame, at
-- most every 0.25s, unregistering itself when idle. No always-on timer.
-- ============================================================

local FLUSH_INTERVAL = 0.25
local accumulated = 0

local function flush()
	local startMs = debugprofilestop()

	for unit in pairs(dirty) do
		state[unit] = scanUnit(unit)
		dirty[unit] = nil
	end

	perf.flushCount = perf.flushCount + 1
	perf.lastFlushMs = debugprofilestop() - startMs

	CBAB:Fire("BUFF_STATE_CHANGED")
end

local function onUpdate(_, elapsed)
	accumulated = accumulated + elapsed
	if accumulated < FLUSH_INTERVAL then return end
	accumulated = 0

	-- spec 9: no work at all in combat except duration-warning evaluation,
	-- which lives elsewhere (not built yet). The dirty set just keeps
	-- accumulating from UNIT_AURA (cheap, event-driven) until combat ends.
	if InCombatLockdown() then return end

	if next(dirty) == nil then
		frame:SetScript("OnUpdate", nil)
		return
	end

	flush()
end

local function ensureFlushing()
	if not frame:GetScript("OnUpdate") then
		frame:SetScript("OnUpdate", onUpdate)
	end
end

-- ============================================================
-- Dirty marking (spec 9): UNIT_AURA marks exactly one unit dirty. When
-- the modern updateInfo payload is present, added auras that are none of
-- ours (and nothing updated/removed) let the event be coalesced away
-- without even marking the unit dirty -- this is what gives a high
-- coalesce ratio during trash, where most aura churn on a raid unit is
-- unrelated debuffs/procs we don't track at all.
-- ============================================================

local function updateInfoMightBeRelevant(updateInfo)
	if updateInfo.addedAuras then
		for _, aura in ipairs(updateInfo.addedAuras) do
			if aura.spellId and CBAB.WatchedSpellIDs[aura.spellId] then
				return true
			end
		end
	end
	-- Updated/removed instance IDs aren't cheaply attributable to a spell
	-- without another API call, so treat their presence as relevant.
	if updateInfo.updatedAuraInstanceIDs and #updateInfo.updatedAuraInstanceIDs > 0 then
		return true
	end
	if updateInfo.removedAuraInstanceIDs and #updateInfo.removedAuraInstanceIDs > 0 then
		return true
	end
	return false
end

local function onUnitAura(unit, updateInfo)
	perf.auraEventsReceived = perf.auraEventsReceived + 1

	if not trackedUnits[unit] then return end

	if dirty[unit] then
		perf.eventsCoalesced = perf.eventsCoalesced + 1
		return
	end

	if updateInfo and updateInfo.isFullUpdate == false and not updateInfoMightBeRelevant(updateInfo) then
		perf.eventsCoalesced = perf.eventsCoalesced + 1
		return
	end

	dirty[unit] = true
	ensureFlushing()
end

-- ============================================================
-- Tracked-unit set follows the roster, event-driven (ROSTER_CHANGED),
-- never polled. Pets are only ever in CBAB.Roster:Get() when the active
-- profile has petsEnabled (Roster.lua's own job), so this needs no
-- separate check here.
-- ============================================================

local function rebuildTrackedUnits()
	trackedUnits = {}
	for unit in pairs(CBAB.Roster:Get()) do
		trackedUnits[unit] = true
	end
end

-- ============================================================
-- Start / Stop
-- ============================================================

function CBAB.Track:Start()
	if started then return end
	started = true

	rebuildTrackedUnits()

	CBAB:On("UNIT_AURA", "track:aura", onUnitAura)
	CBAB:On("ROSTER_CHANGED", "track:roster", rebuildTrackedUnits)
	-- Catch up promptly once combat drops, rather than waiting up to
	-- 0.25s for the next incidental flush tick.
	CBAB:On("PLAYER_REGEN_ENABLED", "track:combat", function()
		if next(dirty) ~= nil then
			ensureFlushing()
		end
	end)
end

function CBAB.Track:Stop()
	if not started then return end
	started = false

	CBAB:Off("UNIT_AURA", "track:aura")
	CBAB:Off("ROSTER_CHANGED", "track:roster")
	CBAB:Off("PLAYER_REGEN_ENABLED", "track:combat")
	frame:SetScript("OnUpdate", nil)

	dirty = {}
	state = {}
	trackedUnits = {}
end

-- Tracking is only useful once there's a roster to track, so it follows
-- group membership -- event-driven, not an explicit always-on default.
local wasInGroup = IsInGroup()
CBAB:On("GROUP_ROSTER_UPDATE", "track:autostart", function()
	local nowInGroup = IsInGroup()
	if nowInGroup and not wasInGroup then
		CBAB.Track:Start()
	elseif not nowInGroup and wasInGroup then
		CBAB.Track:Stop()
	end
	wasInGroup = nowInGroup
end)
if wasInGroup then
	CBAB.Track:Start()
end

-- ============================================================
-- Accessors
-- ============================================================

function CBAB.Track:StateFor(unit)
	return state[unit] or {}
end

-- Cross-references the active assignment against tracked state: for each
-- class-wide greater, every member of that class is assigned it, EXCEPT
-- where an override from the SAME caster replaces it on that one target
-- (rule 4). Reports anyone who should be holding a blessing but isn't.
function CBAB.Track:Missing()
	local profile = CBAB.DB:Profile()
	if not profile or not profile.assignment then return {} end
	local assignment = profile.assignment
	local roster = CBAB.Roster:Get()

	local nameToUnit = {}
	for unit, m in pairs(roster) do
		nameToUnit[m.name] = unit
	end

	-- [unit] = { [blessingId] = casterName }
	local assigned = {}

	for casterName, entries in pairs(assignment.greaters or {}) do
		for class, blessing in pairs(entries) do
			for unit, m in pairs(roster) do
				if not m.isPet and m.class == class then
					assigned[unit] = assigned[unit] or {}
					assigned[unit][blessing] = casterName
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
		end
	end

	local missing = {}
	for unit, blessings in pairs(assigned) do
		local unitState = state[unit]
		for blessingId, casterName in pairs(blessings) do
			if not (unitState and unitState[blessingId]) then
				missing[#missing + 1] = { unit = unit, blessing = blessingId, assignedTo = casterName }
			end
		end
	end
	return missing
end

-- ============================================================
-- /cbab perf
-- ============================================================

CBAB.SlashCommands.perf = function()
	CBAB:Print(("aura API: %s"):format(usingModernAPI and "C_UnitAuras (modern)" or "UnitAura (legacy)"))
	CBAB:Print(("tracking: %s"):format(started and "running" or "stopped"))
	CBAB:Print(("aura events received: %d"):format(perf.auraEventsReceived))
	CBAB:Print(("events coalesced away: %d"):format(perf.eventsCoalesced))
	CBAB:Print(("flush count: %d"):format(perf.flushCount))
	CBAB:Print(("last flush: %.3fms"):format(perf.lastFlushMs))
end
