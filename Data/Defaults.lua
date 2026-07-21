local ADDON, CBAB = ...

-- Pure data. Default want-lists, UI positions, warning thresholds, and the
-- shape of a freshly initialised SavedVariables table for both DBs (spec 10).

CBAB.Defaults = {}

-- Seeded onto a newly created profile's `wants` table (spec 5.5, 5.6).
CBAB.Defaults.wants = {
	petsEnabled = true,
	tanks = {
		PALADIN = { "kings", "wisdom", "sanctuary", "light" },
		DRUID = { "kings", "might", "light" },
		WARRIOR = { "kings", "might", "light", "sanctuary" },
	},
	pet = { "might", "kings", "light" },
	-- Manual class/spec headcounts entered on the roster page (spec 11.6),
	-- keyed CLASS -> specKey -> integer count. Purely informational input
	-- feeding the Might/Wisdom majority preview on that same page ahead of
	-- getting real numbers from live raid data or addon comms.
	specCounts = {},
}

-- Shape of a fresh `CBABuffDB` (account-wide).
CBAB.Defaults.db = {
	schemaVersion = 1,
	activeProfile = nil,
	autoDetectSplit = true,
	profiles = {},
	capabilityCache = {},
}

-- Shape of a fresh `CBABuffCharDB` (per character).
CBAB.Defaults.char = {
	schemaVersion = 1,
	ui = {
		bar = { point = "CENTER", x = 0, y = -180, scale = 1.0, locked = false, compact = true },
		alert = { point = "CENTER", x = 0, y = 200, scale = 1.0, autoHide = true, hideInCombat = true },
	},
	warnings = { enabled = true, threshold = 120, sound = true, screenText = true, whisper = false },
	debug = { enabled = false, verbose = false },
	-- One-time PallyPower button-name collision warning (spec 11.2).
	warnedPallyPowerCollision = false,
}
