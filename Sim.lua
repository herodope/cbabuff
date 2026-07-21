local ADDON, CBAB = ...

-- Sim.lua drives the pure solver files against committed fixtures with no
-- group present (spec 5.9, 12). Not itself required to be pure -- it just
-- never calls a game API, since none of this needs one.

CBAB.Sim = {}

local fixtures = {}
local fixtureOrder = {}

local function defineFixture(def)
	fixtures[def.name] = def
	fixtureOrder[#fixtureOrder + 1] = def.name
end

-- ---- small builders to keep fixture data readable ----

local function pal(name, spec, caps)
	local p = { name = name, spec = spec }
	for k, v in pairs(caps or {}) do p[k] = v end
	return p
end

-- A roster entry for a paladin needs the same capability fields as its
-- `paladins` counterpart (Assign/Validate read capability off roster, not
-- off the paladins array -- see Assign.lua's header comment).
local function palMember(p, extra)
	local m = { name = p.name, class = "PALADIN", spec = p.spec,
		kings = p.kings, sanctuary = p.sanctuary, impMight = p.impMight, impWisdom = p.impWisdom }
	for k, v in pairs(extra or {}) do m[k] = v end
	return m
end

local function member(name, class, spec, extra)
	local m = { name = name, class = class, spec = spec }
	for k, v in pairs(extra or {}) do m[k] = v end
	return m
end

local function pet(name, owner, unit)
	return { name = name, class = "HUNTER_PET", isPet = true, owner = owner, unit = unit }
end

local DEFAULT_WANTS = CBAB.Defaults.wants

-- ============================================================
-- Base paladin-count fixtures (1-6), spec 5.3.
-- ============================================================

-- 1 paladin: only Salvation is a raid-wide slot. Sanctara has Kings, so the
-- tank override lands on Kings (spec 5.3/5.5). Hand-verified.
defineFixture({
	name = "1_paladin",
	paladins = { pal("Sanctara", "holy", { kings = true, sanctuary = false, impMight = 0, impWisdom = 1 }) },
	classCounts = { physical = 2, caster = 1 },
	roster = {
		palMember(pal("Sanctara", "holy", { kings = true, sanctuary = false, impMight = 0, impWisdom = 1 })),
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Mageheart", "MAGE", "frost"),
		member("Roguefang", "ROGUE", "combat"),
	},
	wants = DEFAULT_WANTS,
	expected = {
		greaters = {
			Sanctara = { PALADIN = "salv", WARRIOR = "salv", MAGE = "salv", ROGUE = "salv" },
		},
		overrides = {
			{ caster = "Sanctara", target = "Thrallbjorn", blessing = "kings", reason = "tank" },
		},
	},
})

-- Same roster, Sanctara has no Kings talent. The want-list walk skips
-- straight to the next uncovered, castable entry -- for a Warrior tank
-- that's Might, not Light. (Spec 5.3's "Light if no Kings talent" is an
-- informal paraphrase; the mechanical want-list walk in 5.5 gives Might
-- here since nothing fills it at N=1 and Might isn't talent-gated. See the
-- walkthrough notes.)
defineFixture({
	name = "1_paladin_no_kings",
	paladins = { pal("Sanctara", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 1 }) },
	classCounts = { physical = 2, caster = 1 },
	roster = {
		palMember(pal("Sanctara", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 1 })),
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Mageheart", "MAGE", "frost"),
		member("Roguefang", "ROGUE", "combat"),
	},
	wants = DEFAULT_WANTS,
})

-- 2 paladins: Salv, Kings. No Might/Wisdom slot at all.
defineFixture({
	name = "2_paladins",
	paladins = {
		pal("Bulwarkk", "protection", { kings = true, sanctuary = true, impMight = 0, impWisdom = 0 }),
		pal("Sanctara", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 1 }),
	},
	classCounts = { physical = 3, caster = 2 },
	roster = {
		palMember(pal("Bulwarkk", "protection", { kings = true, sanctuary = true, impMight = 0, impWisdom = 0 })),
		palMember(pal("Sanctara", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 1 })),
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Mageheart", "MAGE", "frost"),
		member("Roguefang", "ROGUE", "combat"),
	},
	wants = DEFAULT_WANTS,
})

