local ADDON, CBAB = ...

-- Pure data. Class/spec reference lists for the roster page's headcount
-- table and the Tanks section's class picker. Colors and class icons are
-- deliberately NOT duplicated here -- they're read at render time from
-- Blizzard's own RAID_CLASS_COLORS / CLASS_ICON_TCOORDS globals, so they
-- can never drift from what the client actually ships.

CBAB.ClassOrder = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

-- Ordered per class. Keys match CBAB.Solver.SPEC_VALUE (Solver/Assign.lua)
-- where that table has an opinion about Might vs Wisdom; labels are
-- cosmetic only and never read by any solver code.
CBAB.ClassSpecs = {
	WARRIOR = {
		{ key = "arms", label = "Arms" },
		{ key = "fury", label = "Fury" },
		{ key = "protection", label = "Prot" },
	},
	PALADIN = {
		{ key = "holy", label = "Holy" },
		{ key = "protection", label = "Prot" },
		{ key = "retribution", label = "Ret" },
	},
	HUNTER = {
		{ key = "beastmastery", label = "BM" },
		{ key = "marksmanship", label = "MM" },
		{ key = "survival", label = "Surv" },
	},
	ROGUE = {
		{ key = "assassination", label = "Assn" },
		{ key = "combat", label = "Combat" },
		{ key = "subtlety", label = "Sub" },
	},
	PRIEST = {
		{ key = "discipline", label = "Disc" },
		{ key = "holy", label = "Holy" },
		{ key = "shadow", label = "Shadow" },
	},
	SHAMAN = {
		{ key = "elemental", label = "Ele" },
		{ key = "enhancement", label = "Enh" },
		{ key = "restoration", label = "Resto" },
	},
	MAGE = {
		{ key = "arcane", label = "Arcane" },
		{ key = "fire", label = "Fire" },
		{ key = "frost", label = "Frost" },
	},
	WARLOCK = {
		{ key = "affliction", label = "Affl" },
		{ key = "demonology", label = "Demo" },
		{ key = "destruction", label = "Destro" },
	},
	DRUID = {
		{ key = "balance", label = "Balance" },
		{ key = "feral", label = "Feral" },
		{ key = "restoration", label = "Resto" },
	},
}

-- Classes with a tank-capable spec, offered in the Tanks section's class
-- dropdown -- these are the only classes with a want-list in
-- Defaults.wants.tanks (spec 5.5).
CBAB.TankClasses = { "WARRIOR", "PALADIN", "DRUID" }
