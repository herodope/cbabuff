local ADDON, CBAB = ...

-- The config page (spec 11.5): warnings, bar and alert positioning, debug
-- toggles, and the hunter pet blessings toggle.

CBAB.Config = {}

local window = CreateFrame("Frame", "CBABuffConfig", UIParent)
window:SetSize(380, 600)
window:SetPoint("CENTER")
window:SetMovable(true)
window:EnableMouse(true)
window:SetClampedToScreen(true)
CBAB:ApplyBackdrop(window, {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
window:Hide()

local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -12)
title:SetText("CBA Buff -- Config")

local closeButton = CreateFrame("Button", nil, window, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -4, -4)
closeButton:SetScript("OnClick", function() window:Hide() end)

window:RegisterForDrag("LeftButton")
window:SetScript("OnDragStart", function() window:StartMoving() end)
window:SetScript("OnDragStop", function() window:StopMovingOrSizing() end)

-- ============================================================
-- Small widget helpers, all bound to a `get()`/`set(value)` pair rather
-- than a fixed table+key, since fields come from three different tables
-- (char.warnings, char.ui.bar, char.ui.alert, char.debug, and the active
-- profile's wants -- see the pet toggle below).
-- ============================================================

local sections = {}
local nextY = -36

local function sectionHeader(text)
	local header = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	header:SetPoint("TOPLEFT", 16, nextY)
	header:SetText(text)
	nextY = nextY - 18
	return header
end

local function checkbox(label, get, set)
	local cb = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
	cb:SetSize(20, 20)
	cb:SetPoint("TOPLEFT", 20, nextY)
	local text = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
	text:SetText(label)
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	cb.refresh = function() cb:SetChecked(get() and true or false) end
	sections[#sections + 1] = cb
	nextY = nextY - 22
	return cb
end

local function numberField(label, get, set)
	local box = CreateFrame("EditBox", nil, window, "InputBoxTemplate")
	box:SetSize(50, 18)
	box:SetPoint("TOPLEFT", 30, nextY)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	local text = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("LEFT", box, "RIGHT", 6, 0)
	text:SetText(label)
	box:SetScript("OnEditFocusLost", function(self)
		local n = tonumber(self:GetText())
		if n then set(n) end
		self:SetText(tostring(get()))
	end)
	box.refresh = function() box:SetText(tostring(get())) end
	sections[#sections + 1] = box
	nextY = nextY - 24
	return box
end

-- ============================================================
-- Warnings (spec 11.4's toggles, exposed here per 11.5).
-- ============================================================

sectionHeader("Warnings")

-- Resolved fresh on every get/set rather than cached, so nothing here
-- goes stale across a reload.
local function warnings() return CBAB.DB:Char().warnings end

checkbox("Enabled (local text + sound, your own assignments)", function() return warnings().enabled end,
	function(v) warnings().enabled = v end)
numberField("Threshold (seconds before 'expiring')", function() return warnings().threshold end,
	function(v) warnings().threshold = v end)
checkbox("Sound", function() return warnings().sound end, function(v) warnings().sound = v end)
checkbox("Screen text", function() return warnings().screenText end, function(v) warnings().screenText = v end)
checkbox("Whisper responsible paladin (leader-enabled, max 1/60s, never in combat)",
	function() return warnings().whisper end, function(v) warnings().whisper = v end)

nextY = nextY - 8

-- ============================================================
-- Bar / Alert positioning. Dragging (Bar.lua's handle) is the primary way
-- to move the bar; these are the toggles/scale that dragging can't cover.
-- The alert window has no drag handle of its own, so its X/Y offsets are
-- exposed directly here.
-- ============================================================

sectionHeader("Paladin bar")
checkbox("Show bar", function() return CBAB.DB:Char().ui.bar.shown ~= false end,
	function(v) CBAB.Bar_SetShown(v) end)
checkbox("Locked (disable dragging and resizing)", function() return CBAB.DB:Char().ui.bar.locked end,
	function(v)
		CBAB.DB:Char().ui.bar.locked = v
		if CBAB.Bar_RefreshChrome then CBAB.Bar_RefreshChrome() end
	end)
checkbox("Compact", function() return CBAB.DB:Char().ui.bar.compact end,
	function(v) CBAB.DB:Char().ui.bar.compact = v end)
numberField("Scale (%)", function() return math.floor(CBAB.DB:Char().ui.bar.scale * 100) end,
	function(v) CBAB.DB:Char().ui.bar.scale = v / 100 end)

nextY = nextY - 8

sectionHeader("Alert window")
checkbox("Auto-hide when clean", function() return CBAB.DB:Char().ui.alert.autoHide end,
	function(v) CBAB.DB:Char().ui.alert.autoHide = v end)
checkbox("Suppress in combat", function() return CBAB.DB:Char().ui.alert.hideInCombat end,
	function(v) CBAB.DB:Char().ui.alert.hideInCombat = v end)
numberField("X offset", function() return CBAB.DB:Char().ui.alert.x end,
	function(v) CBAB.DB:Char().ui.alert.x = v end)
numberField("Y offset", function() return CBAB.DB:Char().ui.alert.y end,
	function(v) CBAB.DB:Char().ui.alert.y = v end)

nextY = nextY - 8

-- ============================================================
-- Debug
-- ============================================================

sectionHeader("Debug")
checkbox("Enabled", function() return CBAB.DB:Char().debug.enabled end,
	function(v) CBAB.DB:Char().debug.enabled = v end)
checkbox("Verbose", function() return CBAB.DB:Char().debug.verbose end,
	function(v) CBAB.DB:Char().debug.verbose = v end)

nextY = nextY - 8

-- ============================================================
-- Hunter pet blessings: NOT a personal display preference. This is a
-- profile-level, raid-wide setting -- toggling it changes what the solver
-- produces and therefore what gets pushed to every paladin in the raid,
-- not just what this client shows (spec 5.6, 11.5). Styled and labelled
-- distinctly from everything else on this page for exactly that reason.
-- ============================================================

sectionHeader("|cffffcc00Hunter pet blessings|r")
local petWarning = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
petWarning:SetPoint("TOPLEFT", 20, nextY)
petWarning:SetPoint("TOPRIGHT", -16, nextY)
petWarning:SetJustifyH("LEFT")
petWarning:SetWordWrap(true)
petWarning:SetText("This is saved on the active PROFILE, not this character. Changing it "
	.. "alters the plan every paladin in the raid receives on the next solve/push -- it is "
	.. "not a personal display setting.")
nextY = nextY - 28

local petCheckbox = checkbox("Pets enabled (this profile)",
	function()
		local profile = CBAB.DB:Profile()
		return profile and profile.wants and profile.wants.petsEnabled
	end,
	function(v)
		local profile = CBAB.DB:Profile()
		if profile and profile.wants then
			profile.wants.petsEnabled = v
			profile.modified = time()
		end
	end)

-- ============================================================
-- Refresh / Toggle
-- ============================================================

local function refreshAll()
	for _, widget in ipairs(sections) do
		if widget.refresh then widget:refresh() end
	end
end

function CBAB.Config:Toggle()
	if window:IsShown() then
		window:Hide()
	else
		window:Show()
		refreshAll()
	end
end

function CBAB.Config:Show()
	window:Show()
	refreshAll()
end

CBAB.SlashCommands.config = function() CBAB.Config:Toggle() end