-- 3 paladins: Salv, Kings, Might (primary by headcount). Matches the 5.5
-- worked example (prot warrior tank -> kings filled, might filled, light
-- overridden) plus the Paladin-class self-conflict from 5.4. Hand-verified.
local function threePaladins()
	return {
		pal("Bulwarkk", "protection", { kings = true, sanctuary = true, impMight = 0, impWisdom = 0 }),
		pal("Lightgrasp", "retribution", { kings = false, sanctuary = false, impMight = 2, impWisdom = 0 }),
		pal("Sanctara", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 1 }),
	}
end

defineFixture({
	name = "3_paladins",
	paladins = threePaladins(),
	classCounts = { physical = 4, caster = 3 },
	roster = {
		palMember(threePaladins()[1]),
		palMember(threePaladins()[2]),
		palMember(threePaladins()[3]),
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Roguefang", "ROGUE", "combat"),
		member("Mageheart", "MAGE", "frost"),
		member("Priestlyheal", "PRIEST", "holy"),
	},
	wants = DEFAULT_WANTS,
	expected = {
		greaters = {
			Sanctara = { PALADIN = "salv", WARRIOR = "salv", ROGUE = "salv", MAGE = "salv", PRIEST = "salv" },
			Bulwarkk = { PALADIN = "kings", WARRIOR = "kings", ROGUE = "kings", MAGE = "kings", PRIEST = "kings" },
			Lightgrasp = { PALADIN = "wisdom", WARRIOR = "might", ROGUE = "might", MAGE = "wisdom", PRIEST = "wisdom" },
		},
		overrides = {
			{ caster = "Lightgrasp", target = "Lightgrasp", blessing = "might", reason = "minority" },
			{ caster = "Sanctara", target = "Thrallbjorn", blessing = "light", reason = "tank" },
		},
	},
})

-- 4 paladins: Salv, Kings, Might, Wisdom all get their own dedicated caster.
defineFixture({
	name = "4_paladins",
	paladins = {
		pal("Bulwarkk", "protection", { kings = true, sanctuary = true, impMight = 0, impWisdom = 0 }),
		pal("Lightgrasp", "retribution", { kings = false, sanctuary = false, impMight = 2, impWisdom = 0 }),
		pal("Sanctara", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 1 }),
		pal("Duskvow", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 2 }),
	},
	classCounts = { physical = 4, caster = 4 },
	roster = {
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Roguefang", "ROGUE", "combat"),
		member("Mageheart", "MAGE", "frost"),
		member("Priestlyheal", "PRIEST", "holy"),
	},
	wants = DEFAULT_WANTS,
})
for _, p in ipairs(fixtures["4_paladins"].paladins) do
	table.insert(fixtures["4_paladins"].roster, 1, palMember(p))
end

-- 5 paladins: adds Light as its own slot.
local function fivePaladins()
	return {
		pal("Bulwarkk", "protection", { kings = true, sanctuary = true, impMight = 0, impWisdom = 0 }),
		pal("Lightgrasp", "retribution", { kings = false, sanctuary = false, impMight = 2, impWisdom = 0 }),
		pal("Sanctara", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 1 }),
		pal("Duskvow", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 2 }),
		pal("Farhold", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 0 }),
	}
end
defineFixture({
	name = "5_paladins",
	paladins = fivePaladins(),
	classCounts = { physical = 4, caster = 4 },
	roster = {
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Roguefang", "ROGUE", "combat"),
		member("Mageheart", "MAGE", "frost"),
		member("Priestlyheal", "PRIEST", "holy"),
	},
	wants = DEFAULT_WANTS,
})
for _, p in ipairs(fivePaladins()) do
	table.insert(fixtures["5_paladins"].roster, 1, palMember(p))
end

