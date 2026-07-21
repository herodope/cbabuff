local ADDON, CBAB = ...

-- The roster page (spec 7, 11.6): 25 slots, name entry, tank flags, an
-- optional plannedGroup pin, a profile switcher, and export/import.
--
-- profile.roster is kept as a DENSE array (no nil holes) rather than 25
-- fixed independently-addressable slots. This matters beyond just this
-- file: several places in the codebase (e.g. Solve.lua's roster walk)
-- iterate profile.roster with ipairs, which silently stops at the first
-- nil -- a sparse array with a gap in slot 3 would make every entry from
-- slot 4 onward invisible to the solver. Deleting a row removes it and
-- shifts everything after it up, so that can never happen. The 25 rows
-- shown are just "the array, plus one blank row to type a new entry into
-- at the end" -- not literally 25 fixed slots.
--
-- Class/spec are optional planning hints ONLY (spec 6, 7): live raid data
-- always overrides them, the solver never reads spec except as a cosmetic
-- tiebreak, and nobody should believe setting it configures anything. Both
-- fields are deliberately small and dim compared to name/tank.

CBAB.RosterPage = {}

local ROW_HEIGHT = 20
local MAX_DISPLAY_ROWS = 25

-- ============================================================
-- Window
-- ============================================================

local window = CreateFrame("Frame", "CBABuffRosterPage", UIParent)
window:SetSize(520, 480)
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
title:SetText("CBA Buff -- Roster")

local closeButton = CreateFrame("Button", nil, window, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -4, -4)
closeButton:SetScript("OnClick", function() window:Hide() end)

window:RegisterForDrag("LeftButton")
window:SetScript("OnDragStart", function() window:StartMoving() end)
window:SetScript("OnDragStop", function() window:StopMovingOrSizing() end)

-- ============================================================
-- Profile switcher. No UIDropDownMenu (avoids that template's boilerplate
-- for a case this simple): a name box plus New/Rename/Delete/Switch
-- buttons acting on whatever's typed, and a clickable list of existing
-- profile names underneath for discoverability.
-- ============================================================

local profileBar = CreateFrame("Frame", nil, window)
profileBar:SetPoint("TOPLEFT", 12, -36)
profileBar:SetPoint("TOPRIGHT", -12, -36)
profileBar:SetHeight(22)

local activeProfileText = profileBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
activeProfileText:SetPoint("LEFT", 0, 0)

local profileNameBox = CreateFrame("EditBox", nil, profileBar, "InputBoxTemplate")
profileNameBox:SetSize(120, 20)
profileNameBox:SetPoint("LEFT", 160, 0)
profileNameBox:SetAutoFocus(false)

local function profileButton(label, xOffset, onClick)
	local btn = CreateFrame("Button", nil, profileBar, "UIPanelButtonTemplate")
	btn:SetSize(60, 20)
	btn:SetPoint("LEFT", profileNameBox, "RIGHT", xOffset, 0)
	btn:SetText(label)
	btn:SetScript("OnClick", onClick)
	return btn
end

local function refreshAll() end -- forward-declared, assigned below

profileButton("Switch", 6, function()
	local name = profileNameBox:GetText()
	local ok, err = CBAB.DB:SetActiveProfile(name)
	if not ok then CBAB:Print(err) end
	refreshAll()
end)
profileButton("New", 72, function()
	local name = profileNameBox:GetText()
	local ok, err = CBAB.DB:CreateProfile(name)
	if ok then
		CBAB.DB:SetActiveProfile(name)
	else
		CBAB:Print(err)
	end
	refreshAll()
end)
profileButton("Rename", 138, function()
	local profile = CBAB.DB:Profile()
	local newName = profileNameBox:GetText()
	if not profile then CBAB:Print("no active profile") return end
	local ok, err = CBAB.DB:RenameProfile(profile.name, newName)
	if not ok then CBAB:Print(err) end
	refreshAll()
end)
profileButton("Delete", 210, function()
	local name = profileNameBox:GetText()
	local ok, err = CBAB.DB:DeleteProfile(name)
	if not ok then CBAB:Print(err) end
	refreshAll()
end)

local profileListText = profileBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
profileListText:SetPoint("TOPLEFT", 0, -22)
profileListText:SetPoint("TOPRIGHT", 0, -22)
profileListText:SetJustifyH("LEFT")

-- ============================================================
-- Roster rows: name, class hint, spec hint, tank flag, plannedGroup,
-- delete.
-- ============================================================

local scrollFrame = CreateFrame("ScrollFrame", "CBABuffRosterScroll", window, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", 12, -108)
scrollFrame:SetPoint("BOTTOMRIGHT", -34, 96)

local content = CreateFrame("Frame", nil, scrollFrame)
content:SetSize(460, MAX_DISPLAY_ROWS * ROW_HEIGHT)
scrollFrame:SetScrollChild(content)

local rows = {}

local function commitRoster()
	-- Compact away any entry whose name is now empty, keeping the array
	-- dense (see file header). Called after every field edit.
	local profile = CBAB.DB:Profile()
	if not profile then return end
	local compact = {}
	for _, r in ipairs(profile.roster) do
		if r.name and r.name ~= "" then
			compact[#compact + 1] = r
		end
	end
	profile.roster = compact
	profile.modified = time()
end

local function createRow(index)
	local row = CreateFrame("Frame", nil, content)
	row:SetSize(460, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

	row.indexText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.indexText:SetPoint("LEFT", 0, 0)
	row.indexText:SetWidth(20)
	row.indexText:SetText(tostring(index))

	row.nameBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.nameBox:SetSize(140, 18)
	row.nameBox:SetPoint("LEFT", 24, 0)
	row.nameBox:SetAutoFocus(false)

	row.tank = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	row.tank:SetSize(18, 18)
	row.tank:SetPoint("LEFT", row.nameBox, "RIGHT", 8, 0)

	-- Class/spec hints: deliberately small, dim, secondary (spec 6/7/11.6)
	-- -- these are planning hints only, never read by the solver as
	-- anything but a cosmetic tiebreak, and always overridden by live data.
	row.classBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.classBox:SetSize(70, 14)
	row.classBox:SetPoint("LEFT", row.tank, "RIGHT", 8, 0)
	row.classBox:SetAutoFocus(false)
	row.classBox:SetFontObject(GameFontDisableSmall)

	row.specBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.specBox:SetSize(70, 14)
	row.specBox:SetPoint("LEFT", row.classBox, "RIGHT", 4, 0)
	row.specBox:SetAutoFocus(false)
	row.specBox:SetFontObject(GameFontDisableSmall)

	row.plannedGroupBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.plannedGroupBox:SetSize(20, 14)
	row.plannedGroupBox:SetPoint("LEFT", row.specBox, "RIGHT", 6, 0)
	row.plannedGroupBox:SetAutoFocus(false)
	row.plannedGroupBox:SetNumeric(true)

	local plannedLabel = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	plannedLabel:SetPoint("LEFT", row.plannedGroupBox, "RIGHT", 2, 0)
	plannedLabel:SetText("grp")

	row.deleteButton = CreateFrame("Button", nil, row, "UIPanelCloseButton")
	row.deleteButton:SetSize(16, 16)
	row.deleteButton:SetPoint("LEFT", plannedLabel, "RIGHT", 4, 0)

	return row
end

local function bindRow(row, index)
	local function entry()
		local profile = CBAB.DB:Profile()
		return profile and profile.roster[index]
	end

	local function ensureEntry()
		local profile = CBAB.DB:Profile()
		if not profile then return nil end
		profile.roster[index] = profile.roster[index] or { name = "" }
		return profile.roster[index]
	end

	row.nameBox:SetScript("OnEnterPressed", function(self)
		local e = ensureEntry()
		if e then e.name = self:GetText() end
		commitRoster()
		refreshAll()
		self:ClearFocus()
	end)
	row.nameBox:SetScript("OnEditFocusLost", function(self)
		local e = ensureEntry()
		if e then e.name = self:GetText() end
		commitRoster()
		refreshAll()
	end)

	row.classBox:SetScript("OnEditFocusLost", function(self)
		local e = entry()
		if e then e.class = self:GetText() ~= "" and self:GetText():upper() or nil end
	end)
	row.specBox:SetScript("OnEditFocusLost", function(self)
		local e = entry()
		if e then e.spec = self:GetText() ~= "" and self:GetText():lower() or nil end
	end)
	row.plannedGroupBox:SetScript("OnEditFocusLost", function(self)
		local e = entry()
		if e then
			local n = tonumber(self:GetText())
			e.plannedGroup = (n == 1 or n == 2) and n or nil
			self:SetText(e.plannedGroup and tostring(e.plannedGroup) or "")
		end
	end)

	row.tank:SetScript("OnClick", function(self)
		local e = ensureEntry()
		if e then e.tank = self:GetChecked() and true or false end
	end)

	row.deleteButton:SetScript("OnClick", function()
		local profile = CBAB.DB:Profile()
		if profile and profile.roster[index] then
			table.remove(profile.roster, index)
			profile.modified = time()
		end
		refreshAll()
	end)
end

local function getRow(index)
	local row = rows[index]
	if not row then
		row = createRow(index)
		bindRow(row, index)
		rows[index] = row
	end
	return row
end

-- ============================================================
-- Export / Import
-- ============================================================

local ioScroll = CreateFrame("ScrollFrame", "CBABuffRosterIOScroll", window, "UIPanelScrollFrameTemplate")
ioScroll:SetPoint("BOTTOMLEFT", 12, 44)
ioScroll:SetPoint("BOTTOMRIGHT", -34, 44)
ioScroll:SetHeight(48)

-- The EditBox's own height can exceed the scroll viewport -- WoW scrolls
-- within it -- so a longer export (a full 25-man roster + assignment)
-- doesn't just overflow invisibly past a fixed-height box.
local ioBox = CreateFrame("EditBox", nil, ioScroll)
ioBox:SetMultiLine(true)
ioBox:SetAutoFocus(false)
ioBox:SetFontObject(ChatFontNormal)
ioBox:SetWidth(440)
ioBox:SetHeight(200)
ioBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
ioScroll:SetScrollChild(ioBox)

local exportButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
exportButton:SetSize(80, 20)
exportButton:SetPoint("BOTTOMLEFT", 12, 12)
exportButton:SetText("Export")
exportButton:SetScript("OnClick", function()
	local profile = CBAB.DB:Profile()
	if not profile then
		CBAB:Print("no active profile to export")
		return
	end
	local str, err = CBAB.DB:Export(profile.name)
	if not str then
		CBAB:Print(err)
		return
	end
	ioBox:SetText(str)
	ioBox:HighlightText()
	ioBox:SetFocus()
end)

local importButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
importButton:SetSize(80, 20)
importButton:SetPoint("LEFT", exportButton, "RIGHT", 8, 0)
importButton:SetText("Import")
importButton:SetScript("OnClick", function()
	local text = ioBox:GetText()
	local ok, err = CBAB.DB:Import(text)
	if ok then
		CBAB:Print("import succeeded")
	else
		CBAB:Print("import failed: " .. tostring(err))
	end
	refreshAll()
end)

-- ============================================================
-- Refresh
-- ============================================================

refreshAll = function()
	local profile = CBAB.DB:Profile()
	activeProfileText:SetText(profile and ("Active: " .. profile.name) or "No active profile")

	local names = {}
	for name in pairs(CBAB.DB:Profiles()) do
		names[#names + 1] = name
	end
	table.sort(names)
	profileListText:SetText(#names > 0 and ("Profiles: " .. table.concat(names, ", ")) or "No profiles yet")

	local rosterCount = profile and #profile.roster or 0
	local displayCount = math.min(MAX_DISPLAY_ROWS, rosterCount + 1)

	for i = 1, displayCount do
		local row = getRow(i)
		row:Show()
		local e = profile and profile.roster[i]
		if e then
			row.nameBox:SetText(e.name or "")
			row.classBox:SetText(e.class or "")
			row.specBox:SetText(e.spec or "")
			row.plannedGroupBox:SetText(e.plannedGroup and tostring(e.plannedGroup) or "")
			row.tank:SetChecked(e.tank and true or false)
			row.deleteButton:Show()
		else
			row.nameBox:SetText("")
			row.classBox:SetText("")
			row.specBox:SetText("")
			row.plannedGroupBox:SetText("")
			row.tank:SetChecked(false)
			row.deleteButton:Hide()
		end
	end
	for i = displayCount + 1, #rows do
		rows[i]:Hide()
	end

	content:SetHeight(math.max(1, displayCount) * ROW_HEIGHT)
end

function CBAB.RosterPage:Toggle()
	if window:IsShown() then
		window:Hide()
	else
		window:Show()
		refreshAll()
	end
end

function CBAB.RosterPage:Show()
	window:Show()
	refreshAll()
end

CBAB:On("ASSIGNMENT_CHANGED", "rosterpage:refresh", function() if window:IsShown() then refreshAll() end end)
CBAB:On("ROSTER_CHANGED", "rosterpage:refresh2", function() if window:IsShown() then refreshAll() end end)

CBAB.SlashCommands.roster = function() CBAB.RosterPage:Toggle() end
