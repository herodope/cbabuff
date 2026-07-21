local ADDON, CBAB = ...

-- CBAB.Cap:ScanSelf() -> entry
-- CBAB.Cap:Get(nameRealm, group) -> record, source, age   -- group defaults to active
-- CBAB.Cap:GetEntry(nameRealm) -> entry
-- CBAB.Cap:Put(nameRealm, entry, source)
-- CBAB.Cap:DiffAgainstPlan(profile) -> {changes}
-- CBAB.Cap:AffectsPlan(nameRealm, oldEntry, newEntry) -> bool
--
-- entry shape (spec 10): { class, activeGroup, groups = { [n] = {spec,
-- kings, sanctuary, impMight, impWisdom} }, source, seen, addonVersion }
--
-- IMPORTANT (verify in-game): GetTalentInfo/GetTalentTabInfo are called
-- here with a 5th `talentGroup` argument to read the INACTIVE spec's
-- talents (spec 6.1). I sourced this signature from Wrath-era API docs
-- (warcraft.wiki.gg) since I couldn't find a TBC Anniversary addon source
-- using it directly, and passing an extra argument a function doesn't use
-- fails silently rather than erroring -- if this is wrong, both groups
-- will silently read as the ACTIVE group instead of erroring. Confirm with
-- /cbab dump talents while parked in each spec, or immediately after a
-- swap, before trusting the inactive-group numbers.

CBAB.Cap = {}

-- ============================================================
-- Talent scanning (spec 6.1)
-- ============================================================

-- Builds a textureID -> rank map for one talent group by walking every
-- tab/talent via GetTalentInfo, then reads each blessing's OWN texture
-- (Data/Spells.lua) out of that map -- the improved talent shares its icon
-- with the base blessing, so this needs no hardcoded tab/index coordinates.
-- Also derives the cosmetic spec label from whichever tab holds the most
-- points, using that tab's own name (no hardcoded tab->spec table either).
local function scanGroup(group)
	local textureRank = {}
	local bestTabName, bestPoints = nil, -1

	for tab = 1, GetNumTalentTabs() do
		local tabName, _, pointsSpent = GetTalentTabInfo(tab, false, false, group)
		pointsSpent = pointsSpent or 0
		if pointsSpent > bestPoints then
			bestTabName, bestPoints = tabName, pointsSpent
		end

		for index = 1, GetNumTalents(tab) do
			local _, texture, _, _, rank = GetTalentInfo(tab, index, false, false, group)
			if texture then
				textureRank[texture] = rank or 0
			end
		end
	end

	local function rankOf(blessingId)
		local texture = CBAB.Blessings[blessingId].texture
		return textureRank[texture] or 0
	end

	return {
		spec = bestTabName and bestTabName:lower() or nil,
		kings = rankOf("kings") > 0,
		sanctuary = rankOf("sanctuary") > 0,
		impMight = rankOf("might"),
		impWisdom = rankOf("wisdom"),
	}
end

function CBAB.Cap:ScanSelf()
	local _, classToken = UnitClass("player")
	local numGroups = GetNumTalentGroups() or 1
	local activeGroup = GetActiveTalentGroup() or 1

	local groups = {}
	for group = 1, numGroups do
		groups[group] = scanGroup(group)
	end

	return {
		class = classToken,
		activeGroup = activeGroup,
		groups = groups,
		addonVersion = CBAB.version,
	}
end

-- ============================================================
-- Cache access -- CBAB.DB:Cache() is the sole store (DB.lua owns
-- SavedVariables); Capability.lua only ever reads/writes through it.
-- ============================================================

function CBAB.Cap:GetEntry(nameRealm)
	return CBAB.DB:Cache()[nameRealm]
end

function CBAB.Cap:Get(nameRealm, group)
	local entry = self:GetEntry(nameRealm)
	if not entry then
		return nil, "unknown", nil
	end

	local g = group or entry.activeGroup
	local record = entry.groups and entry.groups[g]
	local age = entry.seen and (time() - entry.seen) or nil
	return record, entry.source, age
end

-- Precedence (spec 6.2): live > guild > manual > unknown. manual may only
-- write when nothing (unknown) is cached yet.
local SOURCE_RANK = { live = 3, guild = 2, manual = 1 }

function CBAB.Cap:Put(nameRealm, entry, source)
	local cache = CBAB.DB:Cache()
	local existing = cache[nameRealm]

	if existing then
		local existingRank = SOURCE_RANK[existing.source] or 0
		local newRank = SOURCE_RANK[source] or 0
		if newRank < existingRank then
			return false
		end
	end

	entry.source = source
	entry.seen = time()
	cache[nameRealm] = entry
	return true
end

-- ============================================================
-- Plan diffing (spec 6.3) and swap relevance (spec 6.4)
-- ============================================================

local function carrierExists(assignment, blessing)
	for _, entries in pairs(assignment.greaters or {}) do
		for _, b in pairs(entries) do
			if b == blessing then return true end
		end
	end
	return false
end

local function isCasterOf(assignment, name, blessing)
	local entries = assignment.greaters and assignment.greaters[name]
	if not entries then return false end
	for _, b in pairs(entries) do
		if b == blessing then return true end
	end
	return false