-- 6 paladins: "no additional logic" -- the 6th gets no dedicated slot.
local function sixPaladins()
	local six = fivePaladins()
	six[#six + 1] = pal("Grimtide", "protection", { kings = true, sanctuary = false, impMight = 0, impWisdom = 0 })
	return six
end
defineFixture({
	name = "6_paladins",
	paladins = sixPaladins(),
	classCounts = { physical = 4, caster = 4 },
	roster = {
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Roguefang", "ROGUE", "combat"),
		member("Mageheart", "MAGE", "frost"),
		member("Priestlyheal", "PRIEST", "holy"),
	},
	wants = DEFAULT_WANTS,
})
for _, p in ipairs(sixPaladins()) do
	table.insert(fixtures["6_paladins"].roster, 1, palMember(p))
end

-- ============================================================
-- Degenerate cases
-- ============================================================

-- All 3 paladins retribution, nobody has Kings: the Kings tier is omitted
-- and the whole list shifts up.
defineFixture({
	name = "all_ret_no_kings",
	paladins = {
		pal("Lightgrasp", "retribution", { kings = false, sanctuary = false, impMight = 1, impWisdom = 0 }),
		pal("Ashfury", "retribution", { kings = false, sanctuary = false, impMight = 2, impWisdom = 0 }),
		pal("Doomcrest", "retribution", { kings = false, sanctuary = false, impMight = 0, impWisdom = 0 }),
	},
	classCounts = { physical = 5, caster = 1 },
	roster = {
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Roguefang", "ROGUE", "combat"),
		member("Mageheart", "MAGE", "frost"),
	},
	wants = DEFAULT_WANTS,
})
for _, p in ipairs(fixtures.all_ret_no_kings.paladins) do
	table.insert(fixtures.all_ret_no_kings.roster, 1, palMember(p))
end

-- Nobody anywhere has an improved talent: ties fall through to spec/name,
-- never a warning (spec 5.2).
defineFixture({
	name = "no_improved_talents",
	paladins = {
		pal("Bulwarkk", "protection", { kings = true, sanctuary = true, impMight = 0, impWisdom = 0 }),
		pal("Lightgrasp", "retribution", { kings = false, sanctuary = false, impMight = 0, impWisdom = 0 }),
		pal("Sanctara", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 0 }),
	},
	classCounts = { physical = 3, caster = 2 },
	roster = {
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Roguefang", "ROGUE", "combat"),
		member("Mageheart", "MAGE", "frost"),
	},
	wants = DEFAULT_WANTS,
})
for _, p in ipairs(fixtures.no_improved_talents.paladins) do
	table.insert(fixtures.no_improved_talents.roster, 1, palMember(p))
end

-- Two paladins share Improved Might rank 2; nobody has Improved Wisdom.
defineFixture({
	name = "duplicate_improved_talent",
	paladins = {
		pal("Bulwarkk", "protection", { kings = true, sanctuary = true, impMight = 0, impWisdom = 0 }),
		pal("Lightgrasp", "retribution", { kings = false, sanctuary = false, impMight = 2, impWisdom = 0 }),
		pal("Ashfury", "retribution", { kings = false, sanctuary = false, impMight = 2, impWisdom = 0 }),
	},
	classCounts = { physical = 4, caster = 1 },
	roster = {
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Roguefang", "ROGUE", "combat"),
		member("Mageheart", "MAGE", "frost"),
	},
	wants = DEFAULT_WANTS,
})
for _, p in ipairs(fixtures.duplicate_improved_talent.paladins) do
	table.insert(fixtures.duplicate_improved_talent.roster, 1, palMember(p))
end

-- Shaman majority enhancement: greater Might, one normal Wisdom on resto.
defineFixture({
	name = "shaman_majority_enh",
	paladins = threePaladins(),
	classCounts = { physical = 5, caster = 2 },
	roster = {
		palMember(threePaladins()[1]), palMember(threePaladins()[2]), palMember(threePaladins()[3]),
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Windtotem", "SHAMAN", "enhancement"),
		member("Stormtotem", "SHAMAN", "enhancement"),
		member("Mudtotem", "SHAMAN", "enhancement"),
		member("Healtotem", "SHAMAN", "restoration"),
	},
	wants = DEFAULT_WANTS,
})

