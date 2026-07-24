local ADDON, CBAB = ...
local Theme = CBAB.Theme

-- The roster window (spec 7, 11.6). Visually reskinned per the design
-- handoff (UI/redesign/design_handoff_cba_buff/README.md, "2. Roster
-- window") on top of UI/Theme.lua, the same shared design system UI/Bar.lua
-- already builds on -- this file's own business logic (profile CRUD, the
-- three growing sections, the planned-assignment preview, export/import) is
-- unchanged from the pre-redesign version; only frame creation/styling and
-- the top-level layout moved. Two structural changes from the handoff:
--   - The profile toolbar consolidates the old name-box+Switch button into
--     the dropdown alone (selecting an entry already switches); the name
--     box now only feeds New/Rename, which need freeform text the dropdown
--     can't provide.
--   - The former in-scroll "Assignments" section (Solve/Push/Sync/Report +
--     the resolved/warning text) is now the handoff's fixed right-hand
--     Solve rail, sharing this file's buildPlannedAssignment/doSolvePlan
--     with the paladin/tank tables' own scroll area -- this is what fixes
--     the pre-redesign double-scrollbar (tables and rail no longer share
--     one scroll region).
-- Class Headcounts (manual per-class/spec want-count input, used only to
-- seed the planning preview before real capability/spec data exists -- see
-- assumedSlotOrder below) has no equivalent in the reference design, which
-- shows plain read-only headcount chips. Both survive here: the editable
-- input section stays in the main scroll (it's a data-entry tool, not a
-- summary), and the rail additionally renders the same data as read-only
-- class-colored chips per the handoff, purely as a summary.
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

-- ============================================================
-- Layout constants (design handoff README.md, "2. Roster window").
-- ============================================================

local WINDOW_WIDTH = 1040
local WINDOW_HEIGHT = 720
local RAIL_WIDTH = 300

local ROW_HEIGHT = 22
local HEADER_HEIGHT = 22
local COLHEAD_HEIGHT = 16
local SECTION_GAP = 14
local MAX_ROWS = 26 -- raid cap (25) + one blank row headroom
local CONTENT_WIDTH = 660
local DELETE_SIZE = 22 -- red X delete button, sits right after each name
-- A UIDropDownMenuTemplate's visible text starts ~this far right of the
-- frame's own left edge (the template's left-cap texture). Column headers
-- for dropdown columns are offset by this so the label sits over the text.
local DD_TEXT_INSET = 18

-- Paladin row x-layout. Assign/Aura each get a small color-coded dot placed
-- just before the dropdown, sized to leave a 4px gap on both sides, so "the
-- color system reads even at a glance" (README, Icons) without having to
-- retexture the native dropdown chrome itself (see file header, Fidelity).
local PAL_NAME_X = 6
local PAL_TANK_X = 150
local PAL_SPEC_X = 182
local PAL_ASSIGN_DOT_X = 244
local PAL_ASSIGN_X = 254
local PAL_ASSIGN_WIDTH = 90
local PAL_AURA_DOT_X = PAL_ASSIGN_X + PAL_ASSIGN_WIDTH + 4
local PAL_AURA_X = PAL_AURA_DOT_X + 10
local PAL_AURA_WIDTH = 70

-- Tank row x-layout: same color-dot treatment for the class column and
-- each of the four buff-priority columns.
local TANK_CLASS_DOT_X = 140
local TANK_CLASS_DD_X = 150
local TANK_CLASS_DD_WIDTH = 60
local TANK_BUFF_DOT_X = { 224, 294, 364, 434 }
local TANK_BUFF_DD_X = { 234, 304, 374, 444 }
local TANK_BUFF_DD_WIDTH = 50

-- ============================================================
-- Small shared helpers
-- ============================================================

local function blessingLabel(key)
	if not key then return "-" end
	local b = CBAB.Blessings[key]
	return b and b.name or key
end

local function auraLabel(key)
	if not key then return "-" end
	local a = CBAB.Auras[key]
	return a and a.name or key
end

