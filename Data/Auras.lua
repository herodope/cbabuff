local ADDON, CBAB = ...

-- Pure data. Zero logic. Paladin Auras (spec 2, amended -- see SPEC.md's
-- v1 scope note): unlike blessings, an aura is self-cast and has no
-- greater/normal split, so each entry carries one `ids` rank list instead
-- of normalIDs/greaterIDs. `talentGated` mirrors Data/Spells.lua's field so
-- Capability.lua's talent-texture lookup (spec 6.1) can be extended to
-- auras with the same technique if Sanctity Aura capability gating is
-- ever wired up -- not done yet, see SPEC.md.
--
-- HIGH RISK -- UNVERIFIED (see CHECKLIST.md "Auras" section): these rank ID
-- lists were never confirmed against a live 2.5.6 client the way
-- Data/Spells.lua's blessing IDs were. Track.lua matches by exact spell ID
-- only (spec 9), so a wrong or missing rank here fails silently -- the
-- aura simply never reads as "active," not an error.

CBAB.AuraOrder = { "devotion", "retribution", "concentration", "sanctity" }

CBAB.Auras = {
	devotion = {
		name = "Devotion Aura",
		ids = { 465, 10290, 643, 10291, 1032, 10292, 10293, 27149 },
		texture = "Interface\\Icons\\Spell_Holy_DevotionAura",
		talentGated = false,
	},

	retribution = {
		name = "Retribution Aura",
		ids = { 7294, 10298, 10299, 10300, 10301, 27150 },
		texture = "Interface\\Icons\\Spell_Holy_AuraOfLight",
		talentGated = false,
	},

	concentration = {
		name = "Concentration Aura",
		ids = { 19746 },
		texture = "Interface\\Icons\\Spell_Holy_MindSooth",
		talentGated = false,
	},

	-- Retribution talent in TBC -- included for the plan/display, not yet
	-- read by Capability.lua (see SPEC.md's v1 aura scope note).
	sanctity = {
		name = "Sanctity Aura",
		ids = { 20218 },
		texture = "Interface\\Icons\\Spell_Holy_MindVision",
		talentGated = true,
	},
}

-- Folded into the SAME watched-spell set Track.lua already scans (spec 9:
-- spell ID matching only). Auras are self-cast, so a hit here just means
-- "this unit's own aura buff," read off whichever unit happens to be
-- tracked -- no separate shim or scan path needed.
for _, aura in pairs(CBAB.Auras) do
	for _, id in ipairs(aura.ids) do
		CBAB.WatchedSpellIDs[id] = true
	end
end