-- Shaman majority restoration: greater Wisdom, one normal Might on enh.
defineFixture({
	name = "shaman_majority_resto",
	paladins = threePaladins(),
	classCounts = { physical = 2, caster = 5 },
	roster = {
		palMember(threePaladins()[1]), palMember(threePaladins()[2]), palMember(threePaladins()[3]),
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Windtotem", "SHAMAN", "restoration"),
		member("Stormtotem", "SHAMAN", "restoration"),
		member("Mudtotem", "SHAMAN", "restoration"),
		member("Healtotem", "SHAMAN", "enhancement"),
	},
	wants = DEFAULT_WANTS,
})

-- Feral tank alongside boomkins: greater Wisdom; feral picks up Might via
-- his own tank want-list (spec 5.4's worked example).
defineFixture({
	name = "feral_tank_boomkins",
	paladins = threePaladins(),
	classCounts = { physical = 4, caster = 3 },
	roster = {
		palMember(threePaladins()[1]), palMember(threePaladins()[2]), palMember(threePaladins()[3]),
		member("Clawmaw", "DRUID", "feral", { tank = true }),
		member("Moonglow", "DRUID", "balance"),
		member("Starwhisper", "DRUID", "balance"),
	},
	wants = DEFAULT_WANTS,
})

-- Three tanks of different classes.
defineFixture({
	name = "three_tanks",
	paladins = threePaladins(),
	classCounts = { physical = 4, caster = 3 },
	roster = {
		palMember(threePaladins()[1]), palMember(threePaladins()[2]), palMember(threePaladins()[3]),
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
		member("Clawmaw", "DRUID", "feral", { tank = true }),
		member("Duskguard", "PALADIN", "protection", { tank = true }),
	},
	wants = DEFAULT_WANTS,
})
-- Duskguard is a tanking paladin, not one of the three blessing-casters --
-- he's a plain roster member here (he only ever appears as a target, never
-- a caster, so he doesn't need capability fields for this fixture).

-- Pets enabled and disabled on the same composition.
local function petComposition(petsEnabled)
	return {
		paladins = threePaladins(),
		classCounts = { physical = 4, caster = 3 },
		roster = {
			palMember(threePaladins()[1]), palMember(threePaladins()[2]), palMember(threePaladins()[3]),
			member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
			member("Trapmaster", "HUNTER", "survival"),
			pet("Fangtooth", "Trapmaster", "raidpet1"),
		},
		wants = { petsEnabled = petsEnabled, tanks = DEFAULT_WANTS.tanks, pet = DEFAULT_WANTS.pet },
	}
end
defineFixture((function() local f = petComposition(true); f.name = "pets_enabled"; return f end)())
defineFixture((function() local f = petComposition(false); f.name = "pets_disabled"; return f end)())

-- A paladin whose plannedGroup differs from his active group.
defineFixture({
	name = "planned_group_mismatch",
	paladins = threePaladins(),
	classCounts = { physical = 4, caster = 3 },
	roster = {
		palMember(threePaladins()[1]),
		palMember(threePaladins()[2], { plannedGroup = 2, activeGroup = 1 }),
		palMember(threePaladins()[3]),
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
	},
	wants = DEFAULT_WANTS,
})

-- Mid-session swap that adds a Kings carrier where none existed: same
-- roster shape, before/after. Run both and diff to see the shift.
defineFixture({
	name = "kings_swap_before",
	paladins = {
		pal("Lightgrasp", "retribution", { kings = false, sanctuary = false, impMight = 1, impWisdom = 0 }),
		pal("Sanctara", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 1 }),
	},
	classCounts = { physical = 3, caster = 2 },
	roster = {
		palMember(pal("Lightgrasp", "retribution", { kings = false, sanctuary = false, impMight = 1, impWisdom = 0 })),
		palMember(pal("Sanctara", "holy", { kings = false, sanctuary = false, impMight = 0, impWisdom = 1 })),
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
	},
	wants = DEFAULT_WANTS,
})
defineFixture({
	name = "kings_swap_after",
	paladins = {
		pal("Lightgrasp", "retribution", { kings = false, sanctuary = false, impMight = 1, impWisdom = 0 }),
		pal("Sanctara", "holy", { kings = true, sanctuary = false, impMight = 0, impWisdom = 1 }),
	},
	classCounts = { physical = 3, caster = 2 },
	roster = {
		palMember(pal("Lightgrasp", "retribution", { kings = false, sanctuary = false, impMight = 1, impWisdom = 0 })),
		palMember(pal("Sanctara", "holy", { kings = true, sanctuary = false, impMight = 0, impWisdom = 1 })),
		member("Thrallbjorn", "WARRIOR", "protection", { tank = true }),
	},
	wants = DEFAULT_WANTS,
})

