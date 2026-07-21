local ADDON, CBAB = ...

-- PURE. No game API calls (spec 5.9).
--
-- CBAB.Solver.Assign(slots, roster, wants) -> assignment
--
-- roster: array of raid members (spec 5, not the raw DB roster table):
--   { name, class, spec, tank = bool, isPet = bool, owner = "HunterName",
--     unit = "raidpet3" }
--   Paladin entries may additionally carry capability fields mirroring what
--   was passed to BuildSlots -- kings, sanctuary, impMight, impWisdom,
--   activeGroup, plannedGroup -- since Assign (and Validate) need to know
--   whether the salv/override carrier can actually cast a talent-gated
--   blessing (spec 6.2: unknown capability is treated as "no talent").
-- wants: { petsEnabled, tanks = { CLASS = {...} }, pet = {...} }
--
-- Internally: greater pass -> intra-class minority resolution ->
-- tank want-list walk -> pet want-list walk (spec 12).

CBAB.Solver = CBAB.Solver or {}

-- Classes with only one meaningful value regardless of spec. Exposed
-- publicly (not just local) so callers building classCounts for BuildSlots
-- -- e.g. Solve.lua -- classify classes the same way Assign does, instead
-- of duplicating this reference data.
CBAB.Solver.ALWAYS_PHYSICAL = { WARRIOR = true, ROGUE = true, HUNTER = true }
CBAB.Solver.ALWAYS_CASTER = { MAGE = true, PRIEST = true, WARLOCK = true }
local ALWAYS_PHYSICAL = CBAB.Solver.ALWAYS_PHYSICAL
local ALWAYS_CASTER = CBAB.Solver.ALWAYS_CASTER

-- Spec-dependent classes (spec 5.4). Warrior is deliberately absent: every
-- warrior spec wants Might, and protection's other needs are handled
-- entirely by the tank override (5.5), so it needs no minority split.
CBAB.Solver.SPEC_VALUE = {
	SHAMAN = { enhancement = "might", elemental = "wisdom", restoration = "wisdom" },
	DRUID = { feral = "might", balance = "wisdom", restoration = "wisdom" },
	PALADIN = { retribution = "might", holy = "wisdom", protection = "wisdom" },
}
local SPEC_VALUE = CBAB.Solver.SPEC_VALUE

