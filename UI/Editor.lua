local ADDON, CBAB = ...

-- The assignment editor (spec 11.1). Classes as rows, paladins as columns
-- -- deliberately not a PallyPower-style grid, because the leader's
-- setup-time questions ("do the mages have Kings?") are class-first and
-- this answers them by reading across one row. No auto-solve anywhere in
-- this file; Solve and Push are both manual buttons.

CBAB.Editor = {}

local ROW_HEIGHT = 20
local CLASS_COL_WIDTH = 80
local PAL_COL_WIDTH = 92

-- Fixed row-priority order, same as UI/Bar.lua's class compaction, so the
-- editor and the bar agree on ordering. Unlike the bar, nothing here
-- collapses class SLOTS by button count -- every class present in the
-- raid gets a row; only classes with NO members at all are hidden
-- ("classes with no decisions collapse", spec 11.1).
local CLASS_ORDER = { "WARRIOR", "ROGUE", "PRIEST", "DRUID", "PALADIN", "HUNTER", "MAGE", "WARLOCK", "SHAMAN" }

-- ============================================================
-- Window
-- ============================================================

local window = CreateFrame("Frame", "CBABuffEditor", UIParent)
window:SetSize(500, 400)
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
title:SetText("CBA Buff -- Assignment Editor")

local closeButton = CreateFrame("Button", nil, window, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -4, -4)
closeButton:SetScript("OnClick", function() window:Hide() end)

window:RegisterForDrag("LeftButton")
window:SetScript("OnDragStart", function() window:StartMoving() end)
window:SetScript("OnDragStop", function() window:StopMovingOrSizing() end)

-- ============================================================
-- Plan diff banner (spec 6.3, 6.4): non-blocking -- the rest of the
-- editor stays fully usable while it's showing. Dismissing via "Keep
-- plan" suppresses THIS SPECIFIC diff (by content signature) until
-- something actually changes again; it never permanently disables the
-- check.
-- ============================================================

local banner = CreateFrame("Frame", nil, window)
banner:SetPoint("TOPLEFT", 12, -34)
banner:SetPoint("TOPRIGHT", -12, -34)
banner:SetHeight(40)
banner:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
banner:SetBackdropColor(0.5, 0.35, 0, 0.85)
banner:Hide()

local bannerText = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
bannerText:SetPoint("LEFT", 8, 0)
bannerText:SetPoint("RIGHT", -140, 0)
bannerText:SetJustifyH("LEFT")
bannerText:SetWordWrap(true)

local dismissedSignature

