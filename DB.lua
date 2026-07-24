local ADDON, CBAB = ...

-- Sole owner of SavedVariables. Nothing else touches CBABuffDB / CBABuffCharDB.

local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")

CBAB.DB = {}

local DB_SCHEMA_VERSION = 1
local CHAR_SCHEMA_VERSION = 2

local function copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do
		out[k] = copy(v)
	end
	return out
end

-- ============================================================
-- Migrations: a numbered chain of pure functions on the table, keyed by
-- the schemaVersion they upgrade *to*. Future versions add keys here
-- rather than rewriting existing profiles, so older members never lose
-- their splits. Version 1 is the baseline shipped now, so both chains
-- start empty.
-- ============================================================

local DB_MIGRATIONS = {
	-- [2] = function(db) db.someNewKey = db.someNewKey or default end,
}

local CHAR_MIGRATIONS = {
	-- v2: the pbar's old boolean compact toggle became a 3-state size cycle
	-- (minimized/compact/expanded, UI/Bar.lua). old compact=true meant the
	-- single-row "your casts" layout, which is the new "compact" state;
	-- compact=false meant the always-shown multi-row grid, now "expanded".
	-- The old `compact` key is left in place, just unread from here on --
	-- this file never deletes old data (see header comment above).
	[2] = function(char)
		char.ui = char.ui or {}
		char.ui.bar = char.ui.bar or {}
		if char.ui.bar.size == nil then
			char.ui.bar.size = (char.ui.bar.compact == false) and "expanded" or "compact"
		end
	end,
}

local function applyMigrations(tbl, migrations, targetVersion)
	tbl.schemaVersion = tbl.schemaVersion or 1
	for version = tbl.schemaVersion + 1, targetVersion do
		local migrate = migrations[version]
		if migrate then
			migrate(tbl)
		end
		tbl.schemaVersion = version
	end
	return tbl
end

-- ============================================================
-- Init
-- ============================================================

function CBAB.DB:Init()
	if type(CBABuffDB) ~= "table" then
		CBABuffDB = copy(CBAB.Defaults.db)
	else
		applyMigrations(CBABuffDB, DB_MIGRATIONS, DB_SCHEMA_VERSION)
		CBABuffDB.profiles = CBABuffDB.profiles or {}
		CBABuffDB.capabilityCache = CBABuffDB.capabilityCache or {}
		if CBABuffDB.autoDetectSplit == nil then
			CBABuffDB.autoDetectSplit = CBAB.Defaults.db.autoDetectSplit
		end
	end

	if type(CBABuffCharDB) ~= "table" then
		CBABuffCharDB = copy(CBAB.Defaults.char)
	else
		applyMigrations(CBABuffCharDB, CHAR_MIGRATIONS, CHAR_SCHEMA_VERSION)
		-- Fill any top-level default keys added since this character last logged in.
		for k, v in pairs(CBAB.Defaults.char) do
			if CBABuffCharDB[k] == nil then
				CBABuffCharDB[k] = copy(v)
			end
		end
	end
end

CBAB:On("ADDON_LOADED", "db:init", function(loadedAddon)
	if loadedAddon ~= ADDON then return end
	CBAB.DB:Init()
	CBAB:Off("ADDON_LOADED", "db:init")
end)

-- ============================================================
-- Accessors
-- ============================================================

function CBAB.DB:Char()
	return CBABuffCharDB
end

function CBAB.DB:Cache()
	if not CBABuffDB then return {} end
	return CBABuffDB.capabilityCache
end

