local ADDON, CBAB = ...

-- Pure data. Zero logic. Spell IDs are TBC 2.5.6 only -- do not add Classic
-- Era or Retail IDs here. See the verification checklist at the end of the
-- session notes for anything still worth a /dump GetSpellInfo(id) check.

-- Deterministic iteration order for the six blessing ids.
CBAB.BlessingOrder = { "salv", "kings", "might", "wisdom", "light", "sanctuary" }

-- Raid-wide importance order (spec 4's Blessing value model), most valuable
-- first. Used as the tie-break priority when a unit ends up with more than
-- one candidate blessing assigned at once (rule 1: only one blessing can
-- ever be active on a unit) and no role-specific want-list (tank/pet)
-- applies -- see UI/Alert.lua's candidateScore.
CBAB.BlessingValueOrder = { "salv", "kings", "light", "might", "wisdom", "sanctuary" }

CBAB.Blessings = {
	salv = {
		name = "Salvation",
		-- Single rank, unaffected by the TBC rank squeeze.
		normalIDs = { 1038 },
		greaterIDs = { 25895 },
		texture = "Interface\\Icons\\Spell_Holy_SealOfSalvation",
		talentGated = false,
		-- UI/Theme.lua's blessing color system (design handoff README.md).
		color = "#E8629E",
	},

	kings = {
		name = "Kings",
		-- Single rank; Protection talent, cannot be cast without it (spec 3.5).
		normalIDs = { 20217 },
		greaterIDs = { 25898 },
		texture = "Interface\\Icons\\Spell_Magic_MageArmor",
		talentGated = true,
		color = "#8E7BE6",
	},

	might = {
		name = "Might",
		-- Ranks 1-6 vanilla, rank 7 (25291) and rank 8 (27140) added in TBC.
		normalIDs = { 19740, 19834, 19835, 19836, 19837, 19838, 25291, 27140 },
		-- All three greater ranks are TBC-only (greater blessings didn't exist pre-TBC).
		greaterIDs = { 25782, 25916, 27141 },
		-- Load-bearing (spec 6.1): Improved Blessing of Might shares this icon.
		texture = "Interface\\Icons\\Spell_Holy_FistOfJustice",
		talentGated = false,
		color = "#E15A47",
	},

	wisdom = {
		name = "Wisdom",
		-- Ranks 1-5 vanilla, rank 6 (25290) and rank 7 (27142) added in TBC.
		normalIDs = { 19742, 19850, 19852, 19853, 19854, 25290, 27142 },
		greaterIDs = { 25894, 25918, 27143 },
		-- Load-bearing (spec 6.1): Improved Blessing of Wisdom shares this icon.
		texture = "Interface\\Icons\\Spell_Holy_SealOfWisdom",
		talentGated = false,
		color = "#43A6E6",
	},

	light = {
		name = "Light",
		-- Ranks 1-3 vanilla, rank 4 (27144) added in TBC.
		normalIDs = { 19977, 19978, 19979, 27144 },
		-- Greater Light is the one greater blessing with two TBC ranks.
		greaterIDs = { 25890, 27145 },
		texture = "Interface\\Icons\\Spell_Holy_PrayerOfHealing02",
		talentGated = false,
		color = "#E7BE4A",
	},

	sanctuary = {
		name = "Sanctuary",
		-- Ranks 1-4 vanilla, rank 5 (27168) added in TBC. Protection talent (spec 3.5).
		normalIDs = { 20911, 20912, 20913, 20914, 27168 },
		greaterIDs = { 25899 },
		texture = "Interface\\Icons\\Spell_Nature_LightningShield",
		talentGated = true,
		color = "#4FB477",
	},
}

-- Flat set (spellID -> true) of every spell ID any module needs to watch for.
CBAB.WatchedSpellIDs = {}
for _, blessing in pairs(CBAB.Blessings) do
	for _, id in ipairs(blessing.normalIDs) do
		CBAB.WatchedSpellIDs[id] = true
	end
	for _, id in ipairs(blessing.greaterIDs) do
		CBAB.WatchedSpellIDs[id] = true
	end
end