-- 6-hex (no '#', no alpha) class color, for Theme.Hex/Theme.CreateDot --
-- RAID_CLASS_COLORS.colorStr is 8 hex (AARRGGBB), so the leading alpha
-- pair is stripped.
local function classHex(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c and c.colorStr then return c.colorStr:sub(3) end
	return (Theme.Colors.textSecondary):gsub("#", "")
end

local function classLabel(class)
	if not class then return "-" end
	local displayName = class:sub(1, 1) .. class:sub(2):lower()
	return "|cff" .. classHex(class) .. displayName .. "|r"
end

local CLASS_ABBR = {
	WARRIOR = "WAR", ROGUE = "ROG", PRIEST = "PRI", DRUID = "DRU", PALADIN = "PAL",
	HUNTER = "HUN", MAGE = "MAG", WARLOCK = "WLK", SHAMAN = "SHM",
}

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
-- Window chrome: same fill/hairline/shadow recipe as UI/Bar.lua, sized to
-- the handoff's ~1040px roster width. Only the title bar is a drag handle
-- now (README: whole-window drag was a pbar-only allowance).
-- ============================================================

local window = CreateFrame("Frame", "CBABuffRosterPage", UIParent)
window:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
window:SetPoint("CENTER")
window:SetMovable(true)
window:EnableMouse(true)
window:SetClampedToScreen(true)
CBAB:ApplyBackdrop(window, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
Theme.ApplyFill(window, Theme.Colors.windowFillTop, Theme.Colors.windowFillBottom, 1)
window:SetBackdropBorderColor(Theme.Hex(Theme.Colors.borderSubtle))
Theme.ApplyDropShadow(window, { pad = 16, yOffset = 10, alpha = 0.55 })
Theme.ApplyTopHairline(window, Theme.Colors.gold)
window:Hide()

-- Forward-declared: bind functions created below close over these as
-- upvalues, but the real bodies aren't assigned until after every row/
-- section is built.
local commitAll, refreshAll, doSolvePlan, ioBox

local titleBar = CreateFrame("Frame", nil, window)
titleBar:SetPoint("TOPLEFT", 0, 0)
titleBar:SetPoint("TOPRIGHT", 0, 0)
titleBar:SetHeight(40)
titleBar:EnableMouse(true)
titleBar:RegisterForDrag("LeftButton")
titleBar:SetScript("OnDragStart", function() window:StartMoving() end)
titleBar:SetScript("OnDragStop", function() window:StopMovingOrSizing() end)

local brandChip = CreateFrame("Frame", nil, titleBar)
brandChip:SetSize(20, 20)
brandChip:SetPoint("LEFT", 14, 0)
Theme.ApplyFill(brandChip, Theme.Colors.gold, Theme.Colors.goldDark, 0)

local titleText = titleBar:CreateFontString(nil, "OVERLAY")
Theme.StyleText(titleText, "Title", { color = "textPrimary", spacing = 2 })
titleText:SetPoint("LEFT", brandChip, "RIGHT", 10, 0)
titleText:SetText(("CBA BUFF"))

local subtitleText = titleBar:CreateFontString(nil, "OVERLAY")
Theme.StyleText(subtitleText, "Subtitle", { color = "textSecondary" })
subtitleText:SetPoint("LEFT", titleText, "RIGHT", 8, 0)
subtitleText:SetText("Roster")

local closeButton = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -6, -6)
closeButton:SetScript("OnClick", function() window:Hide() end)

-- ============================================================
-- Profile toolbar (README: "one row"): PROFILE label + selector dropdown +
-- New/Rename/Delete acting on the typed name, then (right-anchored, so the
-- gap between the two clusters reads as the handoff's spacer) the Pets
-- toggle, Open pbar, a divider, and Export/Import. The old separate
-- "Switch" button is gone -- picking an entry from the dropdown already
-- calls SetActiveProfile; the name box now exists only to type a NEW name
-- for New/Rename, which the dropdown can't provide.
-- ============================================================

local toolbar = CreateFrame("Frame", nil, window)
toolbar:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 14, -10)
toolbar:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -14, -10)
toolbar:SetHeight(24)

local profileLabel = toolbar:CreateFontString(nil, "OVERLAY")
Theme.StyleText(profileLabel, "ColumnLabel", { color = "textFaint" })
profileLabel:SetPoint("LEFT", 0, 0)
profileLabel:SetText("PROFILE")

-- Native UIDropDownMenuTemplate chrome is left un-retextured (same posture
-- as UI/Bar.lua's gridEditDropdown) -- the handoff's "selector pill" look
-- doesn't have a cheap backdrop-based equivalent for a menu that also needs
-- Blizzard's own click-open-highlight behavior.
local profileDropdown = CreateFrame("Frame", "CBABuffRosterProfileDropdown", toolbar, "UIDropDownMenuTemplate")
profileDropdown:SetPoint("LEFT", profileLabel, "RIGHT", -2, -2)
UIDropDownMenu_SetWidth(profileDropdown, 140)

local profileNameBox = CreateFrame("EditBox", nil, toolbar, "InputBoxTemplate")
profileNameBox:SetSize(110, 20)
profileNameBox:SetPoint("LEFT", profileDropdown, "RIGHT", 4, 2)
profileNameBox:SetAutoFocus(false)

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

local newButton = Theme.CreateButton(toolbar, {
	text = "New", width = 48, height = 20,
	onClick = function()
		local name = profileNameBox:GetText()
		local ok, err = CBAB.DB:CreateProfile(name)
		if ok then
			CBAB.DB:SetActiveProfile(name)
			CBAB:Print(("created and switched to a new, empty profile '%s' -- your other profiles are untouched, switch back any time"):format(name))
		else
			CBAB:Print(err)
		end
		refreshAll()
	end,
})
newButton:SetPoint("LEFT", profileNameBox, "RIGHT", 8, 0)

local renameButton = Theme.CreateButton(toolbar, {
	text = "Rename", width = 58, height = 20,
	onClick = function()
		local profile = CBAB.DB:Profile()
		local newName = profileNameBox:GetText()
		if not profile then CBAB:Print("no active profile") return end
		local ok, err = CBAB.DB:RenameProfile(profile.name, newName)
		if not ok then CBAB:Print(err) end
		refreshAll()
	end,
})
renameButton:SetPoint("LEFT", newButton, "RIGHT", 4, 0)

local deleteButton = Theme.CreateButton(toolbar, {
	text = "Delete", width = 54, height = 20, variant = "outline-red",
	onClick = function()
		local name = profileNameBox:GetText()
		local ok, err = CBAB.DB:DeleteProfile(name)
		if not ok then CBAB:Print(err) end
		refreshAll()
	end,
})
deleteButton:SetPoint("LEFT", renameButton, "RIGHT", 4, 0)

-- Right-anchored cluster, built right-to-left so the gap between it and the
-- left cluster above is whatever's left -- the handoff's "spacer".
local importButton = Theme.CreateButton(toolbar, {
	text = "Import", width = 60, height = 20,
	onClick = function()
		local text = ioBox:GetText()
		local ok, err = CBAB.DB:Import(text)
		if ok then
			CBAB:Print("import succeeded")
		else
			CBAB:Print("import failed: " .. tostring(err))
		end
		refreshAll()
	end,
})
importButton:SetPoint("RIGHT", 0, 0)

local exportButton = Theme.CreateButton(toolbar, {
	text = "Export", width = 60, height = 20,
	onClick = function()
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
	end,
})
exportButton:SetPoint("RIGHT", importButton, "LEFT", -6, 0)

local toolbarDivider = toolbar:CreateTexture(nil, "ARTWORK")
toolbarDivider:SetSize(1, 20)
toolbarDivider:SetColorTexture(Theme.Hex(Theme.Colors.divider))
toolbarDivider:SetPoint("RIGHT", exportButton, "LEFT", -10, 0)

local openPbarButton = Theme.CreateButton(toolbar, {
	text = "Open pbar", width = 82, height = 20, variant = "outline-gold",
	onClick = function()
		if CBAB.Bar_SetShown then CBAB.Bar_SetShown(true) end
	end,
})
openPbarButton:SetPoint("RIGHT", toolbarDivider, "LEFT", -10, 0)

local petsLabel = toolbar:CreateFontString(nil, "OVERLAY")
Theme.StyleText(petsLabel, "Body", { color = "textSecondary" })
petsLabel:SetText("Pets in pbar")
petsLabel:SetPoint("RIGHT", openPbarButton, "LEFT", -8, 0)

local petsToggle = Theme.CreateToggle(toolbar, {
	onClick = function(self, checked)
		local profile = CBAB.DB:Profile()
		if profile and profile.wants then
			profile.wants.petsEnabled = checked
			profile.modified = time()
			CBAB:Fire("ASSIGNMENT_CHANGED")
		end
	end,
})
petsToggle:SetPoint("RIGHT", petsLabel, "LEFT", -8, 0)

-- ============================================================
-- Body: main scroll (Paladins/Tanks tables + Class Headcounts input, left)
-- and the fixed Solve rail (right). Two independent regions instead of one
-- shared scroll area -- this is the fix for the pre-redesign double-
-- scrollbar (README: "Fixes the old double-scrollbar").
-- ============================================================

local FOOTER_CLEARANCE = 100 -- leaves room for the Export/Import string box below

local rail = CreateFrame("Frame", nil, window)
rail:SetWidth(RAIL_WIDTH)
rail:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -14)
rail:SetPoint("BOTTOM", window, "BOTTOM", 0, FOOTER_CLEARANCE)
CBAB:ApplyBackdrop(rail, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
rail:SetBackdropColor(Theme.HexA("000000", 0.18))
rail:SetBackdropBorderColor(Theme.Hex(Theme.Colors.borderSubtle))

local scrollFrame = CreateFrame("ScrollFrame", "CBABuffRosterScroll", window, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -14)
scrollFrame:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 14, FOOTER_CLEARANCE)
scrollFrame:SetPoint("RIGHT", rail, "LEFT", -14, 0)

