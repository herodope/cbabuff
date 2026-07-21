local ADDON, CBAB = ...

-- PURE. No game API calls of any kind (spec 5.9). Plain tables in, plain
-- tables out. This is what lets /cbab sim run with no group present.
--
-- CBAB.Solver.BuildSlots(paladins, classCounts) -> slots
--
-- paladins: array of { name, spec, kings, sanctuary, impMight, impWisdom }
--   `spec` is cosmetic and used only as a sort tie-break (5.2).
-- classCounts: { physical = N, caster = N } -- raid-wide headcount of
--   members who benefit from Might vs Wisdom, pre-classified by the caller
--   (Roster.lua, using roster-page spec hints + live data per spec 5.4).
--   BuildSlots never reads game state itself, only these two numbers.
--
-- slots: ordered array { { blessing = "salv", caster = "Sanctara" }, ... }
--   Priority order per spec 5.1: salv, kings (omitted if no paladin has the
--   talent), whichever of might/wisdom the raid values more, the other of
--   the two, light. Truncated to the first N entries for N paladins -- with
--   Kings omitted the list shifts up, so a 4th paladin can land on Light
--   (spec 5.1). With 5+ paladins every tier is covered; a 6th paladin gets
--   no slot of his own (spec 5.3) and is left free for override work.

CBAB.Solver = CBAB.Solver or {}

-- Higher rank wins; ties fall through to spec then name, both ascending,
-- so ties/zeros/duplicate talents are deterministic and never warn (5.2).
local function isBetter(a, b, rank)
	local ra, rb = rank(a), rank(b)
	if ra ~= rb then return ra > rb end
	local sa, sb = a.spec or "", b.spec or ""
	if sa ~= sb then return sa < sb end
	return (a.name or "") < (b.name or "")
end

local ZERO_RANK = function() return 0 end

local SLOT_RULES = {
	kings = { eligible = function(p) return p.kings == true end, rank = ZERO_RANK },
	might = { rank = function(p) return p.impMight or 0 end },
	wisdom = { rank = function(p) return p.impWisdom or 0 end },
}

function CBAB.Solver.BuildSlots(paladins, classCounts)
	local n = #paladins

	local hasKings = false
	for _, p in ipairs(paladins) do
		if p.kings then
			hasKings = true
			break
		end
	end

	local physical = (classCounts and classCounts.physical) or 0
	local caster = (classCounts and classCounts.caster) or 0
	-- Tie favors Might, matching the value table's relative ordering (spec 4).
	local primary, secondary
	if caster > physical then
		primary, secondary = "wisdom", "might"
	else
		primary, secondary = "might", "wisdom"
	end

	local order = { "salv" }
	if hasKings then
		order[#order + 1] = "kings"
	end
	order[#order + 1] = primary
	order[#order + 1] = secondary
	order[#order + 1] = "light"

	local count = math.min(n, #order)
	local slots = {}
	for i = 1, count do
		slots[i] = { blessing = order[i] }
	end

	-- Fill the most-constrained slot (Kings, talent-gated) first, then the
	-- rest in priority order, so a scarce Kings-capable paladin isn't
	-- accidentally consumed by an earlier, unconstrained slot. Still a
	-- single greedy pass -- no backtracking, no cost matrix (spec 5.0/5.9).
	local fillOrder = {}
	local kingsIndex
	for i, slot in ipairs(slots) do
		if slot.blessing == "kings" then kingsIndex = i end
	end
	if kingsIndex then
		fillOrder[#fillOrder + 1] = kingsIndex
	end
	for i = 1, count do
		if i ~= kingsIndex then
			fillOrder[#fillOrder + 1] = i
		end
	end

	local available = {}
	for i, p in ipairs(paladins) do
		available[i] = p
	end

	local function takeBest(rule)
		local eligible = rule and rule.eligible
		local rank = (rule and rule.rank) or ZERO_RANK
		local bestIndex, best
		for i, p in ipairs(available) do
			if not eligible or eligible(p) then
				if not best or isBetter(p, best, rank) then
					best, bestIndex = p, i
				end
			end
		end
		if bestIndex then
			table.remove(available, bestIndex)
		end
		return best
	end

	for _, idx in ipairs(fillOrder) do
		local slot = slots[idx]
		local caster = takeBest(SLOT_RULES[slot.blessing])
		slot.caster = caster and caster.name or nil
	end

	return slots
end
