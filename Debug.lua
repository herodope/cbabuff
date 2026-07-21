local ADDON, CBAB = ...

-- Log ring buffer, /cbab debug on|off|verbose, /cbab dump log|comm.
-- The other /cbab dump topics (roster, assign, comm epoch, talents,
-- cache, spells) are each owned by the module they describe -- this file
-- only owns the ring buffer itself and the two pieces of the slash
-- surface (spec 13) nothing else claimed: `debug` and `dump log`.

local L = CBAB.L
CBAB.Debug = {}

local MAX_LOG_ENTRIES = 200
local logBuffer = {}
local window -- forward-declared: Log() below references it before its creation further down

-- ============================================================
-- Ring buffer. Anything in the addon can call CBAB.Debug:Log(...) to
-- record a diagnostic line; it's cheap and silently does nothing unless
-- debug logging is turned on (spec 13's /cbab debug on|off|verbose).
-- ============================================================

function CBAB.Debug:Log(...)
	if not CBAB.DB:Char().debug.enabled then return end

	local n = select("#", ...)
	local parts = {}
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	local line = ("[%s] %s"):format(date("%H:%M:%S"), table.concat(parts, " "))

	logBuffer[#logBuffer + 1] = line
	if #logBuffer > MAX_LOG_ENTRIES then
		table.remove(logBuffer, 1)
	end

	if CBAB.DB:Char().debug.verbose then
		CBAB:Print("|cff888888[debug]|r " .. line)
	end

	if window:IsShown() then
		CBAB.Debug:RefreshWindow()
	end
end

-- ============================================================
-- Scrollable log window -- explicitly NOT chat spam. A single
-- word-wrapped FontString inside a standard scroll frame, refreshed only
-- when a new line comes in while it's open or when it's (re)shown.
-- ============================================================

window = CreateFrame("Frame", "CBABuffDebugLog", UIParent)
window:SetSize(500, 320)
window:SetPoint("CENTER")
window:SetMovable(true)
window:EnableMouse(true)
window:SetClampedToScreen(true)
window:SetBackdrop({
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
window:Hide()

local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -12)
title:SetText("CBA Buff -- Debug Log")

local closeButton = CreateFrame("Button", nil, window, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -4, -4)
closeButton:SetScript("OnClick", function() window:Hide() end)

local clearButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
clearButton:SetSize(70, 20)
clearButton:SetPoint("BOTTOMLEFT", 12, 12)
clearButton:SetText("Clear")
clearButton:SetScript("OnClick", function()
	logBuffer = {}
	CBAB.Debug:RefreshWindow()
end)

window:RegisterForDrag("LeftButton")
window:SetScript("OnDragStart", function() window:StartMoving() end)
window:SetScript("OnDragStop", function() window:StopMovingOrSizing() end)

local scrollFrame = CreateFrame("ScrollFrame", "CBABuffDebugLogScroll", window, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", 12, -36)
scrollFrame:SetPoint("BOTTOMRIGHT", -34, 40)

local logText = scrollFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
logText:SetFontObject(ChatFontSmall)
logText:SetJustifyH("LEFT")
logText:SetJustifyV("TOP")
logText:SetWidth(440)
scrollFrame:SetScrollChild(logText)

function CBAB.Debug:RefreshWindow()
	if #logBuffer == 0 then
		logText:SetText("(empty)")
	else
		logText:SetText(table.concat(logBuffer, "\n"))
	end
	logText:SetHeight(logText:GetStringHeight())
	scrollFrame:UpdateScrollChildRect()
	scrollFrame:SetVerticalScroll(scrollFrame:GetVerticalScrollRange() or 0)
end

function CBAB.Debug:ShowWindow()
	window:Show()
	CBAB.Debug:RefreshWindow()
end

CBAB.DumpHandlers.log = function() CBAB.Debug:ShowWindow() end

-- ============================================================
-- /cbab dump comm: epoch table + throttle/queue snapshot. Comm.lua owns
-- the data (CBAB.Comm:EpochTable()); this just presents it, matching how
-- every other /cbab dump topic is owned by the module it describes.
-- ============================================================

CBAB.DumpHandlers.comm = function()
	CBAB:Print("-- Comm epoch table --")
	local any = false
	for name, epoch in pairs(CBAB.Comm:EpochTable()) do
		any = true
		CBAB:Print(("  %s: %d"):format(name, epoch))
	end
	if not any then
		CBAB:Print("  (no other clients heard from yet)")
	end
end

-- ============================================================
-- /cbab debug on|off|verbose
-- ============================================================

CBAB.SlashCommands.debug = function(rest)
	local arg = (rest or ""):match("^(%S*)"):lower()
	local debugDB = CBAB.DB:Char().debug

	if arg == "on" then
		debugDB.enabled = true
		CBAB:Print(L.DEBUG_ENABLED)
	elseif arg == "off" then
		debugDB.enabled = false
		debugDB.verbose = false
		CBAB:Print(L.DEBUG_DISABLED)
	elseif arg == "verbose" then
		debugDB.enabled = true
		debugDB.verbose = true
		CBAB:Print(L.DEBUG_VERBOSE_ENABLED)
	else
		CBAB:Print(L.DEBUG_USAGE)
	end
end