local function diffSignature(changes)
	local parts = {}
	for _, c in ipairs(changes) do parts[#parts + 1] = c.message end
	table.sort(parts)
	return table.concat(parts, "|")
end

local reSolveFromBanner -- forward-declared, assigned once solveNow exists below
local bannerResolve = CreateFrame("Button", nil, banner, "UIPanelButtonTemplate")
bannerResolve:SetSize(80, 20)
bannerResolve:SetPoint("RIGHT", -68, 0)
bannerResolve:SetText("Re-solve")
bannerResolve:SetScript("OnClick", function()
	if reSolveFromBanner then reSolveFromBanner() end
	banner:Hide()
end)

local bannerKeep = CreateFrame("Button", nil, banner, "UIPanelButtonTemplate")
bannerKeep:SetSize(80, 20)
bannerKeep:SetPoint("RIGHT", 16, 0)
bannerKeep:SetText("Keep plan")
bannerKeep:SetScript("OnClick", function()
	local profile = CBAB.DB:Profile()
	dismissedSignature = profile and diffSignature(CBAB.Cap:DiffAgainstPlan(profile))
	banner:Hide()
end)

-- ============================================================
-- Capability header (one column per paladin): spec, kings/sanctuary,
-- improved ranks, and provenance+age, greyed past ~14 days (spec 6.2).
-- ============================================================

local capHeader = CreateFrame("Frame", nil, window)
capHeader:SetPoint("TOPLEFT", CLASS_COL_WIDTH + 12, -84)
capHeader:SetPoint("TOPRIGHT", -12, -84)
capHeader:SetHeight(70)

local capColumns = {}

local function getCapColumn(index)
	local col = capColumns[index]
	if not col then
		col = capHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		col:SetJustifyH("CENTER")
		col:SetJustifyV("TOP")
		col:SetWidth(PAL_COL_WIDTH - 4)
		capColumns[index] = col
	end
	return col
end

local STALE_SECONDS = 14 * 24 * 60 * 60

local function formatProvenance(source, age)
	if not source or source == "unknown" then
		return "unknown", false
	end
	if source == "live" then
		return "live", false
	end
	local days = age and math.floor(age / 86400) or 0
	return ("%s %dd ago"):format(source, days), (age or 0) > STALE_SECONDS
end

local function capabilityText(m)
	local record, source, age = CBAB.Cap:Get(m.nameRealm)
	local provenance, stale = formatProvenance(source, age)

	local lines = { m.name }
	if record then
		lines[#lines + 1] = record.spec or "?"
		lines[#lines + 1] = ("K:%s S:%s"):format(record.kings and "Y" or "-", record.sanctuary and "Y" or "-")
		lines[#lines + 1] = ("iM:%d iW:%d"):format(record.impMight or 0, record.impWisdom or 0)
	else
		lines[#lines + 1] = "no data"
	end
	lines[#lines + 1] = provenance
	return table.concat(lines, "\n"), stale
end

-- ============================================================
-- Grid body: class rows x paladin columns.
-- ============================================================

local gridBody = CreateFrame("Frame", nil, window)
gridBody:SetPoint("TOPLEFT", 12, -158)
gridBody:SetPoint("BOTTOMRIGHT", -12, 96)

local rowFrames = {}
local cellPool = {}

local function getRowFrame(index)
	local row = rowFrames[index]
	if not row then
		row = CreateFrame("Frame", nil, gridBody)
		row:SetHeight(ROW_HEIGHT)
		row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		row.label:SetPoint("LEFT", 0, 0)
		row.label:SetWidth(CLASS_COL_WIDTH - 20)
		row.label:SetJustifyH("LEFT")

		row.tankMarker = CreateFrame("Button", nil, row)
		row.tankMarker:SetSize(14, 14)
		row.tankMarker:SetPoint("LEFT", CLASS_COL_WIDTH - 16, 0)
		row.tankMarker.tex = row.tankMarker:CreateTexture(nil, "OVERLAY")
		row.tankMarker.tex:SetAllPoints()
		row.tankMarker.tex:SetColorTexture(0.9, 0.6, 0.1, 1)
		row.tankMarker:Hide()

		rowFrames[index] = row
	end
	return row
end

local function getCell(rowIndex, colIndex)
	cellPool[rowIndex] = cellPool[rowIndex] or {}
	local cell = cellPool[rowIndex][colIndex]
	if not cell then
		cell = gridBody:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		cell:SetJustifyH("CENTER")
		cell:SetWidth(PAL_COL_WIDTH - 4)
		cellPool[rowIndex][colIndex] = cell
	end
	return cell
end

-- ============================================================
-- Bottom bar: Solve, Push, override count, validator output.
-- ============================================================

local solveButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
solveButton:SetSize(80, 22)
solveButton:SetPoint("BOTTOMLEFT", 12, 12)
solveButton:SetText("Solve")

local pushButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
pushButton:SetSize(90, 22)
pushButton:SetPoint("LEFT", solveButton, "RIGHT", 8, 0)
pushButton:SetText("Push to raid")

local overrideCountText = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
overrideCountText:SetPoint("LEFT", pushButton, "RIGHT", 12, 0)

local validatorArea = CreateFrame("Frame", nil, window)
validatorArea:SetPoint("BOTTOMLEFT", 12, 40)
validatorArea:SetPoint("BOTTOMRIGHT", -12, 40)
validatorArea:SetHeight(50)
local validatorLines = {}

local function getValidatorLine(index)
	local fs = validatorLines[index]
	if not fs then
		fs = validatorArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("TOPLEFT", 0, -(index - 1) * 14)
		fs:SetJustifyH("LEFT")
		validatorLines[index] = fs
	end
	return fs
end

local function solveNow()
	if CBAB.SlashCommands.solve then
		CBAB.SlashCommands.solve()
	end
end
reSolveFromBanner = solveNow

solveButton:SetScript("OnClick", solveNow)
solveButton:SetScript("OnEnter", function(self)
	if InCombatLockdown() then
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Blocked in combat", 1, 1, 1)
		GameTooltip:Show()
	end
end)
solveButton:SetScript("OnLeave", GameTooltip_Hide)

pushButton:SetScript("OnClick", function()
	CBAB.Comm:PushAssignment()
end)

-- ============================================================
-- Refresh: rebuilds the whole grid from live data. Called on every
-- relevant event, never polled.
-- ============================================================

local function presentClasses()
	local counts = CBAB.Roster:ClassCounts()
	local classes = {}
	for _, class in ipairs(CLASS_ORDER) do
		if (counts[class] or 0) > 0 then
			classes[#classes + 1] = class
		end
	end
	return classes
end

local function classHasTank(class)
	for _, m in pairs(CBAB.Roster:Get()) do
		if not m.isPet and m.class == class and m.isTank then
			return true
		end
	end
	return false
end

local function refreshCapabilityHeader(paladins)
	for i, m in ipairs(paladins) do
		local col = getCapColumn(i)
		col:ClearAllPoints()
		col:SetPoint("TOP", capHeader, "TOPLEFT", (i - 1) * PAL_COL_WIDTH + PAL_COL_WIDTH / 2, 0)
		local text, stale = capabilityText(m)
		col:SetText(text)
		if stale then
			col:SetTextColor(0.55, 0.55, 0.55)
		else
			col:SetTextColor(1, 1, 1)
		end
		col:Show()
	end
	for i = #paladins + 1, #capColumns do
		capColumns[i]:Hide()
	end
end

local function refreshGrid(classes, paladins, assignment)
	for r, class in ipairs(classes) do
		local row = getRowFrame(r)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", gridBody, "TOPLEFT", 0, -(r - 1) * ROW_HEIGHT)
		row:SetPoint("TOPRIGHT", gridBody, "TOPRIGHT", 0, -(r - 1) * ROW_HEIGHT)
		row.label:SetText(class:sub(1, 1) .. class:sub(2):lower())
		row:Show()

		-- Tank conflict marker: this class has a tank whose want-list is
		-- handled by override, not by the class-wide greater alone
		-- (spec 11.1: "click to edit" -- there's no want-list editor UI
		-- yet, so this opens a tooltip summary of what's assigned instead).
		if classHasTank(class) then
			row.tankMarker:Show()
			row.tankMarker:SetScript("OnClick", function()
				local lines = {}
				local roster = CBAB.Roster:Get()
				for _, o in ipairs((assignment and assignment.overrides) or {}) do
					for _, rm in pairs(roster) do
						if rm.name == o.target and rm.class == class and rm.isTank then
							lines[#lines + 1] = ("%s: %s -> %s (%s)"):format(o.target, o.caster, CBAB.Blessings[o.blessing].name, o.reason)
						end
					end
				end
				if #lines == 0 then
					lines[1] = "No override recorded yet -- run Solve."
				end
				CBAB:Print(("-- %s tank overrides --"):format(row.label:GetText()))
				for _, l in ipairs(lines) do CBAB:Print("  " .. l) end
			end)
			row.tankMarker:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText("Tank in this class -- click for override detail", 1, 1, 1)
				GameTooltip:Show()
			end)
			row.tankMarker:SetScript("OnLeave", GameTooltip_Hide)
		else
			row.tankMarker:Hide()
		end

		for c, m in ipairs(paladins) do
			local cell = getCell(r, c)
			cell:ClearAllPoints()
			cell:SetPoint("TOP", row, "TOPLEFT", (c - 1) * PAL_COL_WIDTH + PAL_COL_WIDTH / 2, 0)
			local blessing = assignment and assignment.greaters[m.name] and assignment.greaters[m.name][class]
			cell:SetText(blessing and CBAB.Blessings[blessing].name or "-")
			cell:Show()
		end
		if cellPool[r] then
			for c = #paladins + 1, #cellPool[r] do
				if cellPool[r][c] then cellPool[r][c]:Hide() end
			end
		end
	end

	for r = #classes + 1, #rowFrames do
		rowFrames[r]:Hide()
		if cellPool[r] then
			for _, cell in pairs(cellPool[r]) do cell:Hide() end
		end
	end
end

local function refreshValidator()
	local findings = CBAB.Solve:ValidateCurrent()
	local errorCount, warnCount = 0, 0
	for i, f in ipairs(findings) do
		local fs = getValidatorLine(i)
		if f.level == "error" then
			errorCount = errorCount + 1
			fs:SetText("|cffff4444[ERROR]|r " .. f.message)
		else
			warnCount = warnCount + 1
			fs:SetText("|cffffcc00[warn]|r " .. f.message)
		end
		fs:Show()
	end
	for i = #findings + 1, #validatorLines do
		validatorLines[i]:Hide()
	end

	pushButton:SetEnabled(errorCount == 0)
	return errorCount, warnCount
end

local function refreshBanner(profile)
	if not profile then
		banner:Hide()
		return
	end
	local changes = CBAB.Cap:DiffAgainstPlan(profile)
	if #changes == 0 then
		banner:Hide()
		return
	end
	local sig = diffSignature(changes)
	if sig == dismissedSignature then
		banner:Hide()
		return
	end

	local lines = {}
	for _, c in ipairs(changes) do lines[#lines + 1] = c.message end
	bannerText:SetText(table.concat(lines, "\n"))
	banner:SetHeight(14 + 14 * #changes)
	banner:Show()
end

function CBAB.Editor:Refresh()
	if not window:IsShown() then return end

	local profile = CBAB.DB:Profile()
	local paladins = CBAB.Roster:Paladins()
	table.sort(paladins, function(a, b) return a.name < b.name end)
	local classes = presentClasses()
	local assignment = profile and profile.assignment

	refreshBanner(profile)
	refreshCapabilityHeader(paladins)
	refreshGrid(classes, paladins, assignment)
	local errorCount, warnCount = refreshValidator()

	local overrideCount = assignment and #assignment.overrides or 0
	overrideCountText:SetText(("%d override(s)  |  %d error(s), %d warning(s)"):format(overrideCount, errorCount, warnCount))

	solveButton:SetEnabled(not InCombatLockdown())

	-- Grow the window to fit the current grid + capability header.
	window:SetHeight(200 + (#classes * ROW_HEIGHT))
end

-- ============================================================
-- Toggle / Show / Hide
-- ============================================================

function CBAB.Editor:Toggle()
	if window:IsShown() then
		window:Hide()
	else
		window:Show()
		CBAB.Editor:Refresh()
	end
end

function CBAB.Editor:Show()
	window:Show()
	CBAB.Editor:Refresh()
end

function CBAB.Editor:Hide()
	window:Hide()
end

CBAB:On("ASSIGNMENT_CHANGED", "editor:refresh", function() CBAB.Editor:Refresh() end)
CBAB:On("CAPABILITY_CHANGED", "editor:refresh-cap", function() CBAB.Editor:Refresh() end)
CBAB:On("ROSTER_CHANGED", "editor:refresh-roster", function() CBAB.Editor:Refresh() end)
CBAB:On("PLAYER_REGEN_DISABLED", "editor:combat", function() CBAB.Editor:Refresh() end)
CBAB:On("PLAYER_REGEN_ENABLED", "editor:combat2", function() CBAB.Editor:Refresh() end)

CBAB.SlashCommands.editor = function() CBAB.Editor:Toggle() end
