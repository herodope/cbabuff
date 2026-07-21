local ADDON, CBAB = ...

-- CBAB.Roster:Get() -> { [unit] = {name, class, unit, isTank, isPet, owner} }
-- (entries also carry `nameRealm`, needed to join a live member to their
-- CBAB.Cap capabilityCache entry -- see Solve.lua)
-- CBAB.Roster:Paladins() -> {}
-- CBAB.Roster:Tanks() -> {}
-- CBAB.Roster:HunterPets() -> {}
-- CBAB.Roster:ClassCounts() -> { WARRIOR=6, ... }
-- CBAB.Roster:MatchProfile() -> profileName, confidence
--
-- Rebuilt only on GROUP_ROSTER_UPDATE and UNIT_PET (never polled -- spec
-- 9's "no work without an event" rule). Every accessor below just reads
-- the cache built by the last rebuild; none of them touch a game API.

CBAB.Roster = {}

local cache = {}

local function groupUnits()
	local units = {}
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			units[#units + 1] = "raid" .. i
		end
	elseif IsInGroup() then
		units[#units + 1] = "player"
		for i = 1, GetNumGroupMembers() - 1 do
			units[#units + 1] = "party" .. i
		end
	else
		units[#units + 1] = "player"
	end
	return units
end

local function petUnitFor(unit)
	if unit == "player" then return "pet" end
	local prefix, index = unit:match("^(%a-)(%d+)$")
	if prefix == "raid" then return "raidpet" .. index end
	if prefix == "party" then return "partypet" .. index end
	return nil
end

-- Manual tank flags live on the active profile's roster (spec: "unioned
-- with manual tank flags on the active profile's roster"), keyed by name
-- since that's what the roster page edits.
local function manualTankNames()
	local names = {}
	local profile = CBAB.DB:Profile()
	if profile then
		for _, r in ipairs(profile.roster or {}) do
			if r.tank then
				names[r.name] = true
			end
		end
	end
	return names
end

local function petsEnabled()
	local profile = CBAB.DB:Profile()
	return profile ~= nil and profile.wants ~= nil and profile.wants.petsEnabled == true
end

local function rebuild()
	local newCache = {}
	local manualTanks = manualTankNames()
	local includePets = petsEnabled()

	for _, unit in ipairs(groupUnits()) do
		if UnitExists(unit) then
			local name, realm = UnitName(unit)
			local _, classToken = UnitClass(unit)
			local isTank = GetPartyAssignment("MAINTANK", unit)
				or GetPartyAssignment("MAINASSIST", unit)
				or manualTanks[name]
				or false

			newCache[unit] = {
				name = name,
				-- Same-realm units return "" for realm; capabilityCache is
				-- keyed name-realm (spec 6.2), so this is what joins a live
				-- roster member to their cached capability entry.
				nameRealm = name .. "-" .. ((realm and realm ~= "") and realm or GetRealmName()),
				class = classToken,
				unit = unit,
				isTank = isTank and true or false,
				isPet = false,
			}

			-- Hunter pets only (spec 2, 5.6) -- warlock/other pets never
			-- tracked. Skipped entirely when the profile has pets off.
			if includePets and classToken == "HUNTER" then
				local petUnit = petUnitFor(unit)
				if petUnit and UnitExists(petUnit) then
					newCache[petUnit] = {
						name = UnitName(petUnit),
						class = "HUNTER_PET",
						unit = petUnit,
						isTank = false,
						isPet = true,
						owner = name,
					}
				end
			end
		end
	end

	cache = newCache
	CBAB:Fire("ROSTER_CHANGED")
end

CBAB:On("GROUP_ROSTER_UPDATE", "roster:rebuild", rebuild)
CBAB:On("UNIT_PET", "roster:rebuild", rebuild)

-- ============================================================
-- Accessors
-- ============================================================

function CBAB.Roster:Get()
	return cache
end

function CBAB.Roster:Paladins()
	local list = {}
	for _, m in pairs(cache) do
		if not m.isPet and m.class == "PALADIN" then
			list[#list + 1] = m
		end
	end
	return list
end

function CBAB.Roster:Tanks()
	local list = {}
	for _, m in pairs(cache) do
		if m.isTank then
			list[#list + 1] = m
		end
	end
	return list
end

function CBAB.Roster:HunterPets()
	local list = {}
	for _, m in pairs(cache) do
		if m.isPet then
			list[#list + 1] = m
		end
	end
	return list
end

function CBAB.Roster:ClassCounts()
	local counts = {}
	for _, m in pairs(cache) do
		if not m.isPet then
			counts[m.class] = (counts[m.class] or 0) + 1
		end
	end
	return counts
end

-- Scores every stored profile by name overlap with the live raid; returns
-- the best candidate and its confidence (0-1) regardless of the 60%
-- threshold, so the caller decides whether to actually auto-switch (spec
-- 7's "best match above 60% ... with a chat notice and manual override").
function CBAB.Roster:MatchProfile()
	local liveNames, liveCount = {}, 0
	for _, m in pairs(cache) do
		if not m.isPet then
			liveNames[m.name] = true
			liveCount = liveCount + 1
		end
	end

	if liveCount == 0 then
		return nil, 0
	end

	local bestName, bestConfidence = nil, 0
	for name, profile in pairs(CBAB.DB:Profiles()) do
		local matches = 0
		for _, r in ipairs(profile.roster or {}) do
			if liveNames[r.name] then
				matches = matches + 1
			end
		end
		local confidence = matches / liveCount
		if confidence > bestConfidence then
			bestName, bestConfidence = name, confidence
		end
	end

	return bestName, bestConfidence
end

-- ============================================================
-- /cbab dump roster
-- ============================================================

CBAB.DumpHandlers.roster = function()
	CBAB:Print("-- Roster --")
	for unit, m in pairs(cache) do
		if m.isPet then
			CBAB:Print(("  %s: %s (pet of %s)"):format(unit, m.name, m.owner))
		else
			CBAB:Print(("  %s: %s [%s]%s"):format(unit, m.name, m.class, m.isTank and " TANK" or ""))
		end
	end

	for class, n in pairs(CBAB.Roster:ClassCounts()) do
		CBAB:Print(("  %s x%d"):format(class, n))
	end

	local profileName, confidence = CBAB.Roster:MatchProfile()
	if profileName then
		CBAB:Print(("  best profile match: %s (%d%%)"):format(profileName, math.floor(confidence * 100)))
	end
end