-- Which of Might/Wisdom a class's greater should be, and which members (if
-- any) are the minority needing a supplemental normal blessing (5.4). Ties
-- favor Might, matching Slots.lua's tie-break.
local function classWantsValue(class, members)
	if ALWAYS_PHYSICAL[class] then
		return "might", {}
	end
	if ALWAYS_CASTER[class] then
		return "wisdom", {}
	end

	local specMap = SPEC_VALUE[class]
	if not specMap then
		return nil, {}
	end

	local mightMembers, wisdomMembers = {}, {}
	for _, m in ipairs(members) do
		local value = specMap[m.spec]
		if value == "might" then
			mightMembers[#mightMembers + 1] = m
		elseif value == "wisdom" then
			wisdomMembers[#wisdomMembers + 1] = m
		end
		-- Specs absent from specMap (e.g. protection warrior) are simply
		-- never tallied -- they're covered by the tank override instead.
	end

	if #mightMembers >= #wisdomMembers then
		return "might", wisdomMembers
	end
	return "wisdom", mightMembers
end

local function classesOf(roster)
	local members, order = {}, {}
	for _, m in ipairs(roster) do
		if not m.isPet then
			if not members[m.class] then
				members[m.class] = {}
				order[#order + 1] = m.class
			end
			table.insert(members[m.class], m)
		end
	end
	return members, order
end

local function findSlot(slots, blessing)
	for _, slot in ipairs(slots) do
		if slot.blessing == blessing and slot.caster then
			return slot
		end
	end
	return nil
end

-- Kings/Sanctuary are talent-gated; unknown capability counts as "no
-- talent" (spec 6.2). Everything else is always trainable (spec 3.7).
local function canCast(byName, casterName, blessing)
	if blessing ~= "kings" and blessing ~= "sanctuary" then
		return true
	end
	local p = byName[casterName]
	return p ~= nil and p[blessing] == true
end

function CBAB.Solver.Assign(slots, roster, wants)
	local assignment = {
		epoch = 0,
		author = "",
		timestamp = 0,
		greaters = {},
		overrides = {},
	}

	local function greatersFor(casterName)
		assignment.greaters[casterName] = assignment.greaters[casterName] or {}
		return assignment.greaters[casterName]
	end

	local byName = {}
	for _, m in ipairs(roster) do
		byName[m.name] = m
	end

	local classMembers, classOrder = classesOf(roster)

	-- Uniform slots: Salvation, Kings, Light apply the same way to every
	-- class regardless of spec (5.4 only concerns Might vs Wisdom).
	for _, blessing in ipairs({ "salv", "kings", "light" }) do
		local slot = findSlot(slots, blessing)
		if slot then
			for _, class in ipairs(classOrder) do
				greatersFor(slot.caster)[class] = blessing
			end
		end
	end

	-- Might/Wisdom: each class gets whichever type it actually needs. With
	-- both slots present (4+ paladins) each type has its own dedicated
	-- caster. With only one present (3 paladins) that single caster
	-- delivers both -- neither is talent-gated (rule 7), and one paladin
	-- can hold different greaters on different classes at once (rule 1
	-- only forbids two on the SAME target). With neither present (1-2
	-- paladins) Might/Wisdom isn't covered raid-wide at all.
	local mightSlot = findSlot(slots, "might")
	local wisdomSlot = findSlot(slots, "wisdom")
	local individualValue = {}

	if mightSlot or wisdomSlot then
		for _, class in ipairs(classOrder) do
			local want, minority = classWantsValue(class, classMembers[class])
			if want then
				local wantSlot = (want == "might") and mightSlot or wisdomSlot
				local deliverer = wantSlot or mightSlot or wisdomSlot

				greatersFor(deliverer.caster)[class] = want
				for _, m in ipairs(classMembers[class]) do
					individualValue[m.name] = want
				end

				local other = (want == "might") and "wisdom" or "might"
				for _, m in ipairs(minority) do
					individualValue[m.name] = other
					assignment.overrides[#assignment.overrides + 1] = {
						caster = deliverer.caster,
						target = m.name,
						blessing = other,
						reason = "minority",
					}
				end
			end
		end
	end

	-- Tank and pet overrides both walk an ordered want-list and cast the
	-- highest entry that is (a) not already covered and (b) castable by
	-- the salv carrier (5.5, 5.6). The salv carrier is used because his
	-- greater is worthless on tanks/pets to begin with (spec 3), and a
	-- normal cast from him replaces his own greater on that one target
	-- (rule 4), which is exactly what clears stray Salvation (spec 2.1).
	local salvSlot = findSlot(slots, "salv")
	local salvCaster = salvSlot and salvSlot.caster

	local function classHas(class, blessing)
		for _, entries in pairs(assignment.greaters) do
			if entries[class] == blessing then
				return true
			end
		end
		return false
	end

	local function isFilled(member, entry)
		if entry == "might" or entry == "wisdom" then
			return individualValue[member.name] == entry
		end
		return classHas(member.class, entry)
	end

	local function walkWantList(member, wantList, reason, extra)
		if not salvCaster or not wantList then return end
		for _, entry in ipairs(wantList) do
			if not isFilled(member, entry) and canCast(byName, salvCaster, entry) then
				local o = { caster = salvCaster, target = member.name, blessing = entry, reason = reason }
				if extra then
					for k, v in pairs(extra) do o[k] = v end
				end
				assignment.overrides[#assignment.overrides + 1] = o
				return
			end
		end
	end

	for _, member in ipairs(roster) do
		if member.tank and not member.isPet then
			walkWantList(member, wants.tanks and wants.tanks[member.class], "tank")
		end
	end

	if wants.petsEnabled then
		for _, member in ipairs(roster) do
			if member.isPet then
				-- Nothing from the greater pass ever reaches pets (rule 2),
				-- so the first want-list entry always wins.
				local o = {
					caster = salvCaster,
					target = member.unit or member.name,
					blessing = (wants.pet or {})[1],
					reason = "pet",
					owner = member.owner,
				}
				if salvCaster and o.blessing then
					assignment.overrides[#assignment.overrides + 1] = o
				end
			end
		end
	end

	return assignment
end