local content = CreateFrame("Frame", nil, scrollFrame)
content:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
scrollFrame:SetScrollChild(content)

-- ============================================================
-- Section separators (main scroll)
-- ============================================================

local function createSeparator(iconTexture, iconCoords, titleLabel, titleClass)
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

	local titleFS = sep:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(titleFS, "SectionHeader", { spacing = 1.5 })
	titleFS:SetPoint("LEFT", titleX, 0)
	-- Manual :upper() here rather than Theme.StyleText's opts.upper wrapper:
	-- a class-colored header embeds a "|cffRRGGBB...|r" escape, and WoW's
	-- escape parser is case-sensitive -- the wrapper's blanket :upper() would
	-- turn "|c"/"|r" into unrecognized "|C"/"|R" and break the color code.
	local displayText = titleLabel:upper()
	if titleClass then
		titleFS:SetText("|cff" .. classHex(titleClass) .. displayText .. "|r")
	else
		titleFS:SetText(displayText)
		titleFS:SetTextColor(Theme.C("textPrimary"))
	end

	local line = sep:CreateTexture(nil, "ARTWORK")
	line:SetHeight(1)
	line:SetPoint("LEFT", titleFS, "RIGHT", 8, 0)
	line:SetPoint("RIGHT", sep, "RIGHT", -4, 0)
	line:SetColorTexture(Theme.HexA(Theme.Colors.divider, 0.7))

	return sep
end

local function createColumnHeader(labels)
	local ch = CreateFrame("Frame", nil, content)
	ch:SetSize(CONTENT_WIDTH, COLHEAD_HEIGHT)
	for _, l in ipairs(labels) do
		local fs = ch:CreateFontString(nil, "OVERLAY")
		Theme.StyleText(fs, "ColumnLabel", { color = "textFaint", spacing = 1 })
		fs:SetPoint("LEFT", l.x, 0)
		fs:SetWidth(l.width)
		fs:SetJustifyH("LEFT")
		fs:SetText(l.text:upper())
	end
	return ch
end

local paladinIconCoords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS.PALADIN

local paladinHeader = createSeparator(
	"Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes",
	paladinIconCoords,
	"Paladins",
	"PALADIN"
)
local paladinColHeader = createColumnHeader({
	{ text = "Name", x = PAL_NAME_X, width = 110 },
	{ text = "Tank", x = PAL_TANK_X, width = 34 },
	{ text = "Spec (opt.)", x = PAL_SPEC_X, width = 62 },
	{ text = "Assign", x = PAL_ASSIGN_X + DD_TEXT_INSET, width = 90 },
	-- Aura is manual-only (no solver slot construction, see SPEC.md's v1
	-- aura scope note) -- this column has no "assumed" auto-fill or
	-- override-warning the way Assign does, it's just a direct pick.
	{ text = "Aura", x = PAL_AURA_X + DD_TEXT_INSET, width = 70 },
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
	{ text = "Name", x = 6, width = 100 },
	{ text = "Class", x = TANK_CLASS_DD_X + DD_TEXT_INSET, width = 60 },
	{ text = "Buff 1", x = TANK_BUFF_DD_X[1] + DD_TEXT_INSET, width = 50 },
	{ text = "Buff 2", x = TANK_BUFF_DD_X[2] + DD_TEXT_INSET, width = 50 },
	{ text = "Buff 3", x = TANK_BUFF_DD_X[3] + DD_TEXT_INSET, width = 50 },
	{ text = "Buff 4", x = TANK_BUFF_DD_X[4] + DD_TEXT_INSET, width = 50 },
})

