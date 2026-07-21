local ADDON, CBAB = ...

CBAB.version = GetAddOnMetadata(ADDON, "Version") or "dev"

-- The one and only event frame for the entire addon. No other module may
-- create a CreateFrame("Frame") of its own; everything subscribes here.
local frame = CreateFrame("Frame")
CBAB.frame = frame

-- registry[event][key] = handler. "event" covers both real WoW events
-- (registered on `frame`) and custom cross-module messages fired via
-- CBAB:Fire, so On/Off/Fire work uniformly for either.
local registry = {}
local registeredWithFrame = {}

local function dispatch(event, ...)
	local handlers = registry[event]
	if not handlers then return end
	for key, handler in pairs(handlers) do
		local ok, err = pcall(handler, ...)
		if not ok then
			CBAB:Print(CBAB.L.HANDLER_ERROR:format(event, tostring(key), tostring(err)))
		end
	end
end

frame:SetScript("OnEvent", function(_, event, ...)
	dispatch(event, ...)
end)

function CBAB:On(event, key, handler)
	registry[event] = registry[event] or {}
	registry[event][key] = handler

	if registeredWithFrame[event] == nil then
		-- Custom messages (e.g. "ROSTER_CHANGED") aren't real WoW events;
		-- RegisterEvent errors on those, so probe safely.
		registeredWithFrame[event] = pcall(frame.RegisterEvent, frame, event)
	end
end

function CBAB:Off(event, key)
	local handlers = registry[event]
	if not handlers then return end

	handlers[key] = nil
	if next(handlers) == nil then
		registry[event] = nil
		if registeredWithFrame[event] then
			frame:UnregisterEvent(event)
		end
		registeredWithFrame[event] = nil
	end
end

function CBAB:Fire(msg, ...)
	dispatch(msg, ...)
end

function CBAB:After(delay, fn)
	C_Timer.After(delay, fn)
end

function CBAB:Print(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	DEFAULT_CHAT_FRAME:AddMessage("|cff3399ffCBA Buff|r: " .. table.concat(parts, " "))
end

-- ============================================================
-- Mode detection (spec 2.1)
--
-- Two modes exist in v1: coordinator (leader/assist) and paladin
-- (player's class). A player can be both. `passive` is reserved for a
-- future mode (deferred features, spec 5.7 / v3) and carries no behaviour
-- yet -- it exists only so adding it later needs no restructuring.
-- ============================================================

local _, playerClassToken = UnitClass("player")

local mode = {
	coordinator = false,
	paladin = false,
	passive = false,
}

local function isCoordinator()
	if not IsInGroup() then return false end
	if UnitIsGroupLeader("player") then return true end
	if IsInRaid() and IsRaidOfficer() then return true end
	return false
end

local function evaluateMode()
	mode.paladin = playerClassToken == "PALADIN"
	mode.coordinator = isCoordinator()
	mode.passive = not mode.paladin and not mode.coordinator
end

function CBAB:Mode()
	return mode
end

CBAB:On("PLAYER_LOGIN", "core:mode", evaluateMode)
CBAB:On("GROUP_ROSTER_UPDATE", "core:mode", evaluateMode)

local function modeLabel()
	local parts = {}
	if mode.coordinator then parts[#parts + 1] = "coordinator" end
	if mode.paladin then parts[#parts + 1] = "paladin" end
	if #parts == 0 then parts[#parts + 1] = "passive" end
	return table.concat(parts, "+")
end

-- ============================================================
-- Slash command router
-- ============================================================

-- Other modules register into this table (e.g. CBAB.DumpHandlers.assign = fn)
-- so `/cbab dump <topic>` can grow without Core knowing about every module.
CBAB.DumpHandlers = {}

CBAB.DumpHandlers.spells = function()
	CBAB:Print("-- Blessings --")
	for _, id in ipairs(CBAB.BlessingOrder) do
		local b = CBAB.Blessings[id]
		CBAB:Print(("%s (%s): normal={%s} greater={%s} texture=%s talentGated=%s"):format(
			b.name, id,
			table.concat(b.normalIDs, ","),
			table.concat(b.greaterIDs, ","),
			b.texture,
			tostring(b.talentGated)
		))
	end
end

-- Other modules register into this table (e.g. CBAB.SlashCommands.sim = fn)
-- for subcommands beyond the two Core owns directly (bare, dump).
CBAB.SlashCommands = {}

local function SlashHandler(msg)
	msg = strtrim(msg or "")
	local command, rest = msg:match("^(%S*)%s*(.-)$")
	command = command:lower()

	if command == "" then
		-- Section 13: bare /cbab toggles the editor. Kept as a graceful
		-- fallback (print version+mode) if UI/Editor.lua somehow isn't
		-- loaded, rather than silently doing nothing.
		if CBAB.Editor then
			CBAB.Editor:Toggle()
		else
			CBAB:Print(CBAB.L.VERSION_LINE:format(CBAB.version, modeLabel()))
		end
	elseif command == "version" then
		CBAB:Print(CBAB.L.VERSION_LINE:format(CBAB.version, modeLabel()))
	elseif command == "dump" then
		local topic = rest:match("^(%S*)"):lower()
		local handler = CBAB.DumpHandlers[topic]
		if handler then
			handler()
		else
			CBAB:Print(CBAB.L.UNKNOWN_TOPIC)
		end
	else
		local handler = CBAB.SlashCommands[command]
		if handler then
			handler(rest)
		end
	end
end

SLASH_CBAB1 = "/cbab"
SLASH_CBAB2 = "/cbabuff"
SlashCmdList["CBAB"] = SlashHandler
