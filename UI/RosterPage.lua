local ADDON, CBAB = ...

-- The roster page (spec 7, 11.6). Redesigned per session feedback into
-- three stacked, independently N+1-auto-growing sections sharing one
-- underlying profile.roster array (spec 11.6, amended): every row list
-- shows its current entries plus exactly one blank row at the end to type
-- a new one into -- never a fixed row count, and never more than one
-- blank row at a time.
--
-- Sections:
--   1. Paladins  -- name, tank flag, optional spec hint, and an auto-filled
--      blessing Assign column the user can override (spec 5.5, amended).
--   2. Tanks     -- name, class, and 4 PreferredBuff slots auto-filled from
--      that class's want-list (Defaults.wants.tanks), overridable per tank.
--   3. Class headcounts -- a manual might/wisdom headcount table by class
--      and spec, feeding the Assign preview below before real numbers are
--      available from live raid data or addon comms.
--
-- A character who is both a paladin and a tank is simply ONE profile.roster
-- entry that appears as a row in both of the first two sections -- there is
-- no per-section duplicate storage. commitAll() below scans both sections'
-- widgets every edit and merges them back into one array by name, same
-- spirit as the old single-section "rebuild from scratch" approach, just
-- spanning two sections instead of one.
--
-- The Assign column's auto-fill is a PLANNING PREVIEW ONLY (see
-- assumedSlotOrder below) -- it assumes Kings is available once there are
-- 2+ paladins, since real capability isn't known until a paladin's own
-- client has scanned their talents (spec 6). It is never fed to the real
-- solver (Solver/Slots.lua + Solver/Assign.lua), which uses actual
-- capability. A red warning line appears only when the user's override
-- differs from that preview, not merely because one was set.
--
-- Class/spec are optional planning hints ONLY (spec 6, 7): live raid data
-- always overrides them, the solver never reads spec except as a cosmetic
-- tiebreak, and nobody should believe setting it configures anything.

CBAB.RosterPage = {}

local ROW_HEIGHT = 20
local HEADER_HEIGHT = 20
local COLHEAD_HEIGHT = 14
local SECTION_GAP = 14
local MAX_ROWS = 26 -- raid cap (25) + one blank row headroom
local CONTENT_WIDTH = 600
local SCROLLBAR_CLEARANCE = 46

-- ============================================================
-- Small shared helpers
-- ============================================================

local function blessingLabel(key)
	if not key then return "-" end
	local b = CBAB.Blessings[key]
	return b and b.name or key
end

local function classLabel(class)
	if not class then return "-" end
	local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	local displayName = class:sub(1, 1) .. class:sub(2):lower()
	if color and color.colorStr then
		return "|c" .. color.colorStr .. displayName .. "|r"
	end
	return displayName
end

-- Tallies a raid-wide physical/caster headcount from the manual
-- specCounts table (spec 5.4's classification, reused from
-- Solver/Assign.lua so this preview agrees with the real solver about
-- which spec wants which value).
local function tallyPhysicalCaster(specCounts)
	local physical, caster = 0, 0
	for _, class in ipairs(CBAB.ClassOrder) do
		local counts = (specCounts and specCounts[class]) or {}
		if CBAB.Solver.ALWAYS_PHYSICAL[class] then
			for _, n in pairs(counts) do physical = physical + (tonumber(n) or 0) end
		elseif CBAB.Solver.ALWAYS_CASTER[class] then
			for _, n in pairs(counts) do caster = caster + (tonumber(n) or 0) end
		else
			local specMap = CBAB.Solver.SPEC_VALUE[class]
			if specMap then
				for specKey, n in pairs(counts) do
					local value = specMap[specKey]
					n = tonumber(n) or 0
					if value == "might" then
						physical = physical + n
					elseif value == "wisdom" then
						caster = caster + n
					end
				end
			end
		end
	end
	return physical, caster
end

