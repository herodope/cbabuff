local ADDON, CBAB = ...

-- Wires the pure solver (Solver/*.lua) to live game data via CBAB.Cap and
-- CBAB.Roster, and writes the result back through CBAB.DB. No UI yet --
-- this is the /cbab solve slash command and the plan-diff nag only (spec
-- 11.1: Solve is manual-only, gated on InCombatLockdown(), never automatic).

-- ============================================================
-- Building solver inputs from live state
-- ============================================================

-- BuildSlots(paladins, classCounts) needs each paladin's OWN capability.
local function buildPaladinsList()
	local list = {}
	for _, m in ipairs(CBAB.Roster:Paladins()) do
		local record = CBAB.Cap:Get(m.nameRealm) or {}
		list[#list + 1] = {
			name = m.name,
			spec = record.spec,
			kings = record.kings or false,
			sanctuary = record.sanctuary or false,
			impMight = record.impMight or 0,
			impWisdom = record.impWisdom or 0,
		}
	end
	return list
end

-- classCounts is the raid-wide physical/caster headcount BuildSlots uses
-- to decide which of Might/Wisdom is "primary" (spec 5.1). Classes with
-- only one meaningful value are unambiguous; the spec-dependent classes
-- (spec 5.4) need a spec hint, which -- with no live spec detection built
-- yet -- only exists if the active profile's roster page has one for that
-- name. Members with neither are simply not tallied either way, since
-- guessing would be worse than omitting them from this coarse headcount.
local function buildClassCounts(profileByName)
	local physical, caster = 0, 0
	for _, m in pairs(CBAB.Roster:Get()) do
		if not m.isPet then
			if CBAB.Solver.ALWAYS_PHYSICAL[m.class] then
				physical = physical + 1
			elseif CBAB.Solver.ALWAYS_CASTER[m.class] then
				caster = caster + 1
			else
				local specMap = CBAB.Solver.SPEC_VALUE[m.class]
				local hint = profileByName[m.name]
				local value = specMap and hint and hint.spec and specMap[hint.spec]
				if value == "might" then
					physical = physical + 1
				elseif value == "wisdom" then
					caster = caster + 1
				end
			end
		end
	end
	return { physical = physical, caster = caster }
end

-- Assign/Validate's roster shape (Solver/Assign.lua's header comment):
-- live {name, class, unit, isTank, isPet, owner} enriched with the active
-- profile's spec/plannedGroup hints and, for paladins, live capability.
-- Live capability's spec wins over the roster-page hint once someone is
-- actually present (spec 6.5: "live active group always wins").
local function buildSolverRoster(profileByName)
	local roster = {}
	for _, m in pairs(CBAB.Roster:Get()) do
		local entry = {
			name = m.name,
			class = m.class,
			tank = m.isTank or nil,
			isPet = m.isPet or nil,
			owner = m.owner,
			unit = m.unit,
		}

		local hint = profileByName[m.name]
		if hint then
			entry.spec = hint.spec
			entry.plannedGroup = hint.plannedGroup
			entry.tankWantOverride = hint.tankWantOverride
		end

		if m.class == "PALADIN" and not m.isPet then
			local record = CBAB.Cap:Get(m.nameRealm)
			local capEntry = CBAB.Cap:GetEntry(m.nameRealm)
			if record then
				entry.kings = record.kings
				entry.sanctuary = record.sanctuary
				entry.impMight = record.impMight
				entry.impWisdom = record.impWisdom
				entry.spec = record.spec or entry.spec
			end
			if capEntry then
				entry.activeGroup = capEntry.activeGroup
			end
		end

		roster[#roster + 1] = entry
	end
	return roster
end

local function profileNameIndex(profile)
	local byName = {}
	for _, r in ipairs(profile.roster or {}) do
		byName[r.name] = r
	end
	return byName
end

CBAB.Solve = {}

-- Re-validates the CURRENTLY STORED assignment against live state, without
-- re-solving. UI/Editor.lua needs this to show validator output inline
-- for whatever's already on the profile (e.g. right after a push from
-- someone else), not only immediately after this client runs /cbab solve.
function CBAB.Solve:ValidateCurrent()
	local profile = CBAB.DB:Profile()
	if not profile or not profile.assignment then return {} end
	local roster = buildSolverRoster(profileNameIndex(profile))
	return CBAB.Solver.Validate(profile.assignment, roster)
end

-- ============================================================
-- /cbab solve
-- ============================================================

local function printSolveSummary(assignment, validation)
	CBAB:Print(("-- Solved: epoch %d by %s --"):format(assignment.epoch, assignment.author))

	for casterName, entries in pairs(assignment.greaters) do
		local parts = {}
		for class, blessing in pairs(entries) do
			parts[#parts + 1] = ("%s=%s"):format(class, blessing)
		end
		CBAB:Print(("  %s: %s"):format(casterName, table.concat(parts, ", ")))
	end

	CBAB:Print(("  %d override(s):"):format(#assignment.overrides))
	for _, o in ipairs(assignment.overrides) do
		CBAB:Print(("    %s -> %s: %s (%s)"):format(o.caster, o.target, o.blessing, o.reason))
	end

	local errorCount, warnCount = 0, 0
	for _, v in ipairs(validation) do
		if v.level == "error" then
			errorCount = errorCount + 1
			CBAB:Print(("  |cffff4444[ERROR]|r %s"):format(v.message))
		else
			warnCount = warnCount + 1
			CBAB:Print(("  |cffffcc00[warn]|r %s"):format(v.message))
		end
	end

	if errorCount > 0 then
		CBAB:Print(("|cffff4444%d error(s)|r, %d warning(s) -- push would be blocked"):format(errorCount, warnCount))
	elseif warnCount > 0 then
		CBAB:Print(("clean plan with %d warning(s)"):format(warnCount))
	else
		CBAB:Print("clean plan, no findings")
	end
end

-- CBAB.Solve:RunLive() -- the live-data solve (spec 11.1), shared by
-- `/cbab solve` and the pbar's Solve button (UI/Bar.lua) so there is one
-- code path, not two copies that can drift.
function CBAB.Solve:RunLive()
	if InCombatLockdown() then
		CBAB:Print("|cffff4444cannot solve in combat|r -- Solve is manual-only and gated out of combat (spec 11.1)")
		return
	end

	local profile = CBAB.DB:Profile()
	if not profile then
		CBAB:Print("no active profile -- create one with the roster page first")
		return
	end

	local profileByName = profileNameIndex(profile)
	local paladins = buildPaladinsList()
	local classCounts = buildClassCounts(profileByName)
	local roster = buildSolverRoster(profileByName)

	local slots = CBAB.Solver.BuildSlots(paladins, classCounts)
	local assignment = CBAB.Solver.Assign(slots, roster, profile.wants)
	local validation = CBAB.Solver.Validate(assignment, roster)

	assignment.epoch = (profile.assignment and profile.assignment.epoch or 0) + 1
	assignment.author = UnitName("player")
	assignment.timestamp = time()
	-- Computed here, not yet pushed to the raid (spec 8's source values:
	-- pushed/local/default). CBAB.Comm:PushAssignment marks it "pushed"
	-- once it's actually sent.
	assignment.source = "local"
	-- Auras are manual-only (SPEC.md's v1 aura scope note) -- carried
	-- forward from whatever was already planned rather than solved.
	assignment.auras = (profile.assignment and profile.assignment.auras) or {}

	profile.assignment = assignment
	profile.modified = time()
	CBAB:Fire("ASSIGNMENT_CHANGED")

	printSolveSummary(assignment, validation)
end

CBAB.SlashCommands.solve = function() CBAB.Solve:RunLive() end

-- ============================================================
-- Plan-diff nag (spec 6.3, 6.4): never auto-solves, just tells the leader
-- something moved and to re-solve if they agree it matters.
-- ============================================================

local function checkPlanDiff()
	local profile = CBAB.DB:Profile()
	if not profile then return end

	local changes = CBAB.Cap:DiffAgainstPlan(profile)
	if #changes == 0 then return end

	CBAB:Print("|cffffcc00plan may be out of date:|r")
	for _, c in ipairs(changes) do
		CBAB:Print("  " .. c.message)
	end
	CBAB:Print("  run |cff3399ff/cbab solve|r to re-solve, or ignore to keep the current plan")
end

-- Coalesces bursts (raid formation firing several GROUP_ROSTER_UPDATEs,
-- or a diff check landing close to a debounced CAPABILITY_CHANGED) into
-- one check instead of spamming chat per event.
local pendingDiffCheck = false
local function scheduleDiffCheck()
	if pendingDiffCheck then return end
	pendingDiffCheck = true
	CBAB:After(2, function()
		pendingDiffCheck = false
		checkPlanDiff()
	end)
end

CBAB:On("ROSTER_CHANGED", "solve:diff", scheduleDiffCheck)

-- A capability change only warrants a nag if it would actually alter the
-- assignment (spec 6.4) -- e.g. a ret paladin moving to a second ret build
-- must stay silent. AffectsPlan needs the PREVIOUS entry to compare
-- against, which the cache no longer has by the time this fires (Put()
-- already overwrote it), so this module keeps its own last-seen snapshot.
local lastSeenCapability = {}

CBAB:On("CAPABILITY_CHANGED", "solve:diff", function(nameRealm, newEntry)
	local oldEntry = lastSeenCapability[nameRealm]
	lastSeenCapability[nameRealm] = newEntry

	if oldEntry and not CBAB.Cap:AffectsPlan(nameRealm, oldEntry, newEntry) then
		return
	end
	scheduleDiffCheck()
end)