-- Generic separator style, no icon/class-color (spec: "use generic style").
local classHeader = createSeparator(nil, nil, "Class Headcounts", nil)

-- ============================================================
-- Paladin rows
-- ============================================================

local palRows = {}

-- Every row gets a faint card backdrop (README "Elevated row fill") plus a
-- hover highlight -- shared by paladin/tank rows since both use the same
-- card look.
local function applyRowCard(row)
	CBAB:ApplyBackdrop(row, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	row:SetBackdropColor(Theme.HexA("ffffff", 0.013))
	row:SetBackdropBorderColor(Theme.Hex(Theme.Colors.borderSubtle))
	row:EnableMouse(true)
	Theme.ApplyHoverHighlight(row, { hoverAlpha = 0.05, pressAlpha = 0.02 })
end

local function createPaladinRow(index)
	local row = CreateFrame("Frame", nil, content)
	row:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
	applyRowCard(row)

	row.nameBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.nameBox:SetSize(110, 18)
	row.nameBox:SetPoint("LEFT", PAL_NAME_X, 0)
	row.nameBox:SetAutoFocus(false)
	-- Paladin name (README type scale: "Name (class-colored)").
	row.nameBox:SetTextColor(Theme.HexA(classHex("PALADIN"), 1))

	-- Delete X sits right after the name (per request), and is bigger.
	row.deleteButton = CreateFrame("Button", nil, row, "UIPanelCloseButton")
	row.deleteButton:SetSize(DELETE_SIZE, DELETE_SIZE)
	row.deleteButton:SetPoint("LEFT", row.nameBox, "RIGHT", 2, 0)

	row.tank = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	row.tank:SetSize(18, 18)
	row.tank:SetPoint("LEFT", PAL_TANK_X, 0)

	row.specBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.specBox:SetSize(58, 14)
	row.specBox:SetPoint("LEFT", PAL_SPEC_X, 0)
	row.specBox:SetAutoFocus(false)
	row.specBox:SetFontObject(GameFontDisableSmall)

	row.assignDot = Theme.CreateDot(row, Theme.Colors.dashedEmpty, 6)
	row.assignDot:SetPoint("LEFT", PAL_ASSIGN_DOT_X, 0)

	row.assignDropdown = CreateFrame("Frame", "CBABuffRosterPalAssignDD" .. index, row, "UIDropDownMenuTemplate")
	row.assignDropdown:SetPoint("LEFT", PAL_ASSIGN_X, 0)
	UIDropDownMenu_SetWidth(row.assignDropdown, PAL_ASSIGN_WIDTH)

	row.auraDot = Theme.CreateDot(row, Theme.Colors.dashedEmpty, 6)
	row.auraDot:SetPoint("LEFT", PAL_AURA_DOT_X, 0)

	row.auraDropdown = CreateFrame("Frame", "CBABuffRosterPalAuraDD" .. index, row, "UIDropDownMenuTemplate")
	row.auraDropdown:SetPoint("LEFT", PAL_AURA_X, 0)
	UIDropDownMenu_SetWidth(row.auraDropdown, PAL_AURA_WIDTH)

	row.warningText = row:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(row.warningText, "Body", { color = "redText" })
	row.warningText:SetPoint("LEFT", row.auraDropdown, "RIGHT", 6, 2)
	row.warningText:SetWidth(130)
	row.warningText:SetJustifyH("LEFT")

	row.state = { assignOverride = nil, auraOverride = nil }
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

	-- Manual-only (SPEC.md's v1 aura scope note) -- no "Auto" preview the
	-- way Assign has, just a direct pick or Clear.
	UIDropDownMenu_Initialize(row.auraDropdown, function(self, level)
		local clearInfo = UIDropDownMenu_CreateInfo()
		clearInfo.text = "Clear"
		clearInfo.func = function()
			row.state.auraOverride = nil
			commit()
		end
		UIDropDownMenu_AddButton(clearInfo, level)

		for _, key in ipairs(CBAB.AuraOrder) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = auraLabel(key)
			info.func = function()
				row.state.auraOverride = key
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
		row.state.auraOverride = nil
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
	applyRowCard(row)

	row.nameBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.nameBox:SetSize(100, 18)
	row.nameBox:SetPoint("LEFT", 6, 0)
	row.nameBox:SetAutoFocus(false)

	-- Delete X right after the name (per request), bigger.
	row.deleteButton = CreateFrame("Button", nil, row, "UIPanelCloseButton")
	row.deleteButton:SetSize(DELETE_SIZE, DELETE_SIZE)
	row.deleteButton:SetPoint("LEFT", row.nameBox, "RIGHT", 0, 0)

	row.classDot = Theme.CreateDot(row, Theme.Colors.dashedEmpty, 6)
	row.classDot:SetPoint("LEFT", TANK_CLASS_DOT_X, 0)

	row.classDropdown = CreateFrame("Frame", "CBABuffRosterTankClassDD" .. index, row, "UIDropDownMenuTemplate")
	-- Fixed x (shared with the header, above) instead of chaining relative
	-- offsets, so headers and dropdowns stay aligned regardless of the
	-- template's internal padding.
	row.classDropdown:SetPoint("LEFT", TANK_CLASS_DD_X, 0)
	UIDropDownMenu_SetWidth(row.classDropdown, TANK_CLASS_DD_WIDTH)

	row.buffDots = {}
	row.buffDropdowns = {}
	for slot = 1, 4 do
		local dot = Theme.CreateDot(row, Theme.Colors.dashedEmpty, 6)
		dot:SetPoint("LEFT", TANK_BUFF_DOT_X[slot], 0)
		row.buffDots[slot] = dot

		local dd = CreateFrame("Frame", ("CBABuffRosterTankBuffDD%d_%d"):format(index, slot), row, "UIDropDownMenuTemplate")
		dd:SetPoint("LEFT", TANK_BUFF_DD_X[slot], 0)
		UIDropDownMenu_SetWidth(dd, TANK_BUFF_DD_WIDTH)
		row.buffDropdowns[slot] = dd
	end

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
-- Class/spec headcount rows -- fixed one-per-class, never grows. Manual
-- planning input (see file header) -- not the handoff's read-only rail
-- chips, which are a separate, simpler summary of this same data.
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

	local label = row:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(label, "ColumnLabel")
	label:SetTextColor(Theme.HexA(classHex(class), 1))
	label:SetPoint("LEFT", 26, 0)
	label:SetWidth(90)
	label:SetJustifyH("LEFT")
	label:SetText(class:sub(1, 1) .. class:sub(2):lower())

	row.specBoxes = {}
	local anchor = label
	for i, spec in ipairs(CBAB.ClassSpecs[class]) do
		local specLabel = row:CreateFontString(nil, "OVERLAY")
		Theme.StyleText(specLabel, "ColumnLabel", { color = "textFaint" })
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
-- Planned assignment (shared by the rail's Resolved/Warnings/stat chips).
-- Computes a PLANNED assignment from the profile roster -- not from live
-- raid data -- by running the real pure solver (Solver/Assign.lua) against
-- the roster window's own inputs: each paladin's Assign column (override or
-- the assumed default), the Tanks section's per-tank want-lists, and the
-- Class Headcounts majority for Might vs Wisdom. This is what lets a
-- leader see and commit a plan BEFORE the raid forms (spec 7). With no
-- headcount and no live data the majority defaults to Might primary /
-- Wisdom secondary.
--
-- The display is a live preview, recomputed every refresh. "Solve (plan)"
-- commits that same preview to profile.assignment and fires
-- ASSIGNMENT_CHANGED, which is what makes the paladin bar (and a
-- subsequent Push) reflect it. `/cbab solve` remains the separate
-- LIVE-data solve for when the raid is actually assembled.
-- ============================================================

local function buildPlannedAssignment(profile)
	local paladins = {}
	for _, r in ipairs(profile.roster) do
		if r.class == "PALADIN" then
			paladins[#paladins + 1] = r
		end
	end

	local physical, caster = tallyPhysicalCaster(profile.wants.specCounts or {})
	local primary = (caster > physical) and "wisdom" or "might"
	local assumed = assumedSlotOrder(#paladins, primary)

	-- Slots map blessing -> caster, which is exactly what Solver.Assign
	-- reads (via findSlot). Building them straight from the Assign column
	-- means the displayed plan matches the Paladins section above.
	-- slotByName records each paladin's DESIGNATED role blessing so the
	-- display can show e.g. "Greater Wisdom" for the wisdom carrier even in
	-- a roster where no class currently wants Wisdom (all-paladin, no spec
	-- data) -- otherwise the solver assigns that carrier nothing to cast and
	-- the row would misleadingly read "no greater slot".
	local slots, slotByName = {}, {}
	for i, p in ipairs(paladins) do
		local blessing = p.assignOverride or assumed[i]
		if blessing then
			slots[#slots + 1] = { blessing = blessing, caster = p.name }
			slotByName[p.name] = blessing
		end
	end

	local roster = {}
	for _, r in ipairs(profile.roster) do
		-- Skip entries missing a name or class. Solver.Assign indexes
		-- members[m.class] and errors on a nil class -- and legacy profiles
		-- (edited under older roster-page versions, before Paladins/Tanks
		-- were the only entry points) can hold class-less cruft. commitAll
		-- now drops these on the next edit; this guards the read side too.
		if r.name and r.name ~= "" and r.class then
			roster[#roster + 1] = {
				name = r.name,
				class = r.class,
				spec = r.spec,
				tank = r.tank,
				tankWantOverride = r.tankWantOverride,
			}
		end
	end

	local assignment = CBAB.Solver.Assign(slots, roster, profile.wants)
	local validation = CBAB.Solver.Validate(assignment, roster)

	-- Auras are manual-only (SPEC.md's v1 aura scope note) -- no slot
	-- construction, just a direct copy of each paladin's own dropdown pick.
	assignment.auras = {}
	for _, p in ipairs(paladins) do
		if p.auraOverride then
			assignment.auras[p.name] = p.auraOverride
		end
	end

	return assignment, validation, paladins, slotByName
end

-- Distinct greater blessing TYPES a paladin casts (in blessing order) plus
-- the overrides they own. Kept separate so the caller can color them.
-- `slotBlessing` seeds the set with the paladin's designated role even when
-- the solver gave them no class to cast it on (see slotByName above).
local function paladinAssignmentSummary(paladinName, assignment, slotBlessing)
	local greaterSet = {}
	if slotBlessing then
		greaterSet[slotBlessing] = true
	end
	for _, blessing in pairs(assignment.greaters[paladinName] or {}) do
		greaterSet[blessing] = true
	end
	local greaterParts = {}
	for _, key in ipairs(CBAB.BlessingOrder) do
		if greaterSet[key] then
			greaterParts[#greaterParts + 1] = "Greater " .. blessingLabel(key)
		end
	end

	local overrideParts = {}
	for _, o in ipairs(assignment.overrides or {}) do
		if o.caster == paladinName then
			overrideParts[#overrideParts + 1] =
				("%s->%s (%s)"):format(blessingLabel(o.blessing), o.target, o.reason)
		end
	end

	return greaterParts, overrideParts
end

-- ============================================================
-- Solve rail (fixed, right). README: Solve/Push, three stat chips, a
-- Resolved list, a Warnings list, and class headcount chips at the bottom.
-- The Resolved/Warnings lists share one small inner scroll frame between
-- the stat chips and the headcount chips -- the handoff's rail doesn't
-- scroll WITH the tables, but doesn't say its own contents can never
-- overflow a 25-raider list, so this keeps the rail itself fixed in place
-- while still coping with a full raid.
-- ============================================================

local RAIL_PAD = 10

local solveButton = Theme.CreateButton(rail, {
	text = "Solve (plan)", width = 122, height = 24, variant = "primary",
	onClick = function() doSolvePlan() end,
})
solveButton:SetPoint("TOPLEFT", rail, "TOPLEFT", RAIL_PAD, -RAIL_PAD)

local pushButton = Theme.CreateButton(rail, {
	text = "Push to raid", width = 110, height = 24, variant = "outline-blue",
	onClick = function() CBAB.Comm:PushAssignment() end,
})
pushButton:SetPoint("LEFT", solveButton, "RIGHT", 8, 0)

local syncButton = Theme.CreateButton(rail, {
	text = "Sync", width = 70, height = 20,
	onClick = function() CBAB.Comm:Hello() end,
})
syncButton:SetPoint("TOPLEFT", solveButton, "BOTTOMLEFT", 0, -8)

local reportButton = Theme.CreateButton(rail, {
	text = "Report", width = 70, height = 20,
	onClick = function() CBAB.PostReport() end,
})
reportButton:SetPoint("LEFT", syncButton, "RIGHT", 8, 0)

local function createStatChip(parent, colorKey, textColorKey)
	local chip = CreateFrame("Frame", nil, parent)
	chip:SetHeight(22)
	CBAB:ApplyBackdrop(chip, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	chip:SetBackdropColor(Theme.HexA(Theme.Colors[colorKey], 0.12))
	chip:SetBackdropBorderColor(Theme.HexA(Theme.Colors[colorKey], 0.45))
	local text = chip:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(text, "ButtonLabel", { color = textColorKey })
	text:SetPoint("CENTER")
	chip.text = text
	return chip
end

local statChipOverrides = createStatChip(rail, "gold", "goldText2")
statChipOverrides:SetSize(86, 22)
statChipOverrides:SetPoint("TOPLEFT", syncButton, "BOTTOMLEFT", 0, -10)

local statChipErrors = createStatChip(rail, "red", "redText")
statChipErrors:SetSize(86, 22)
statChipErrors:SetPoint("LEFT", statChipOverrides, "RIGHT", 6, 0)

local statChipWarns = createStatChip(rail, "teal", "tealText")
statChipWarns:SetSize(86, 22)
statChipWarns:SetPoint("LEFT", statChipErrors, "RIGHT", 6, 0)

local resolvedHeaderLabel = rail:CreateFontString(nil, "OVERLAY")
Theme.StyleText(resolvedHeaderLabel, "ColumnLabel", { color = "textFaint" })
resolvedHeaderLabel:SetPoint("TOPLEFT", statChipOverrides, "BOTTOMLEFT", 0, -12)
resolvedHeaderLabel:SetText(("Resolved"):upper())

-- Class headcount chips, anchored to the rail's bottom edge (README:
-- "Class headcount chips at bottom"). One chip per CBAB.ClassOrder class,
-- always present (0 when a class has no manual headcount), wrapped 3-per-
-- row -- read-only, purely a summary of the Class Headcounts input above.
local CLASS_CHIP_WIDTH, CLASS_CHIP_GAP, CLASS_CHIP_ROW_HEIGHT, CLASS_CHIPS_PER_ROW = 86, 6, 18, 3
local classChipRows = math.ceil(#CBAB.ClassOrder / CLASS_CHIPS_PER_ROW)

local classChipsContainer = CreateFrame("Frame", nil, rail)
classChipsContainer:SetPoint("BOTTOMLEFT", rail, "BOTTOMLEFT", RAIL_PAD, RAIL_PAD)
classChipsContainer:SetPoint("BOTTOMRIGHT", rail, "BOTTOMRIGHT", -RAIL_PAD, RAIL_PAD)
classChipsContainer:SetHeight(classChipRows * CLASS_CHIP_ROW_HEIGHT)

local classChips = {}
for i, class in ipairs(CBAB.ClassOrder) do
	local col = (i - 1) % CLASS_CHIPS_PER_ROW
	local row = math.floor((i - 1) / CLASS_CHIPS_PER_ROW)
	local chip = CreateFrame("Frame", nil, classChipsContainer)
	chip:SetSize(CLASS_CHIP_WIDTH, CLASS_CHIP_ROW_HEIGHT)
	chip:SetPoint("TOPLEFT", classChipsContainer, "TOPLEFT", col * (CLASS_CHIP_WIDTH + CLASS_CHIP_GAP), -row * CLASS_CHIP_ROW_HEIGHT)

	local dot = Theme.CreateDot(chip, classHex(class), 6)
	dot:SetPoint("LEFT", 2, 0)

	local text = chip:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(text, "ColumnLabel")
	text:SetTextColor(Theme.HexA(classHex(class), 1))
	text:SetPoint("LEFT", dot, "RIGHT", 5, 0)
	chip.text = text

	classChips[class] = chip
end

-- Inner scroll for Resolved + Warnings, filling the rail between the stat
-- chips/"Resolved" label and the class chips at the bottom.
local railListScroll = CreateFrame("ScrollFrame", "CBABuffRosterRailScroll", rail, "UIPanelScrollFrameTemplate")
railListScroll:SetPoint("TOPLEFT", resolvedHeaderLabel, "BOTTOMLEFT", 0, -4)
railListScroll:SetPoint("RIGHT", rail, "RIGHT", -RAIL_PAD, 0)
railListScroll:SetPoint("BOTTOM", classChipsContainer, "TOP", 0, 10)

local railListContent = CreateFrame("Frame", nil, railListScroll)
railListContent:SetSize(1, 1)
railListScroll:SetScrollChild(railListContent)

local RAIL_LIST_WIDTH = RAIL_WIDTH - 2 * RAIL_PAD - 26 -- clears the template's own scrollbar

-- Shared list-row builder: a small color dot + one line of text, used for
-- both the Resolved list and the red-tinted Warnings list (README: "red-
-- tinted rows (dot + text)").
local function createRailListRow()
	local row = CreateFrame("Frame", nil, railListContent)
	row:SetSize(RAIL_LIST_WIDTH, 16)
	row.dot = Theme.CreateDot(row, Theme.Colors.textFaint, 6)
	row.dot:SetPoint("LEFT", 2, 1)
	row.text = row:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(row.text, "Body", { color = "textSecondary" })
	row.text:SetPoint("LEFT", row.dot, "RIGHT", 6, 0)
	row.text:SetWidth(RAIL_LIST_WIDTH - 12)
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)
	return row
end

local railListRows = {}
local function getRailListRow(i)
	local row = railListRows[i]
	if not row then
		row = createRailListRow()
		railListRows[i] = row
	end
	return row
end

-- ============================================================
-- Footer: Export/Import paste box. The buttons themselves live in the
-- toolbar now (README puts Export/Import in the profile toolbar row) --
-- this panel is just the persistent copy/paste surface, since WoW has no
-- native modal dialog to pop one up in only when needed.
-- ============================================================

local ioLabel = window:CreateFontString(nil, "OVERLAY")
Theme.StyleText(ioLabel, "ColumnLabel", { color = "textFaint" })
ioLabel:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 14, 86)
ioLabel:SetText(("Export / Import String"):upper())

local ioScroll = CreateFrame("ScrollFrame", "CBABuffRosterIOScroll", window, "UIPanelScrollFrameTemplate")
ioScroll:SetPoint("TOPLEFT", ioLabel, "BOTTOMLEFT", 0, -4)
ioScroll:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -34, 14)
CBAB:ApplyBackdrop(ioScroll, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
ioScroll:SetBackdropColor(Theme.Hex(Theme.Colors.fieldFill))
ioScroll:SetBackdropBorderColor(Theme.Hex(Theme.Colors.borderControl))

ioBox = CreateFrame("EditBox", nil, ioScroll)
ioBox:SetMultiLine(true)
ioBox:SetAutoFocus(false)
ioBox:SetFontObject(ChatFontNormal)
ioBox:SetTextColor(Theme.C("textPrimary"))
ioBox:SetWidth(WINDOW_WIDTH - 34 - 34)
ioBox:SetHeight(200)
ioBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
ioScroll:SetScrollChild(ioBox)

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
					auraOverride = row.state.auraOverride,
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

	-- Preserve any WELL-FORMED entry neither section touched this pass.
	-- In practice every entry is a paladin, a tank, or both, so this rarely
	-- fires -- but it deliberately DROPS entries with no name or no class:
	-- legacy profiles (from older roster-page versions) can hold class-less
	-- cruft that has no home in the current UI and crashes the solver
	-- (Assign.lua indexes members[class]). Editing the roster once purges it.
	for _, r in ipairs(profile.roster) do
		if r.name and r.name ~= "" and r.class and not seen[r.name] then
			newRoster[#newRoster + 1] = r
			seen[r.name] = true
		end
	end

	profile.roster = newRoster
	profile.modified = time()
end

doSolvePlan = function()
	local profile = CBAB.DB:Profile()
	if not profile then
		CBAB:Print("no active profile")
		return
	end
	local assignment = buildPlannedAssignment(profile)
	assignment.epoch = (profile.assignment and profile.assignment.epoch or 0) + 1
	assignment.author = UnitName("player")
	assignment.timestamp = time()
	-- Not pushed yet (spec 8): Comm:PushAssignment marks it "pushed".
	assignment.source = "local"
	-- assignment.auras is already populated by buildPlannedAssignment above,
	-- straight from each paladin row's own Aura dropdown.
	profile.assignment = assignment
	profile.modified = time()
	CBAB:Print(("solved plan for '%s' -- %d override(s). Push to raid when ready."):format(
		profile.name, #assignment.overrides))
	-- Fires the roster page's own refresh AND the paladin bar's, so both
	-- reflect the just-committed plan (this is the pbar-wiring fix).
	CBAB:Fire("ASSIGNMENT_CHANGED")
end

-- ============================================================
-- Refresh: lays out the main scroll's sections top-to-bottom with a
-- running cursor (row counts change independently every edit), then the
-- fixed rail separately from its own cursor.
-- ============================================================

local function refreshRail(profile)
	local assignment, validation, paladins, slotByName = buildPlannedAssignment(profile)

	local errorCount, warnCount = 0, 0
	for _, f in ipairs(validation) do
		if f.level == "error" then errorCount = errorCount + 1 else warnCount = warnCount + 1 end
	end
	statChipOverrides.text:SetText(("%d override%s"):format(#assignment.overrides, #assignment.overrides == 1 and "" or "s"))
	statChipErrors.text:SetText(("%d error%s"):format(errorCount, errorCount == 1 and "" or "s"))
	statChipWarns.text:SetText(("%d warn%s"):format(warnCount, warnCount == 1 and "" or "s"))
	pushButton:SetEnabled(errorCount == 0)

	local y, rowIndex = 0, 0
	if #paladins == 0 then
		rowIndex = rowIndex + 1
		local row = getRailListRow(rowIndex)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", railListContent, "TOPLEFT", 0, y)
		row.dot:SetColorTexture(Theme.Hex(Theme.Colors.textFaint))
		row.text:SetText("No paladins in the roster yet.")
		row:Show()
		y = y - 16
	else
		for _, p in ipairs(paladins) do
			rowIndex = rowIndex + 1
			local row = getRailListRow(rowIndex)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", railListContent, "TOPLEFT", 0, y)

			local slotBlessing = slotByName[p.name]
			local tint = slotBlessing and Theme.BlessingTint(slotBlessing)
			if tint then
				row.dot:SetColorTexture(tint.solid[1], tint.solid[2], tint.solid[3])
			else
				row.dot:SetColorTexture(Theme.Hex(classHex("PALADIN")))
			end

			local greaterParts, overrideParts = paladinAssignmentSummary(p.name, assignment, slotBlessing)
			local greaterText = #greaterParts > 0 and table.concat(greaterParts, ", ") or "no greater slot"
			local line = ("|cff%s%s|r: %s"):format(classHex("PALADIN"), p.name, greaterText)
			if #overrideParts > 0 then
				line = line .. "  |c" .. Theme.ColorCode("gold") .. "[" .. table.concat(overrideParts, ", ") .. "]|r"
			end
			row.text:SetText(line)
			row:Show()
			y = y - 16
		end
	end

	if #validation > 0 then
		y = y - 6
		for _, f in ipairs(validation) do
			rowIndex = rowIndex + 1
			local row = getRailListRow(rowIndex)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", railListContent, "TOPLEFT", 0, y)
			local colorKey = (f.level == "error") and "red" or "gold"
			row.dot:SetColorTexture(Theme.Hex(Theme.Colors[colorKey]))
			row.text:SetText(("|c%s[%s]|r %s"):format(Theme.ColorCode(colorKey), f.level:upper(), f.message))
			row:Show()
			y = y - 16
		end
	end

	for i = rowIndex + 1, #railListRows do
		railListRows[i]:Hide()
	end
	railListContent:SetSize(RAIL_LIST_WIDTH, math.max(1, -y))

	local specCounts = profile.wants.specCounts or {}
	for _, class in ipairs(CBAB.ClassOrder) do
		local counts = specCounts[class] or {}
		local total = 0
		for _, n in pairs(counts) do total = total + (tonumber(n) or 0) end
		classChips[class].text:SetText(("%s %d"):format(CLASS_ABBR[class], total))
	end
end

refreshAll = function()
	local profile = CBAB.DB:Profile()

	if profile and not profileNameBox:HasFocus() then
		profileNameBox:SetText(profile.name)
	end
	UIDropDownMenu_SetText(profileDropdown, profile and profile.name or "Select profile")
	petsToggle:SetChecked(profile and profile.wants and profile.wants.petsEnabled and true or false)

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
			row.state.auraOverride = entry.auraOverride
			row.deleteButton:Show()
		else
			row.nameBox:SetText("")
			row.tank:SetChecked(false)
			row.specBox:SetText("")
			row.state.assignOverride = nil
			row.state.auraOverride = nil
			row.deleteButton:Hide()
		end

		local assumedBlessing = assumed[i]
		local effective = row.state.assignOverride or assumedBlessing
		UIDropDownMenu_SetText(row.assignDropdown, blessingLabel(effective))
		UIDropDownMenu_SetText(row.auraDropdown, auraLabel(row.state.auraOverride))

		local assignTint = effective and Theme.BlessingTint(effective)
		if assignTint then
			row.assignDot:SetColorTexture(assignTint.solid[1], assignTint.solid[2], assignTint.solid[3])
		else
			row.assignDot:SetColorTexture(Theme.Hex(Theme.Colors.dashedEmpty))
		end

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
		row.classDot:SetColorTexture(Theme.Hex(classHex(row.state.class)))

		local defaultWants = (profile.wants.tanks and profile.wants.tanks[row.state.class]) or {}
		for slot, dd in ipairs(row.buffDropdowns) do
			local value = row.state.tankWantOverride[slot]
			if value == nil then
				value = defaultWants[slot]
			end
			UIDropDownMenu_SetText(dd, value and blessingLabel(value) or "-")
			local buffTint = value and Theme.BlessingTint(value)
			if buffTint then
				row.buffDots[slot]:SetColorTexture(buffTint.solid[1], buffTint.solid[2], buffTint.solid[3])
			else
				row.buffDots[slot]:SetColorTexture(Theme.Hex(Theme.Colors.dashedEmpty))
			end
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

	refreshRail(profile)
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
-- The standalone editor was folded into this page (spec 11.1); keep the old
-- command working so muscle memory / macros don't silently break.
CBAB.SlashCommands.editor = function() CBAB.RosterPage:Toggle() end