-- Assumed slot order for N paladins -- a planning-time PREVIEW mirroring
-- the reference count table in SPEC.md 5.3, not the real solver (see file
-- header). Ties favor Might, matching Solver/Slots.lua's own tie-break.
local function assumedSlotOrder(n, primary)
	local secondary = (primary == "might") and "wisdom" or "might"
	local order = { "salv" }
	if n >= 2 then order[#order + 1] = "kings" end
	if n >= 3 then order[#order + 1] = primary end
	if n >= 4 then order[#order + 1] = secondary end
	if n >= 5 then order[#order + 1] = "light" end
	return order
end

-- ============================================================
-- Window
-- ============================================================

local window = CreateFrame("Frame", "CBABuffRosterPage", UIParent)
window:SetSize(700, 760)
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

-- Forward-declared: bind functions created below close over these as
-- upvalues, but the real bodies aren't assigned until after every row/
-- section is built.
local commitAll, refreshAll

-- ============================================================
-- Profile switcher. A name box plus New/Rename/Delete/Switch buttons
-- acting on whatever's typed, each anchored to the PREVIOUS button's right
-- edge rather than at fixed offsets from the name box -- this is what
-- keeps Delete on-screen regardless of button label width, instead of the
-- earlier fixed-offset layout that ran past the window edge. A dropdown
-- (native UIDropDownMenuTemplate, not the banned LibUIDropDownMenu -- spec
-- 1) replaces the old N+1 row of clickable profile-name buttons.
-- ============================================================

local profileBar = CreateFrame("Frame", nil, window)
profileBar:SetPoint("TOPLEFT", 12, -36)
profileBar:SetPoint("TOPRIGHT", -12, -36)
profileBar:SetHeight(22)

local activeProfileText = profileBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
activeProfileText:SetPoint("LEFT", 0, 0)
activeProfileText:SetWidth(100)
activeProfileText:SetJustifyH("LEFT")

local profileNameBox = CreateFrame("EditBox", nil, profileBar, "InputBoxTemplate")
profileNameBox:SetSize(110, 20)
profileNameBox:SetPoint("LEFT", activeProfileText, "RIGHT", 4, 0)
profileNameBox:SetAutoFocus(false)

local function profileButton(label, anchorTo, xOffset, onClick)
	local btn = CreateFrame("Button", nil, profileBar, "UIPanelButtonTemplate")
	btn:SetSize(56, 20)
	btn:SetPoint("LEFT", anchorTo, "RIGHT", xOffset, 0)
	btn:SetText(label)
	btn:SetScript("OnClick", onClick)
	return btn
end

local switchButton = profileButton("Switch", profileNameBox, 6, function()
	local name = profileNameBox:GetText()
	local ok, err = CBAB.DB:SetActiveProfile(name)
	if not ok then CBAB:Print(err) end
	refreshAll()
end)
local newButton = profileButton("New", switchButton, 4, function()
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
local renameButton = profileButton("Rename", newButton, 4, function()
	local profile = CBAB.DB:Profile()
	local newName = profileNameBox:GetText()
	if not profile then CBAB:Print("no active profile") return end
	local ok, err = CBAB.DB:RenameProfile(profile.name, newName)
	if not ok then CBAB:Print(err) end
	refreshAll()
end)
profileButton("Delete", renameButton, 4, function()
	local name = profileNameBox:GetText()
	local ok, err = CBAB.DB:DeleteProfile(name)
	if not ok then CBAB:Print(err) end
	refreshAll()
end)

local profileDropdownLabel = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
profileDropdownLabel:SetPoint("TOPLEFT", profileBar, "BOTTOMLEFT", 0, -8)
profileDropdownLabel:SetText("Profiles:")

local profileDropdown = CreateFrame("Frame", "CBABuffRosterProfileDropdown", window, "UIDropDownMenuTemplate")
profileDropdown:SetPoint("LEFT", profileDropdownLabel, "RIGHT", -6, -2)
UIDropDownMenu_SetWidth(profileDropdown, 160)
UIDropDownMenu_Initialize(profileDropdown, function(self, level)
	local profile = CBAB.DB:Profile()
	local names = {}
	for name in pairs(CBAB.DB:Profiles()) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local info = UIDropDownMenu_CreateInfo()
		info.text = name
		info.checked = profile and profile.name == name
		info.func = function()
			local ok, err = CBAB.DB:SetActiveProfile(name)
			if not ok then CBAB:Print(err) end
			profileNameBox:SetText(name)
			refreshAll()
		end
		UIDropDownMenu_AddButton(info, level)
	end
end)

-- ============================================================
-- Scroll region holding all three sections
-- ============================================================

local scrollFrame = CreateFrame("ScrollFrame", "CBABuffRosterScroll", window, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", 12, -128)
scrollFrame:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -SCROLLBAR_CLEARANCE, 130)

local content = CreateFrame("Frame", nil, scrollFrame)
content:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
scrollFrame:SetScrollChild(content)

-- ============================================================
-- Section separators
-- ============================================================

local function createSeparator(iconTexture, iconCoords, titleText, titleColorHex)
	local sep = CreateFrame("Frame", nil, content)
	sep:SetSize(CONTENT_WIDTH, HEADER_HEIGHT)

	local titleX = 4
	if iconTexture then
		local icon = sep:CreateTexture(nil, "ARTWORK")
		icon:SetSize(16, 16)
		icon:SetPoint("LEFT", 4, 0)
		icon:SetTexture(iconTexture)
		if iconCoords then
			icon:SetTexCoord(iconCoords[1], iconCoords[2], iconCoords[3], iconCoords[4])
		end
		titleX = 26
	end

	local titleFS = sep:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	titleFS:SetPoint("LEFT", titleX, 0)
	titleFS:SetText(titleColorHex and ("|c" .. titleColorHex .. titleText .. "|r") or titleText)

	local line = sep:CreateTexture(nil, "ARTWORK")
	line:SetHeight(1)
	line:SetPoint("LEFT", titleFS, "RIGHT", 8, 0)
	line:SetPoint("RIGHT", sep, "RIGHT", -4, 0)
	line:SetColorTexture(1, 1, 1, 0.25)

	return sep
end

local function createColumnHeader(labels)
	local ch = CreateFrame("Frame", nil, content)
	ch:SetSize(CONTENT_WIDTH, COLHEAD_HEIGHT)
	for _, l in ipairs(labels) do
		local fs = ch:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("LEFT", l.x, 0)
		fs:SetWidth(l.width)
		fs:SetJustifyH("LEFT")
		fs:SetText(l.text)
	end
	return ch
end

local paladinColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS.PALADIN and RAID_CLASS_COLORS.PALADIN.colorStr
local paladinIconCoords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS.PALADIN

local paladinHeader = createSeparator(
	"Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes",
	paladinIconCoords,
	"Paladins",
	paladinColor
)
local paladinColHeader = createColumnHeader({
	{ text = "Name", x = 6, width = 120 },
	{ text = "Tank", x = 140, width = 40 },
	{ text = "Spec (optional)", x = 176, width = 90 },
	{ text = "Assign", x = 270, width = 90 },
})

-- Generic "shield" flavoring for the Tanks separator (spec: "prot warrior
-- shield style icon to differentiate") -- this labels the SECTION, not the
-- warrior class specifically; tanks of any class appear underneath it.
local tankHeader = createSeparator(
	"Interface\\Icons\\Ability_Warrior_ShieldWall",
	nil,
	"Tanks",
	nil
)
local tankColHeader = createColumnHeader({
	{ text = "Name", x = 6, width = 110 },
	{ text = "Class", x = 118, width = 70 },
	{ text = "Buff 1", x = 196, width = 54 },
	{ text = "Buff 2", x = 252, width = 54 },
	{ text = "Buff 3", x = 308, width = 54 },
	{ text = "Buff 4", x = 364, width = 54 },
})

-- Generic separator style, no icon (spec: "use generic style").
local classHeader = createSeparator(nil, nil, "Class Headcounts", nil)

-- ============================================================
-- Paladin rows
-- ============================================================

local palRows = {}

local function createPaladinRow(index)
	local row = CreateFrame("Frame", nil, content)
	row:SetSize(CONTENT_WIDTH, ROW_HEIGHT)

	row.nameBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.nameBox:SetSize(120, 18)
	row.nameBox:SetPoint("LEFT", 6, 0)
	row.nameBox:SetAutoFocus(false)

	row.tank = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	row.tank:SetSize(18, 18)
	row.tank:SetPoint("LEFT", row.nameBox, "RIGHT", 14, 0)

	row.specBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.specBox:SetSize(60, 14)
	row.specBox:SetPoint("LEFT", row.tank, "RIGHT", 14, 0)
	row.specBox:SetAutoFocus(false)
	row.specBox:SetFontObject(GameFontDisableSmall)

	row.assignDropdown = CreateFrame("Frame", "CBABuffRosterPalAssignDD" .. index, row, "UIDropDownMenuTemplate")
	row.assignDropdown:SetPoint("LEFT", row.specBox, "RIGHT", 2, -2)
	UIDropDownMenu_SetWidth(row.assignDropdown, 90)

	row.warningText = row:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
	row.warningText:SetPoint("LEFT", row.assignDropdown, "RIGHT", 6, 2)
	row.warningText:SetWidth(160)
	row.warningText:SetJustifyH("LEFT")

	row.deleteButton = CreateFrame("Button", nil, row, "UIPanelCloseButton")
	row.deleteButton:SetSize(16, 16)
	row.deleteButton:SetPoint("RIGHT", 0, 0)

	row.state = { assignOverride = nil }
	return row
end

local function bindPaladinRow(row)
	local function commit()
		commitAll()
		refreshAll()
	end

	row.nameBox:SetScript("OnEnterPressed", function(self) commit() self:ClearFocus() end)
	row.nameBox:SetScript("OnEditFocusLost", commit)
	row.specBox:SetScript("OnEditFocusLost", commit)
	row.tank:SetScript("OnClick", commit)

	UIDropDownMenu_Initialize(row.assignDropdown, function(self, level)
		local autoInfo = UIDropDownMenu_CreateInfo()
		autoInfo.text = "Auto"
		autoInfo.func = function()
			row.state.assignOverride = nil
			commit()
		end
		UIDropDownMenu_AddButton(autoInfo, level)

		for _, key in ipairs(CBAB.BlessingOrder) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = blessingLabel(key)
			info.func = function()
				row.state.assignOverride = key
				commit()
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end)

	row.deleteButton:SetScript("OnClick", function()
		row.nameBox:SetText("")
		row.tank:SetChecked(false)
		row.specBox:SetText("")
		row.state.assignOverride = nil
		commit()
	end)
end

local function getPaladinRow(index)
	local row = palRows[index]
	if not row then
		row = createPaladinRow(index)
		bindPaladinRow(row)
		palRows[index] = row
	end
	return row
end

-- ============================================================
-- Tank rows
-- ============================================================

local tankRows = {}

local function createTankRow(index)
	local row = CreateFrame("Frame", nil, content)
	row:SetSize(CONTENT_WIDTH, ROW_HEIGHT)

	row.nameBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.nameBox:SetSize(110, 18)
	row.nameBox:SetPoint("LEFT", 6, 0)
	row.nameBox:SetAutoFocus(false)

	row.classDropdown = CreateFrame("Frame", "CBABuffRosterTankClassDD" .. index, row, "UIDropDownMenuTemplate")
	row.classDropdown:SetPoint("LEFT", row.nameBox, "RIGHT", 4, -2)
	UIDropDownMenu_SetWidth(row.classDropdown, 70)

	row.buffDropdowns = {}
	local anchor = row.classDropdown
	for slot = 1, 4 do
		local dd = CreateFrame("Frame", ("CBABuffRosterTankBuffDD%d_%d"):format(index, slot), row, "UIDropDownMenuTemplate")
		-- UIDropDownMenuTemplate carries built-in left padding around its
		-- text -- the -8 tightens the visual gap between adjacent small
		-- dropdowns. May need a pixel tweak once seen in-game.
		dd:SetPoint("LEFT", anchor, "RIGHT", slot == 1 and 6 or -8, 0)
		UIDropDownMenu_SetWidth(dd, 50)
		row.buffDropdowns[slot] = dd
		anchor = dd
	end

	row.deleteButton = CreateFrame("Button", nil, row, "UIPanelCloseButton")
	row.deleteButton:SetSize(16, 16)
	row.deleteButton:SetPoint("RIGHT", 0, 0)

	row.state = { class = "WARRIOR", tankWantOverride = {} }
	return row
end

local function bindTankRow(row)
	local function commit()
		commitAll()
		refreshAll()
	end

	row.nameBox:SetScript("OnEnterPressed", function(self) commit() self:ClearFocus() end)
	row.nameBox:SetScript("OnEditFocusLost", commit)

	UIDropDownMenu_Initialize(row.classDropdown, function(self, level)
		for _, class in ipairs(CBAB.TankClasses) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = classLabel(class)
			info.func = function()
				row.state.class = class
				commit()
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end)

	for slot, dd in ipairs(row.buffDropdowns) do
		UIDropDownMenu_Initialize(dd, function(self, level)
			local noneInfo = UIDropDownMenu_CreateInfo()
			noneInfo.text = "-"
			noneInfo.func = function()
				row.state.tankWantOverride[slot] = false
				commit()
			end
			UIDropDownMenu_AddButton(noneInfo, level)

			for _, key in ipairs(CBAB.BlessingOrder) do
				local info = UIDropDownMenu_CreateInfo()
				info.text = blessingLabel(key)
				info.func = function()
					row.state.tankWantOverride[slot] = key
					commit()
				end
				UIDropDownMenu_AddButton(info, level)
			end
		end)
	end

	row.deleteButton:SetScript("OnClick", function()
		row.nameBox:SetText("")
		row.state = { class = "WARRIOR", tankWantOverride = {} }
		commit()
	end)
end

local function getTankRow(index)
	local row = tankRows[index]
	if not row then
		row = createTankRow(index)
		bindTankRow(row)
		tankRows[index] = row
	end
	return row
end

-- ============================================================
-- Class/spec headcount rows -- fixed one-per-class, never grows.
-- ============================================================

local classRows = {}

local function createClassRow(class)
	local row = CreateFrame("Frame", nil, content)
	row:SetSize(CONTENT_WIDTH, ROW_HEIGHT + 4)

	local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
	if coords then
		local icon = row:CreateTexture(nil, "ARTWORK")
		icon:SetSize(16, 16)
		icon:SetPoint("LEFT", 6, 0)
		icon:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
		icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
	end

	local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("LEFT", 26, 0)
	label:SetWidth(90)
	label:SetJustifyH("LEFT")
	label:SetText(classLabel(class))

	row.specBoxes = {}
	local anchor = label
	for i, spec in ipairs(CBAB.ClassSpecs[class]) do
		local specLabel = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		specLabel:SetPoint("LEFT", anchor, "RIGHT", i == 1 and 10 or 16, 0)
		specLabel:SetWidth(38)
		specLabel:SetJustifyH("LEFT")
		specLabel:SetText(spec.label)

		local box = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
		box:SetSize(30, 16)
		box:SetPoint("LEFT", specLabel, "RIGHT", 2, 0)
		box:SetAutoFocus(false)
		box:SetNumeric(true)

		local function commit()
			local profile = CBAB.DB:Profile()
			if not profile then return end
			profile.wants.specCounts = profile.wants.specCounts or {}
			profile.wants.specCounts[class] = profile.wants.specCounts[class] or {}
			local n = tonumber(box:GetText())
			profile.wants.specCounts[class][spec.key] = (n and n > 0) and n or nil
			profile.modified = time()
			refreshAll()
		end
		box:SetScript("OnEnterPressed", function(self) commit() self:ClearFocus() end)
		box:SetScript("OnEditFocusLost", commit)

		row.specBoxes[spec.key] = box
		anchor = box
	end

	return row
end

for _, class in ipairs(CBAB.ClassOrder) do
	classRows[class] = createClassRow(class)
end

-- ============================================================
-- Commit: scans both growing sections' CURRENT widget state and merges
-- them back into profile.roster by name, in one pass. See file header for
-- why a shared name (paladin who's also a tank) is never duplicated.
-- ============================================================

commitAll = function()
	local profile = CBAB.DB:Profile()
	if not profile then return end

	local paladinByName, paladinOrder = {}, {}
	for i = 1, #palRows do
		local row = palRows[i]
		if row:IsShown() then
			local name = row.nameBox:GetText()
			if name and name ~= "" then
				local spec = row.specBox:GetText()
				paladinByName[name] = {
					name = name,
					class = "PALADIN",
					tank = row.tank:GetChecked() and true or false,
					spec = spec ~= "" and spec:lower() or nil,
					assignOverride = row.state.assignOverride,
				}
				paladinOrder[#paladinOrder + 1] = name
			end
		end
	end

	local tankByName, tankOrder = {}, {}
	for i = 1, #tankRows do
		local row = tankRows[i]
		if row:IsShown() then
			local name = row.nameBox:GetText()
			if name and name ~= "" then
				-- Appended, not indexed by slot: a skipped ("-") slot must
				-- never leave a nil hole -- Assign.lua's walkWantList reads
				-- this with ipairs, which silently stops at the first nil
				-- (the same pitfall this codebase avoids elsewhere).
				local override
				for slot = 1, 4 do
					local v = row.state.tankWantOverride[slot]
					if v then
						override = override or {}
						override[#override + 1] = v
					end
				end
				tankByName[name] = { class = row.state.class, tankWantOverride = override }
				tankOrder[#tankOrder + 1] = name
			end
		end
	end

	local seen, newRoster = {}, {}

	for _, name in ipairs(paladinOrder) do
		local p = paladinByName[name]
		local t = tankByName[name]
		if t then
			p.tank = true
			p.tankWantOverride = t.tankWantOverride
		end
		newRoster[#newRoster + 1] = p
		seen[name] = true
	end

	for _, name in ipairs(tankOrder) do
		if not seen[name] then
			local t = tankByName[name]
			newRoster[#newRoster + 1] = {
				name = name,
				class = t.class,
				tank = true,
				tankWantOverride = t.tankWantOverride,
			}
			seen[name] = true
		end
	end

	-- Defensive only: preserves any entry neither section touched this
	-- pass. Shouldn't occur in practice -- every roster entry is a
	-- paladin, a tank, or both -- but a silent drop would be worse.
	for _, r in ipairs(profile.roster) do
		if not seen[r.name] then
			newRoster[#newRoster + 1] = r
			seen[r.name] = true
		end
	end

	profile.roster = newRoster
	profile.modified = time()
end

-- ============================================================
-- Export / Import
-- ============================================================

local ioScroll = CreateFrame("ScrollFrame", "CBABuffRosterIOScroll", window, "UIPanelScrollFrameTemplate")
ioScroll:SetPoint("BOTTOMLEFT", 12, 44)
ioScroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_CLEARANCE, 44)
ioScroll:SetHeight(70)

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
-- Refresh: lays out all three sections top-to-bottom with a running
-- cursor, since each one's row count changes independently every edit.
-- ============================================================

refreshAll = function()
	local profile = CBAB.DB:Profile()

	activeProfileText:SetText(profile and ("Active: " .. profile.name) or "No active profile")
	if profile and not profileNameBox:HasFocus() then
		profileNameBox:SetText(profile.name)
	end
	UIDropDownMenu_SetText(profileDropdown, profile and profile.name or "Select profile")

	if not profile then
		for _, row in pairs(palRows) do row:Hide() end
		for _, row in pairs(tankRows) do row:Hide() end
		content:SetHeight(1)
		return
	end

	local specCounts = profile.wants.specCounts or {}
	local physical, caster = tallyPhysicalCaster(specCounts)
	local primary = (caster > physical) and "wisdom" or "might"

	local y = 0

	-- Paladins ------------------------------------------------------
	local paladinEntries = {}
	for _, r in ipairs(profile.roster) do
		if r.class == "PALADIN" then
			paladinEntries[#paladinEntries + 1] = r
		end
	end
	local assumed = assumedSlotOrder(#paladinEntries, primary)
	local paladinDisplayCount = math.min(MAX_ROWS, #paladinEntries + 1)

	paladinHeader:ClearAllPoints()
	paladinHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
	y = y - HEADER_HEIGHT

	paladinColHeader:ClearAllPoints()
	paladinColHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
	y = y - COLHEAD_HEIGHT - 2

	for i = 1, paladinDisplayCount do
		local row = getPaladinRow(i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
		row:Show()

		local entry = paladinEntries[i]
		if entry then
			row.nameBox:SetText(entry.name or "")
			row.tank:SetChecked(entry.tank and true or false)
			row.specBox:SetText(entry.spec or "")
			row.state.assignOverride = entry.assignOverride
			row.deleteButton:Show()
		else
			row.nameBox:SetText("")
			row.tank:SetChecked(false)
			row.specBox:SetText("")
			row.state.assignOverride = nil
			row.deleteButton:Hide()
		end

		local assumedBlessing = assumed[i]
		local effective = row.state.assignOverride or assumedBlessing
		UIDropDownMenu_SetText(row.assignDropdown, blessingLabel(effective))

		if row.state.assignOverride and row.state.assignOverride ~= assumedBlessing then
			row.warningText:SetText(("overridden -- assumed %s"):format(blessingLabel(assumedBlessing)))
			row.warningText:Show()
		else
			row.warningText:Hide()
		end

		y = y - ROW_HEIGHT
	end
	for i = paladinDisplayCount + 1, #palRows do
		palRows[i]:Hide()
	end

	y = y - SECTION_GAP

	-- Tanks -----------------------------------------------------------
	local tankEntries = {}
	for _, r in ipairs(profile.roster) do
		if r.tank then
			tankEntries[#tankEntries + 1] = r
		end
	end
	local tankDisplayCount = math.min(MAX_ROWS, #tankEntries + 1)

	tankHeader:ClearAllPoints()
	tankHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
	y = y - HEADER_HEIGHT

	tankColHeader:ClearAllPoints()
	tankColHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
	y = y - COLHEAD_HEIGHT - 2

	for i = 1, tankDisplayCount do
		local row = getTankRow(i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
		row:Show()

		local entry = tankEntries[i]
		if entry then
			row.nameBox:SetText(entry.name or "")
			row.state.class = entry.class or "WARRIOR"
			row.state.tankWantOverride = entry.tankWantOverride or {}
			row.deleteButton:Show()
		else
			row.nameBox:SetText("")
			row.state.class = "WARRIOR"
			row.state.tankWantOverride = {}
			row.deleteButton:Hide()
		end

		UIDropDownMenu_SetText(row.classDropdown, classLabel(row.state.class))

		local defaultWants = (profile.wants.tanks and profile.wants.tanks[row.state.class]) or {}
		for slot, dd in ipairs(row.buffDropdowns) do
			local value = row.state.tankWantOverride[slot]
			if value == nil then
				value = defaultWants[slot]
			end
			UIDropDownMenu_SetText(dd, value and blessingLabel(value) or "-")
		end

		y = y - ROW_HEIGHT
	end
	for i = tankDisplayCount + 1, #tankRows do
		tankRows[i]:Hide()
	end

	y = y - SECTION_GAP

	-- Class headcounts --------------------------------------------------
	classHeader:ClearAllPoints()
	classHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
	y = y - HEADER_HEIGHT

	for _, class in ipairs(CBAB.ClassOrder) do
		local row = classRows[class]
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
		local counts = specCounts[class] or {}
		for _, spec in ipairs(CBAB.ClassSpecs[class]) do
			local box = row.specBoxes[spec.key]
			if not box:HasFocus() then
				box:SetText(counts[spec.key] and tostring(counts[spec.key]) or "")
			end
		end
		y = y - (ROW_HEIGHT + 4)
	end

	content:SetHeight(math.max(1, -y))
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
