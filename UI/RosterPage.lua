local ADDON, CBAB = ...

-- The roster page (spec 7, 11.6): 25 slots, name entry, tank flags, an
-- optional plannedGroup pin, a profile switcher, and export/import.
--
-- All 25 rows are always shown (matching spec's literal "25 slots"
-- language, and avoiding the surprise of a row silently appearing after
-- pressing Enter). Every field edit rebuilds profile.roster FROM SCRATCH
-- by scanning all 25 rows' current widget state and keeping only the ones
-- with a non-empty name, in visual order. This matters beyond just this
-- file: several places in the codebase (e.g. Solve.lua's roster walk)
-- iterate profile.roster with ipairs, which silently stops at the first
-- nil -- rebuilding fresh from a full scan every time means there is no
-- index-mapping logic that could ever leave a gap in the middle.
--
-- Class/spec are optional planning hints ONLY (spec 6, 7): live raid data
-- always overrides them, the solver never reads spec except as a cosmetic
-- tiebreak, and nobody should believe setting it configures anything. Both
-- fields are deliberately small and dim compared to name/tank, and labelled
-- as hints in the column header so that's not left to guesswork.

CBAB.RosterPage = {}

local ROW_HEIGHT = 20
local MAX_DISPLAY_ROWS = 25

-- ============================================================
-- Window
-- ============================================================

local window = CreateFrame("Frame", "CBABuffRosterPage", UIParent)
window:SetSize(560, 520)
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

local function refreshAll() end -- forward-declared, assigned near the bottom

-- ============================================================
-- Profile switcher. No UIDropDownMenu (avoids that template's boilerplate
-- for a case this simple): a name box plus New/Rename/Delete/Switch
-- buttons acting on whatever's typed, PLUS a clickable list of existing
-- profiles -- clicking one switches to it immediately and loads its name
-- into the box, so "which profile am I on" is never just a small text
-- label you can miss, and "New" only ever fires against a name you
-- deliberately typed over the current one.
-- ============================================================

local profileBar = CreateFrame("Frame", nil, window)
profileBar:SetPoint("TOPLEFT", 12, -36)
profileBar:SetPoint("TOPRIGHT", -12, -36)
profileBar:SetHeight(22)

local activeProfileText = profileBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
activeProfileText:SetPoint("LEFT", 0, 0)
activeProfileText:SetWidth(150)
activeProfileText:SetJustifyH("LEFT")

local profileNameBox = CreateFrame("EditBox", nil, profileBar, "InputBoxTemplate")
profileNameBox:SetSize(120, 20)
profileNameBox:SetPoint("LEFT", 156, 0)
profileNameBox:SetAutoFocus(false)

local function profileButton(label, xOffset, onClick)
	local btn = CreateFrame("Button", nil, profileBar, "UIPanelButtonTemplate")
	btn:SetSize(60, 20)
	btn:SetPoint("LEFT", profileNameBox, "RIGHT", xOffset, 0)
	btn:SetText(label)
	btn:SetScript("OnClick", onClick)
	return btn
end

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
		CBAB:Print(("created and switched to a new, empty profile '%s' -- your other profiles are untouched, switch back any time"):format(name))
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

-- Clickable profile list: one button per saved profile, reused across
-- refreshes. Clicking switches to it AND loads its name into the box.
local profileListButtons = {}

local function getProfileListButton(index)
	local btn = profileListButtons[index]
	if not btn then
		btn = CreateFrame("Button", nil, profileBar, "UIPanelButtonTemplate")
		btn:SetHeight(18)
		profileListButtons[index] = btn
	end
	return btn
end

-- ============================================================
-- Column header (spec 11.6: class/spec are hints, visually secondary --
-- labelled here so nobody has to guess what an unlabelled box is for).
-- ============================================================

local header = CreateFrame("Frame", nil, window)
header:SetPoint("TOPLEFT", 12, -84)
header:SetPoint("TOPRIGHT", -46, -84)
header:SetHeight(14)

local function headerLabel(text, anchorPoint, xOffset, width)
	local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("LEFT", anchorPoint, xOffset, 0)
	fs:SetWidth(width)
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
	return fs
end

local headerName = headerLabel("Name", header, 24, 140)
local headerTank = headerLabel("Tank", headerName, 148, 30)
local headerClass = headerLabel("Class (hint)", headerTank, 30, 70)
local headerSpec = headerLabel("Spec (hint)", headerClass, 74, 70)
local headerGroup = headerLabel("Grp", headerSpec, 74, 40)

-- ============================================================
-- Roster rows: name, tank flag, class hint, spec hint, plannedGroup,
-- delete. Always all 25, never a dynamically-growing N+1.
-- ============================================================

-- Scrollbar clearance: this client has repeatedly not matched the legacy
-- template assumptions the rest of this addon was written against, so
-- rather than fine-tune an exact pixel offset for UIPanelScrollFrameTemplate's
-- scrollbar, this reserves generous margin instead of a tight one.
local SCROLLBAR_CLEARANCE = 46

local scrollFrame = CreateFrame("ScrollFrame", "CBABuffRosterScroll", window, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
scrollFrame:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -SCROLLBAR_CLEARANCE, 130)

local content = CreateFrame("Frame", nil, scrollFrame)
content:SetSize(420, MAX_DISPLAY_ROWS * ROW_HEIGHT)
scrollFrame:SetScrollChild(content)

local rows = {}

-- Rebuilds profile.roster from scratch by scanning every row's CURRENT
-- widget state, keeping only rows with a non-empty name, in visual order.
-- Called after every field edit -- see file header for why this replaced
-- the earlier per-index read/write approach.
local function commitAllRows()
	local profile = CBAB.DB:Profile()
	if not profile then return end

	local newRoster = {}
	for i = 1, MAX_DISPLAY_ROWS do
		local row = rows[i]
		if row then
			local name = row.nameBox:GetText()
			if name and name ~= "" then
				local classText = row.classBox:GetText()
				local specText = row.specBox:GetText()
				local plannedNum = tonumber(row.plannedGroupBox:GetText())
				newRoster[#newRoster + 1] = {
					name = name,
					tank = row.tank:GetChecked() and true or false,
					class = classText ~= "" and classText:upper() or nil,
					spec = specText ~= "" and specText:lower() or nil,
					plannedGroup = (plannedNum == 1 or plannedNum == 2) and plannedNum or nil,
				}
			end
		end
	end
	profile.roster = newRoster
	profile.modified = time()
end

local function createRow(index)
	local row = CreateFrame("Frame", nil, content)
	row:SetSize(420, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

	row.indexText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.indexText:SetPoint("LEFT", 0, 0)
	row.indexText:SetWidth(20)
	row.indexText:SetText(tostring(index))

	row.nameBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.nameBox:SetSize(130, 18)
	row.nameBox:SetPoint("LEFT", 24, 0)
	row.nameBox:SetAutoFocus(false)

	row.tank = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	row.tank:SetSize(18, 18)
	row.tank:SetPoint("LEFT", row.nameBox, "RIGHT", 18, 0)

	row.classBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.classBox:SetSize(70, 14)
	row.classBox:SetPoint("LEFT", row.tank, "RIGHT", 20, 0)
	row.classBox:SetAutoFocus(false)
	row.classBox:SetFontObject(GameFontDisableSmall)

	row.specBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.specBox:SetSize(70, 14)
	row.specBox:SetPoint("LEFT", row.classBox, "RIGHT", 4, 0)
	row.specBox:SetAutoFocus(false)
	row.specBox:SetFontObject(GameFontDisableSmall)

	row.plannedGroupBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.plannedGroupBox:SetSize(24, 14)
	row.plannedGroupBox:SetPoint("LEFT", row.specBox, "RIGHT", 10, 0)
	row.plannedGroupBox:SetAutoFocus(false)
	row.plannedGroupBox:SetNumeric(true)

	row.deleteButton = CreateFrame("Button", nil, row, "UIPanelCloseButton")
	row.deleteButton:SetSize(16, 16)
	row.deleteButton:SetPoint("LEFT", row.plannedGroupBox, "RIGHT", 6, 0)

	return row
end

local function bindRow(row)
	local function commitAndRefresh()
		commitAllRows()
		refreshAll()
	end

	row.nameBox:SetScript("OnEnterPressed", function(self)
		commitAndRefresh()
		self:ClearFocus()
	end)
	row.nameBox:SetScript("OnEditFocusLost", commitAndRefresh)
	row.classBox:SetScript("OnEditFocusLost", commitAndRefresh)
	row.specBox:SetScript("OnEditFocusLost", commitAndRefresh)
	row.plannedGroupBox:SetScript("OnEditFocusLost", commitAndRefresh)
	row.tank:SetScript("OnClick", commitAndRefresh)

	row.deleteButton:SetScript("OnClick", function()
		row.nameBox:SetText("")
		row.classBox:SetText("")
		row.specBox:SetText("")
		row.plannedGroupBox:SetText("")
		row.tank:SetChecked(false)
		commitAndRefresh()
	end)
end

local function getRow(index)
	local row = rows[index]
	if not row then
		row = createRow(index)
		bindRow(row)
		rows[index] = row
	end
	return row
end

-- ============================================================
-- Export / Import
-- ============================================================

local ioScroll = CreateFrame("ScrollFrame", "CBABuffRosterIOScroll", window, "UIPanelScrollFrameTemplate")
ioScroll:SetPoint("BOTTOMLEFT", 12, 44)
ioScroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_CLEARANCE, 44)
ioScroll:SetHeight(70)

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

	-- Keep the name box tracking the active profile whenever it isn't
	-- currently focused, so "New"/"Rename"/"Delete" act on the profile
	-- you're actually looking at unless you've deliberately typed
	-- something else over it.
	if profile and not profileNameBox:HasFocus() then
		profileNameBox:SetText(profile.name)
	end

	local names = {}
	for name in pairs(CBAB.DB:Profiles()) do
		names[#names + 1] = name
	end
	table.sort(names)

	for i, name in ipairs(names) do
		local btn = getProfileListButton(i)
		btn:SetText(name == (profile and profile.name) and ("* " .. name) or name)
		btn:SetWidth(math.max(70, btn:GetFontString():GetStringWidth() + 16))
		btn:ClearAllPoints()
		if i == 1 then
			btn:SetPoint("TOPLEFT", profileBar, "TOPLEFT", 0, -22)
		else
			btn:SetPoint("LEFT", profileListButtons[i - 1], "RIGHT", 4, 0)
		end
		btn:SetScript("OnClick", function()
			local ok, err = CBAB.DB:SetActiveProfile(name)
			if not ok then CBAB:Print(err) end
			profileNameBox:SetText(name)
			refreshAll()
		end)
		btn:Show()
	end
	for i = #names + 1, #profileListButtons do
		profileListButtons[i]:Hide()
	end

	for i = 1, MAX_DISPLAY_ROWS do
		local row = getRow(i)
		local e = profile and profile.roster[i]
		if e then
			row.nameBox:SetText(e.name or "")
			row.classBox:SetText(e.class or "")
			row.specBox:SetText(e.spec or "")
			row.plannedGroupBox:SetText(e.plannedGroup and tostring(e.plannedGroup) or "")
			row.tank:SetChecked(e.tank and true or false)
		else
			row.nameBox:SetText("")
			row.classBox:SetText("")
			row.specBox:SetText("")
			row.plannedGroupBox:SetText("")
			row.tank:SetChecked(false)
		end
	end
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
