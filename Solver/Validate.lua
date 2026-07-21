local ADDON, CBAB = ...

-- PURE. No game API calls (spec 5.9).
--
-- CBAB.Solver.Validate(assignment, roster) -> { {level, code, message, subject}, ... }
--
-- roster is the same enriched shape Assign() takes (see Assign.lua) --
-- paladin entries may carry kings/sanctuary/impMight/impWisdom/
-- activeGroup/plannedGroup.

CBAB.Solver = CBAB.Solver or {}

local function add(findings, level, code, message, subject)
	findings[#findings + 1] = { level = level, code = code, message = message, subject = subject }
end

local function classesInRoster(roster)
	local seen, order = {}, {}
	for _, m in ipairs(roster) do
		if not m.isPet and not seen[m.class] then
			seen[m.class] = true
			order[#order + 1] = m.class
		end
	end
	return order
end

local function anyCasterGivesClass(assignment, class, blessing)
	for _, entries in pairs(assignment.greaters) do
		if entries[class] == blessing then
			return true
		end
	end
	return false
end

local function blessingExistsAnywhere(assignment, blessing)
	for _, entries in pairs(assignment.greaters) do
		for _, b in pairs(entries) do
			if b == blessing then return true end
		end
	end
	return false
end

function CBAB.Solver.Validate(assignment, roster)
	local findings = {}

	local byName = {}
	for _, m in ipairs(roster) do
		byName[m.name] = m
	end

	-- ERROR: the same caster assigned two different blessings to the same
	-- target. Structurally this shows up as a duplicate (caster, target)
	-- pair in overrides with conflicting blessing values -- the greaters
	-- map can't hold two values for one class, so this is where it'd
	-- surface (e.g. from a future manual/local-override edit).
	do
		local seen = {}
		for _, o in ipairs(assignment.overrides) do
			local key = o.caster .. "\0" .. o.target
			local prior = seen[key]
			if prior and prior ~= o.blessing then
				add(findings, "error", "duplicate_assignment",
					("%s is assigned two different blessings to %s"):format(o.caster, o.target), o.target)
			end
			seen[key] = o.blessing
		end
	end

	-- ERROR: a tank with no override at all still holds his class's
	-- Greater Salvation, since nothing replaced it on him (rule 4).
	for _, m in ipairs(roster) do
		if m.tank and not m.isPet then
			local covered = false
			for _, o in ipairs(assignment.overrides) do
				if o.target == m.name then
					covered = true
					break
				end
			end
			if not covered then
				add(findings, "error", "tank_holds_salvation",
					("%s (tank) has no override and still holds Salvation"):format(m.name), m.name)
			end
		end
	end

	-- ERROR: a caster assigned to cast something he can't. Only fires when
	-- we KNOW the talent is absent (capability == false) -- unknown
	-- capability is a warning, not an error (see below).
	local function checkCastable(casterName, blessing, subject)
		if blessing ~= "kings" and blessing ~= "sanctuary" then return end
		local p = byName[casterName]
		if p and p[blessing] == false then
			add(findings, "error", "missing_talent",
				("%s is assigned to cast %s but doesn't have the talent"):format(casterName, blessing), subject)
		end
	end
	for casterName, entries in pairs(assignment.greaters) do
		for class, blessing in pairs(entries) do
			checkCastable(casterName, blessing, class)
		end
	end
	for _, o in ipairs(assignment.overrides) do
		checkCastable(o.caster, o.blessing, o.target)
	end

	-- WARN: a class missing Salvation/Kings coverage even though a carrier
	-- for that blessing exists somewhere in the assignment.
	local classes = classesInRoster(roster)
	for _, blessing in ipairs({ "salv", "kings" }) do
		if blessingExistsAnywhere(assignment, blessing) then
			for _, class in ipairs(classes) do
				if not anyCasterGivesClass(assignment, class, blessing) then
					add(findings, "warn", "class_missing_coverage",
						("%s has no %s carrier"):format(class, blessing), class)
				end
			end
		end
	end

	-- WARN: a caster with no capability data reported at all -- not
	-- installed, or not seen since login (spec 5.8/6.2).
	do
		local casters = {}
		for casterName in pairs(assignment.greaters) do
			casters[casterName] = true
		end
		for _, o in ipairs(assignment.overrides) do
			casters[o.caster] = true
		end
		for casterName in pairs(casters) do
			local p = byName[casterName]
			if not p or (p.kings == nil and p.sanctuary == nil and p.impMight == nil and p.impWisdom == nil) then
				add(findings, "warn", "unknown_capability",
					("%s has not reported capability (not installed, or not seen since login)"):format(casterName),
					casterName)
			end
		end
	end

	-- WARN: live active talent group differs from the planned one (6.5).
	for _, m in ipairs(roster) do
		if m.class == "PALADIN" and m.plannedGroup and m.activeGroup and m.plannedGroup ~= m.activeGroup then
			add(findings, "warn", "planned_group_mismatch",
				("%s is planned for group %d but is on group %d"):format(m.name, m.plannedGroup, m.activeGroup),
				m.name)
		end
	end

	return findings
end