-- ============================================================
-- Runner
-- ============================================================

local function deepEqual(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

function CBAB.Sim:Run(fixtureName)
	local f = fixtures[fixtureName]
	if not f then
		CBAB:Print("no such fixture: " .. tostring(fixtureName))
		return nil, nil
	end

	local slots = CBAB.Solver.BuildSlots(f.paladins, f.classCounts)
	local assignment = CBAB.Solver.Assign(slots, f.roster, f.wants)
	local validation = CBAB.Solver.Validate(assignment, f.roster)
	return assignment, validation
end

function CBAB.Sim:RunAll()
	local results = {}
	for _, name in ipairs(fixtureOrder) do
		local f = fixtures[name]
		local assignment, validation = self:Run(name)

		local hasError = false
		for _, finding in ipairs(validation) do
			if finding.level == "error" then hasError = true end
		end

		local pass, diff
		if f.expected then
			pass = deepEqual(assignment, f.expected)
			diff = pass and nil or "assignment does not match the committed snapshot"
		else
			pass = not hasError
			diff = pass and nil or "solver produced a validation error -- see /cbab sim " .. name
		end

		results[#results + 1] = { name = name, pass = pass, diff = diff }
	end
	return results
end

-- ============================================================
-- /cbab sim <fixture> | all
-- ============================================================

local function printAssignment(assignment)
	for casterName, entries in pairs(assignment.greaters) do
		for class, blessing in pairs(entries) do
			CBAB:Print(("  greater: %s -> %s = %s"):format(casterName, class, blessing))
		end
	end
	for _, o in ipairs(assignment.overrides) do
		CBAB:Print(("  override: %s -> %s = %s (%s)"):format(o.caster, o.target, o.blessing, o.reason))
	end
end

local function printValidation(validation)
	if #validation == 0 then
		CBAB:Print("  no findings")
		return
	end
	for _, v in ipairs(validation) do
		CBAB:Print(("  [%s] %s: %s"):format(v.level, v.code, v.message))
	end
end

local function SimSlash(topic)
	if topic == "" then
		CBAB:Print("usage: /cbab sim <fixture> | all")
		return
	end

	if topic == "all" then
		local results = CBAB.Sim:RunAll()
		local passCount = 0
		for _, r in ipairs(results) do
			if r.pass then passCount = passCount + 1 end
			CBAB:Print(("  [%s] %s%s"):format(r.pass and "pass" or "FAIL", r.name, r.diff and (" -- " .. r.diff) or ""))
		end
		CBAB:Print(("-- %d/%d fixtures passed --"):format(passCount, #results))
		return
	end

	local assignment, validation = CBAB.Sim:Run(topic)
	if not assignment then return end
	CBAB:Print("-- " .. topic .. " --")
	printAssignment(assignment)
	printValidation(validation)
end

CBAB.SlashCommands = CBAB.SlashCommands or {}
CBAB.SlashCommands.sim = SimSlash