end

-- Compares each paladin in the profile's roster against their live cached
-- capability, surfacing only what a leader would act on: a spec change
-- (cosmetic, but explains WHY capability moved) and gained/lost Kings or
-- Sanctuary specifically (the only capability that can make a slot exist
-- or vanish -- Might/Wisdom rank changes don't add or remove a slot, so
-- they're not surfaced here, matching AffectsPlan's spirit below).
function CBAB.Cap:DiffAgainstPlan(profile)
	local changes = {}
	if not profile then return changes end

	local assignment = profile.assignment or {}

	for _, r in ipairs(profile.roster or {}) do
		if r.class == "PALADIN" then
			local entry = self:GetEntry(r.name)
			local active = entry and entry.groups and entry.groups[entry.activeGroup]

			if active then
				if r.spec and active.spec and r.spec ~= active.spec then
					changes[#changes + 1] = {
						name = r.name,
						kind = "spec_changed",
						message = ("%s is %s, not %s"):format(r.name, active.spec, r.spec),
					}
				end

				for _, blessing in ipairs({ "kings", "sanctuary" }) do
					local has = active[blessing] == true
					local carrying = isCasterOf(assignment, r.name, blessing)
					local label = CBAB.Blessings[blessing].name

					if has and not carrying and not carrierExists(assignment, blessing) then
						changes[#changes + 1] = {
							name = r.name,
							kind = "new_capability",
							blessing = blessing,
							message = ("%s has %s -- plan assumed no %s carrier"):format(r.name, label, label),
						}
					elseif not has and carrying then
						changes[#changes + 1] = {
							name = r.name,
							kind = "capability_lost",
							blessing = blessing,
							message = ("%s no longer has %s"):format(r.name, label),
						}
					end
				end
			end
		end
	end

	return changes
end

-- Whether a capability change is worth surfacing at all -- only the fields
-- the solver actually reads (spec 6). Compares whichever group is active
-- in each entry, so this covers both a same-group respec and a group swap.
function CBAB.Cap:AffectsPlan(nameRealm, oldEntry, newEntry)
	if not oldEntry or not newEntry then
		return true
	end

	local oldGroup = oldEntry.groups and oldEntry.groups[oldEntry.activeGroup]
	local newGroup = newEntry.groups and newEntry.groups[newEntry.activeGroup]

	if not oldGroup or not newGroup then
		return oldGroup ~= newGroup
	end

	return oldGroup.kings ~= newGroup.kings
		or oldGroup.sanctuary ~= newGroup.sanctuary
		or oldGroup.impMight ~= newGroup.impMight
		or oldGroup.impWisdom ~= newGroup.impWisdom
end

-- ============================================================
-- Debounced rescanning (spec 6.4): a respec or dual-spec swap fires
-- SPELLS_CHANGED/PLAYER_TALENT_UPDATE/CHARACTER_POINTS_CHANGED/
-- ACTIVE_TALENT_GROUP_CHANGED several times in a burst. Wait for it to
-- settle, then scan once and emit CAPABILITY_CHANGED. Broadcasting SELF on
-- the guild channel is Comm.lua's job (not built yet) -- it should
-- subscribe to CAPABILITY_CHANGED for "self" to do that.
-- ============================================================

local function selfKey()
	return UnitName("player") .. "-" .. GetRealmName()
end

local DEBOUNCE_SECONDS = 1.5
local pending = false

local function rescanSelf()
	pending = false
	local key = selfKey()
	local entry = CBAB.Cap:ScanSelf()
	CBAB.Cap:Put(key, entry, "live")
	CBAB:Fire("CAPABILITY_CHANGED", key, entry)
end

-- Checked directly against the player's class rather than CBAB:Mode(),
-- since Core's mode table is only populated by its own PLAYER_LOGIN
-- handler and handler dispatch order between modules isn't guaranteed.
local function isPaladin()
	local _, classToken = UnitClass("player")
	return classToken == "PALADIN"
end

local function scheduleRescan()
	if not isPaladin() then return end
	if pending then return end
	pending = true
	CBAB:After(DEBOUNCE_SECONDS, rescanSelf)
end

CBAB:On("PLAYER_LOGIN", "cap:login", scheduleRescan)
for _, event in ipairs({ "SPELLS_CHANGED", "PLAYER_TALENT_UPDATE", "CHARACTER_POINTS_CHANGED", "ACTIVE_TALENT_GROUP_CHANGED" }) do
	CBAB:On(event, "cap:" .. event, scheduleRescan)
end

-- ============================================================
-- /cbab dump talents
-- ============================================================

CBAB.DumpHandlers.talents = function()
	local entry = CBAB.Cap:ScanSelf()
	CBAB:Print(("-- Talents (%s) --"):format(entry.class))
	for group = 1, #entry.groups do
		local record = entry.groups[group]
		local marker = (group == entry.activeGroup) and "*" or " "
		CBAB:Print(("  %s group %d: spec=%s kings=%s sanctuary=%s impMight=%d impWisdom=%d"):format(
			marker, group, tostring(record.spec), tostring(record.kings), tostring(record.sanctuary),
			record.impMight, record.impWisdom))
	end
end