-- CBABuffDB is nil until ADDON_LOADED fires and CBAB.DB:Init() runs, which
-- happens only after every file in the TOC (including this one and every
-- UI file) has already executed once. UIDropDownMenu_Initialize calls its
-- init function immediately during that first execution pass -- not only
-- later when the menu opens -- so anything wired to a dropdown built at
-- file scope (e.g. UI/RosterPage.lua's profile dropdown) can call these
-- accessors before CBABuffDB exists. Guard rather than assume Init() has
-- already run.
function CBAB.DB:Profile()
	if not CBABuffDB then return nil end
	return CBABuffDB.profiles[CBABuffDB.activeProfile]
end

function CBAB.DB:Profiles()
	if not CBABuffDB then return {} end
	return CBABuffDB.profiles
end

-- ============================================================
-- Profile CRUD
-- ============================================================

function CBAB.DB:SetActiveProfile(name)
	if not CBABuffDB.profiles[name] then
		return false, "no such profile: " .. tostring(name)
	end

	CBABuffDB.activeProfile = name
	CBAB:Fire("ASSIGNMENT_CHANGED")
	return true
end

function CBAB.DB:CreateProfile(name)
	if type(name) ~= "string" or name == "" then
		return false, "profile name must be a non-empty string"
	end
	if CBABuffDB.profiles[name] then
		return false, "a profile named '" .. name .. "' already exists"
	end

	CBABuffDB.profiles[name] = {
		name = name,
		modified = time(),
		roster = {},
		wants = copy(CBAB.Defaults.wants),
		assignment = {
			epoch = 0,
			author = "",
			timestamp = 0,
			greaters = {},
			overrides = {},
			-- [paladinName] = auraId. Manual-only in v1 (see SPEC.md) -- no
			-- solver slot construction, just a plan field the roster page and
			-- pbar read/write directly.
			auras = {},
		},
	}
	return true
end

function CBAB.DB:DeleteProfile(name)
	if not CBABuffDB.profiles[name] then
		return false, "no such profile: " .. tostring(name)
	end

	CBABuffDB.profiles[name] = nil

	if CBABuffDB.activeProfile == name then
		CBABuffDB.activeProfile = nil
		CBAB:Fire("ASSIGNMENT_CHANGED")
	end
	return true
end

function CBAB.DB:RenameProfile(old, new)
	local profile = CBABuffDB.profiles[old]
	if not profile then
		return false, "no such profile: " .. tostring(old)
	end
	if type(new) ~= "string" or new == "" then
		return false, "profile name must be a non-empty string"
	end
	if new == old then
		return true
	end
	if CBABuffDB.profiles[new] then
		return false, "a profile named '" .. new .. "' already exists"
	end

	profile.name = new
	CBABuffDB.profiles[new] = profile
	CBABuffDB.profiles[old] = nil

	if CBABuffDB.activeProfile == old then
		CBABuffDB.activeProfile = new
	end
	return true
end

-- ============================================================
-- Export / Import (spec 7): LibSerialize -> LibDeflate -> print-safe string.
-- Import never trusts its input -- every stage is checked before anything
-- is written to CBABuffDB.
-- ============================================================

local function validateWants(wants)
	if type(wants) ~= "table" then return false, "wants must be a table" end
	if type(wants.petsEnabled) ~= "boolean" then return false, "wants.petsEnabled must be a boolean" end
	if type(wants.tanks) ~= "table" then return false, "wants.tanks must be a table" end
	if type(wants.pet) ~= "table" then return false, "wants.pet must be a table" end
	return true
end

local function validateAssignment(assignment)
	if type(assignment) ~= "table" then return false, "assignment must be a table" end
	if type(assignment.epoch) ~= "number" then return false, "assignment.epoch must be a number" end
	if type(assignment.greaters) ~= "table" then return false, "assignment.greaters must be a table" end
	if type(assignment.overrides) ~= "table" then return false, "assignment.overrides must be a table" end
	-- Optional: older exports predate the auras field (added alongside the
	-- pbar grid). Absent is fine; present-but-wrong-typed is not.
	if assignment.auras ~= nil and type(assignment.auras) ~= "table" then
		return false, "assignment.auras must be a table"
	end
	return true
end

local function validateProfile(profile)
	if type(profile) ~= "table" then
		return false, "decoded data is not a table"
	end
	if type(profile.name) ~= "string" or profile.name == "" then
		return false, "missing or invalid profile name"
	end
	if type(profile.roster) ~= "table" then
		return false, "missing or invalid roster"
	end

	local ok, err = validateWants(profile.wants)
	if not ok then return false, err end

	ok, err = validateAssignment(profile.assignment)
	if not ok then return false, err end

	return true
end

function CBAB.DB:Export(name)
	local profile = CBABuffDB.profiles[name]
	if not profile then
		return nil, "no such profile: " .. tostring(name)
	end

	local serialized = LibSerialize:Serialize(profile)
	local compressed = LibDeflate:CompressDeflate(serialized)
	return LibDeflate:EncodeForPrint(compressed)
end

function CBAB.DB:Import(str)
	if type(str) ~= "string" or str == "" then
		return false, "nothing to import"
	end

	local ok, profile = pcall(function()
		local compressed = LibDeflate:DecodeForPrint(str)
		if not compressed then
			error("not a valid CBA Buff export string", 0)
		end

		local serialized = LibDeflate:DecompressDeflate(compressed)
		if not serialized then
			error("failed to decompress data", 0)
		end

		local deserializeOk, data = LibSerialize:Deserialize(serialized)
		if not deserializeOk then
			error("failed to deserialize data", 0)
		end

		return data
	end)

	if not ok then
		return false, profile
	end

	local valid, err = validateProfile(profile)
	if not valid then
		return false, err
	end

	CBABuffDB.profiles[profile.name] = profile

	if CBABuffDB.activeProfile == profile.name then
		CBAB:Fire("ASSIGNMENT_CHANGED")
	end

	return true
end

-- ============================================================
-- /cbab dump assign | cache
-- ============================================================

CBAB.DumpHandlers.assign = function()
	local profile = CBAB.DB:Profile()
	if not profile then
		CBAB:Print("no active profile")
		return
	end

	local a = profile.assignment
	CBAB:Print(("-- Assignment (%s) -- epoch=%d author=%s"):format(profile.name, a.epoch, tostring(a.author)))

	for caster, classes in pairs(a.greaters) do
		for class, blessing in pairs(classes) do
			CBAB:Print(("  greater: %s -> %s = %s"):format(caster, class, blessing))
		end
	end

	for _, o in ipairs(a.overrides) do
		CBAB:Print(("  override: %s -> %s = %s (%s)"):format(o.caster, o.target, o.blessing, tostring(o.reason)))
	end
end

CBAB.DumpHandlers.cache = function()
	local cache = CBAB.DB:Cache()
	local count = 0
	for nameRealm, entry in pairs(cache) do
		count = count + 1
		CBAB:Print(("  %s: class=%s activeGroup=%s source=%s seen=%s"):format(
			nameRealm, tostring(entry.class), tostring(entry.activeGroup), tostring(entry.source), tostring(entry.seen)))
	end
	CBAB:Print(("-- Capability cache (%d entries) --"):format(count))
end
