local ADDON, CBAB = ...
local Theme = CBAB.Theme

-- The config window (spec 11.5), reskinned per the design handoff
-- (UI/redesign/design_handoff_cba_buff/README.md, "3. Config window",
-- HTML section 4a, screenshots/4-config.png) on top of UI/Theme.lua --
-- same shared design system UI/Bar.lua, UI/Alert.lua and UI/RosterPage.lua
-- already build on. This file's own business logic (which DB field each
-- setting reads/writes) is unchanged from the pre-redesign version; only
-- frame creation/styling and the top-level layout moved.
--
-- Structural change from the old single-column panel that ran off the
-- frame: settings are now split into five categories in a left sidebar
-- (README's dot colors below) -- only the active category's rows render in
-- the content scroll, so a fixed 860x600 window never overflows.
--
-- Two things the HTML reference doesn't spell out, decided here:
--   - "Open pbar" and "Preview alert" are each ONE row: a label+description
--     on the left (what the row does) and a short-labelled button on the
--     right (the actual control) -- not a label-less row whose entire
--     content is the button, since every other row in the mock keeps that
--     label/control split.
--   - Per-section subtitles (shown under the big content title) aren't in
--     the README's copy at all outside the Warnings screenshot -- the other
--     four are this file's own one-line descriptions of what the category
--     covers.
-- "Reset section" (footer, README) resets only the ACTIVE category's own
-- fields back to CBAB.Defaults -- e.g. clicking it on Paladin bar never
-- touches Warnings/Alert/Debug/pets.
--
-- Row pool: every row in every section is one of four shapes (toggle,
-- number stepper, button, full-width note) -- see the HTML's r.isNote /
-- r.hasControl+toggleOn/toggleOff / r.isNumber / r.isButton sc-ifs. Rather
-- than build distinct frames per section, one pool of generic row frames
-- (sized to the largest section) is built once and re-skinned per row via
-- applyRowSpec() every time the active category changes -- same "build a
-- pool, reuse by index" shape as UI/RosterPage.lua's palRows/tankRows.

CBAB.Config = {}

-- ============================================================
-- Layout constants (design handoff README.md, "3. Config window").
-- ============================================================

local WINDOW_WIDTH, WINDOW_HEIGHT = 860, 600
local SIDEBAR_WIDTH = 216
local FOOTER_HEIGHT = 52
local NAV_HEIGHT = 36
local ROW_HEIGHT = 58
local ROW_GAP = 8
local CONTENT_PAD = 24
local MAX_ROWS = 7 -- largest section (Alert window) has 6 rows; one spare slot

-- ============================================================
-- Data accessors. Resolved fresh on every get/set rather than cached, so
-- nothing here goes stale across a reload (same posture as the pre-redesign
-- file).
-- ============================================================

local function warnings() return CBAB.DB:Char().warnings end
local function barUI() return CBAB.DB:Char().ui.bar end
local function alertUI() return CBAB.DB:Char().ui.alert end
local function debugUI() return CBAB.DB:Char().debug end
local function wants()
	local profile = CBAB.DB:Profile()
	return profile and profile.wants
end

-- ============================================================
-- Window chrome: same fill/hairline/shadow recipe as UI/RosterPage.lua,
-- fixed at the handoff's 860x600 (no resize grip -- the sidebar split is
-- what fixes overflow, not scaling the window).
-- ============================================================

local window = CreateFrame("Frame", "CBABuffConfig", UIParent)
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

-- Forward-declared: nav/row bindings below close over these as upvalues,
-- but the real bodies aren't assigned until every section/row is built.
local layoutSection, refreshAll
local currentSectionId

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
titleText:SetText("CBA BUFF")

local subtitleText = titleBar:CreateFontString(nil, "OVERLAY")
Theme.StyleText(subtitleText, "Subtitle", { color = "textSecondary" })
subtitleText:SetPoint("LEFT", titleText, "RIGHT", 8, 0)
subtitleText:SetText("Config")

local closeButton = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -6, -6)
closeButton:SetScript("OnClick", function() window:Hide() end)

-- ============================================================
-- Footer: Reset section (ghost) + Done (gold filled). Built before the
-- body so the body's BOTTOM anchor has something to sit on.
-- ============================================================

local footer = CreateFrame("Frame", nil, window)
footer:SetPoint("BOTTOMLEFT", 0, 0)
footer:SetPoint("BOTTOMRIGHT", 0, 0)
footer:SetHeight(FOOTER_HEIGHT)

local footerFill = footer:CreateTexture(nil, "BACKGROUND")
footerFill:SetAllPoints()
footerFill:SetColorTexture(Theme.HexA("000000", 0.18))

-- Single top-edge texture rather than a full ApplyBackdrop border -- see
-- contentHeaderDivider above for why.
local footerDivider = footer:CreateTexture(nil, "ARTWORK")
footerDivider:SetHeight(1)
footerDivider:SetPoint("TOPLEFT", 0, 0)
footerDivider:SetPoint("TOPRIGHT", 0, 0)
footerDivider:SetColorTexture(Theme.Hex(Theme.Colors.divider))

local doneButton = Theme.CreateButton(footer, {
	text = "Done", width = 90, height = 26, variant = "primary",
	onClick = function() window:Hide() end,
})
doneButton:SetPoint("RIGHT", -18, 0)

local resetButton = Theme.CreateButton(footer, {
	text = "Reset section", width = 110, height = 26,
	onClick = function()
		local section = CBAB.Config.Sections[currentSectionId]
		if section and section.reset then
			section.reset()
			refreshAll()
		end
	end,
})
resetButton:SetPoint("LEFT", 18, 0)

-- ============================================================
-- Sidebar: SETTINGS label + one nav button per category + version string
-- pinned to the bottom (README: sidebar 216px, dot + label, active = gold
-- fill/border/text).
-- ============================================================

local sidebar = CreateFrame("Frame", nil, window)
sidebar:SetWidth(SIDEBAR_WIDTH)
sidebar:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, 0)
sidebar:SetPoint("BOTTOM", footer, "TOP", 0, 0)
CBAB:ApplyBackdrop(sidebar, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
sidebar:SetBackdropColor(Theme.HexA("000000", 0.18))
sidebar:SetBackdropBorderColor(Theme.Hex(Theme.Colors.borderSubtle))

local sidebarLabel = sidebar:CreateFontString(nil, "OVERLAY")
Theme.StyleText(sidebarLabel, "ColumnLabel", { color = "textFaint", spacing = 1.4 })
sidebarLabel:SetPoint("TOPLEFT", 12, -14)
sidebarLabel:SetText(("Settings"):upper())

local versionText = sidebar:CreateFontString(nil, "OVERLAY")
Theme.StyleText(versionText, "Body", { color = "textFaint" })
versionText:SetPoint("BOTTOMLEFT", 12, 10)
versionText:SetPoint("BOTTOMRIGHT", -12, 10)
versionText:SetJustifyH("LEFT")
versionText:SetText(("CBA Buff · v%s · TBC 2.5.6"):format(CBAB.version))

-- Keyed ONLY by section id (never also by array index) -- updateSidebarActive
-- below does a plain `pairs()` scan, and a table that stored each button
-- under both its id and its creation-order index would visit the same
-- button object twice with two different keys, racing over which write
-- "wins" depending on pairs()'s undefined order.
local navButtons = {}

local function createNavButton(section)
	local btn = CreateFrame("Button", nil, sidebar)
	btn:SetHeight(NAV_HEIGHT)
	CBAB:ApplyBackdrop(btn, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })

	local dot = Theme.CreateDot(btn, section.dot, 9)
	dot:SetPoint("LEFT", 12, 0)

	local label = btn:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(label, "ButtonLabel", { upper = false })
	label:SetPoint("LEFT", dot, "RIGHT", 10, 0)
	label:SetText(section.label)

	Theme.ApplyHoverHighlight(btn)
	btn:SetScript("OnClick", function() layoutSection(section.id) end)

	btn.dot, btn.labelText = dot, label
	return btn
end

local function updateSidebarActive()
	for id, btn in pairs(navButtons) do
		if id == currentSectionId then
			btn:SetBackdropColor(Theme.HexA(Theme.Colors.gold, 0.12))
			btn:SetBackdropBorderColor(Theme.HexA(Theme.Colors.gold, 0.4))
			btn.labelText:SetTextColor(Theme.C("goldText"))
		else
			btn:SetBackdropColor(0, 0, 0, 0)
			btn:SetBackdropBorderColor(0, 0, 0, 0)
			btn.labelText:SetTextColor(Theme.C("textSecondary"))
		end
	end
end

-- ============================================================
-- Content: header (active section's title + subtitle) + a scrolling list
-- of setting rows.
-- ============================================================

local content = CreateFrame("Frame", nil, window)
content:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 0, 0)
content:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, 0)

local contentHeader = CreateFrame("Frame", nil, content)
contentHeader:SetPoint("TOPLEFT", 0, 0)
contentHeader:SetPoint("TOPRIGHT", 0, 0)
contentHeader:SetHeight(58)

-- A single bottom-edge texture, not a full ApplyBackdrop border -- the
-- latter would also draw stray left/right edges the reference doesn't have
-- (same "dedicated divider line" approach as RosterPage.lua's separators).
local contentHeaderDivider = contentHeader:CreateTexture(nil, "ARTWORK")
contentHeaderDivider:SetHeight(1)
contentHeaderDivider:SetPoint("BOTTOMLEFT", 0, 0)
contentHeaderDivider:SetPoint("BOTTOMRIGHT", 0, 0)
contentHeaderDivider:SetColorTexture(Theme.Hex(Theme.Colors.divider))

-- Content title (README screenshot: "Warnings", 22px bold, normal case --
-- distinct from the Type scale table's 14px UPPER "Section header" role, so
-- this is its own Theme.Fonts entry rather than reusing SectionHeader.
Theme.Fonts.ContentTitle = Theme.Fonts.ContentTitle or CreateFont("CBABuffFontContentTitle")
do
	local font = Theme.Fonts.ContentTitle
	local FONT_DIR = "Interface\\AddOns\\" .. ADDON .. "\\Fonts\\"
	local ok = font:SetFont(FONT_DIR .. "Rajdhani-Bold.ttf", 22, "")
	if not ok then
		font:CopyFontObject(GameFontNormalLarge)
		local path, _, flags = font:GetFont()
		font:SetFont(path, 22, flags)
	end
end

local contentTitle = contentHeader:CreateFontString(nil, "OVERLAY")
Theme.StyleText(contentTitle, "ContentTitle", { color = "textPrimary" })
contentTitle:SetPoint("TOPLEFT", CONTENT_PAD, -18)

local contentSubtitle = contentHeader:CreateFontString(nil, "OVERLAY")
Theme.StyleText(contentSubtitle, "Body", { color = "textMuted" })
contentSubtitle:SetPoint("TOPLEFT", contentTitle, "BOTTOMLEFT", 0, -3)
contentSubtitle:SetPoint("RIGHT", contentHeader, "RIGHT", -CONTENT_PAD, 0)
contentSubtitle:SetJustifyH("LEFT")

local scrollFrame = CreateFrame("ScrollFrame", "CBABuffConfigScroll", content, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", contentHeader, "BOTTOMLEFT", CONTENT_PAD, -16)
scrollFrame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -(CONTENT_PAD + 26), 24)

local ROW_WIDTH = WINDOW_WIDTH - SIDEBAR_WIDTH - CONTENT_PAD * 2 - 26 -- clears the template's own scrollbar

local rowScrollChild = CreateFrame("Frame", nil, scrollFrame)
rowScrollChild:SetSize(ROW_WIDTH, ROW_HEIGHT)
scrollFrame:SetScrollChild(rowScrollChild)

-- ============================================================
-- Row pool. Each pooled row carries one each of every control type (toggle,
-- number stepper, button, note) and shows/hides whichever one the current
-- spec needs -- see file header.
-- ============================================================

local NUMBER_STEP_WIDTH, NUMBER_STEP_HEIGHT = 26, 34

local function createRow()
	local row = CreateFrame("Frame", nil, rowScrollChild)
	row:SetSize(ROW_WIDTH, ROW_HEIGHT)
	CBAB:ApplyBackdrop(row, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	row:SetBackdropColor(Theme.HexA("ffffff", 0.014))
	row:SetBackdropBorderColor(Theme.Hex(Theme.Colors.borderSubtle))
	Theme.ApplyHoverHighlight(row, { hoverAlpha = 0.05, pressAlpha = 0.02 })

	-- Fixed right margin clears the widest control (the number stepper,
	-- ~112px) plus a gap -- simpler than recomputing per row-type, and the
	-- unused space next to a toggle/button is the same "control column"
	-- look the handoff's own flex layout produces.
	row.labelFS = row:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(row.labelFS, "Body", { color = "textPrimary" })
	row.labelFS:SetPoint("TOPLEFT", 16, -12)
	row.labelFS:SetPoint("RIGHT", -150, 0)
	row.labelFS:SetJustifyH("LEFT")

	row.descFS = row:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(row.descFS, "Body", { color = "textMuted" })
	row.descFS:SetPoint("TOPLEFT", row.labelFS, "BOTTOMLEFT", 0, -3)
	row.descFS:SetPoint("RIGHT", -150, 0)
	row.descFS:SetJustifyH("LEFT")
	row.descFS:SetWordWrap(true)

	-- Toggle control.
	row.toggle = Theme.CreateToggle(row, {
		onClick = function(_, checked)
			local spec = row.spec
			if spec and spec.set then spec.set(checked) end
		end,
	})
	row.toggle:SetPoint("RIGHT", -16, 0)

	-- Number stepper: [-] value+unit [+] inside one field-tinted container.
	row.numberBox = CreateFrame("Frame", nil, row)
	row.numberBox:SetSize(2 * NUMBER_STEP_WIDTH + 60, NUMBER_STEP_HEIGHT)
	row.numberBox:SetPoint("RIGHT", -16, 0)
	CBAB:ApplyBackdrop(row.numberBox, { edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	row.numberBox:SetBackdropColor(Theme.Hex(Theme.Colors.fieldFill))
	row.numberBox:SetBackdropBorderColor(Theme.Hex(Theme.Colors.borderControl))

	row.numberValueFS = row.numberBox:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(row.numberValueFS, "NumericValue", { color = "goldText2" })
	row.numberValueFS:SetPoint("CENTER")

	local function stepValue(delta)
		local spec = row.spec
		if not spec or not spec.get or not spec.set then return end
		local v = spec.get() + delta
		if spec.min then v = math.max(spec.min, v) end
		if spec.max then v = math.min(spec.max, v) end
		spec.set(v)
		row.numberValueFS:SetText(("%s %s"):format(spec.get(), spec.unit or ""))
	end

	row.numberMinus = Theme.CreateButton(row.numberBox, {
		text = "-", width = NUMBER_STEP_WIDTH, height = NUMBER_STEP_HEIGHT,
		upper = false,
		onClick = function() stepValue(-(row.spec and row.spec.step or 1)) end,
	})
	row.numberMinus:SetPoint("LEFT", 0, 0)

	row.numberPlus = Theme.CreateButton(row.numberBox, {
		text = "+", width = NUMBER_STEP_WIDTH, height = NUMBER_STEP_HEIGHT,
		upper = false,
		onClick = function() stepValue(row.spec and row.spec.step or 1) end,
	})
	row.numberPlus:SetPoint("RIGHT", 0, 0)

	-- Button control.
	row.button = Theme.CreateButton(row, {
		width = 110, height = 26, variant = "outline-gold",
		onClick = function()
			local spec = row.spec
			if spec and spec.onClick then spec.onClick() end
			-- Buttons whose label reflects live state (e.g. the alert
			-- preview's Preview/Hide text) need a repaint right after the
			-- click fires, since nothing else drives a refresh here.
			if row.spec == spec then CBAB.Config.RefreshRow(row) end
		end,
	})
	row.button:SetPoint("RIGHT", -16, 0)

	-- Full-width note row (Hunter pets warning): a gold dot + wrapped text,
	-- no separate label/control split.
	row.noteDot = Theme.CreateDot(row, Theme.Colors.gold, 7)
	row.noteDot:SetPoint("TOPLEFT", 16, -14)

	row.noteText = row:CreateFontString(nil, "OVERLAY")
	Theme.StyleText(row.noteText, "Body", { color = "textSecondary" })
	row.noteText:SetPoint("TOPLEFT", row.noteDot, "TOPRIGHT", 9, 4)
	row.noteText:SetPoint("RIGHT", -16, 0)
	row.noteText:SetJustifyH("LEFT")
	row.noteText:SetWordWrap(true)

	return row
end

local rowPool = {}
local function getRow(index)
	local row = rowPool[index]
	if not row then
		row = createRow()
		rowPool[index] = row
	end
	return row
end

-- Applies one row spec's data into a pooled row frame, showing only the
-- control the spec's `type` needs. Also callable standalone (see the
-- button onClick above) to repaint a single row without relaying out the
-- whole section.
function CBAB.Config.RefreshRow(row)
	local spec = row.spec
	if not spec then return end

	row.toggle:Hide()
	row.numberBox:Hide()
	row.button:Hide()
	row.noteDot:Hide()
	row.noteText:Hide()
	row.labelFS:Hide()
	row.descFS:Hide()

	if spec.type == "note" then
		row.noteDot:Show()
		row.noteText:Show()
		row.noteText:SetText(spec.text)
		return
	end

	row.labelFS:Show()
	row.labelFS:SetText(spec.label)
	if spec.desc then
		row.descFS:Show()
		row.descFS:SetText(spec.desc)
	end

	if spec.type == "toggle" then
		row.toggle:Show()
		row.toggle:SetChecked(spec.get())
	elseif spec.type == "number" then
		row.numberBox:Show()
		row.numberValueFS:SetText(("%s %s"):format(spec.get(), spec.unit or ""))
	elseif spec.type == "button" then
		row.button:Show()
		local text = spec.buttonText
		row.button.label:SetText(type(text) == "function" and text() or (text or spec.label))
	end
end

-- ============================================================
-- Sections (README "Config contents (exact rows)"). Each row is a plain
-- spec table -- get/set close over CBAB.DB so nothing here caches state
-- across a reload. `reset` restores this section's own fields from
-- CBAB.Defaults, for the footer's "Reset section" button.
-- ============================================================

CBAB.Config.Sections = {
	warnings = {
		id = "warnings", label = "Warnings", dot = Theme.Colors.red,
		subtitle = "Local alerts for your own missing assignments.",
		rows = {
			{
				type = "toggle", label = "Enabled",
				desc = "Local text + sound for your own assignments",
				get = function() return warnings().enabled end,
				set = function(v) warnings().enabled = v end,
			},
			{
				type = "number", label = "Expiring threshold", unit = "s", step = 10, min = 0,
				desc = "Seconds before a buff counts as 'expiring'",
				get = function() return warnings().threshold end,
				set = function(v) warnings().threshold = v end,
			},
			{
				type = "toggle", label = "Sound",
				get = function() return warnings().sound end,
				set = function(v) warnings().sound = v end,
			},
			{
				type = "toggle", label = "Screen text",
				get = function() return warnings().screenText end,
				set = function(v) warnings().screenText = v end,
			},
			{
				type = "toggle", label = "Whisper responsible paladin",
				desc = "Leader only · max 1 / 60s · never in combat",
				get = function() return warnings().whisper end,
				set = function(v) warnings().whisper = v end,
			},
		},
		reset = function()
			for k, v in pairs(CBAB.Defaults.char.warnings) do warnings()[k] = v end
		end,
	},
	pbar = {
		id = "pbar", label = "Paladin bar", dot = Theme.Colors.gold,
		subtitle = "Position, lock, and scale for the combat strip.",
		rows = {
			{
				type = "button", label = "Open pbar", buttonText = "Open",
				desc = "Show the combat strip if it's hidden",
				onClick = function()
					if CBAB.Bar_SetShown then CBAB.Bar_SetShown(true) end
				end,
			},
			{
				type = "toggle", label = "Show bar",
				get = function() return barUI().shown ~= false end,
				set = function(v) CBAB.Bar_SetShown(v) end,
			},
			{
				type = "toggle", label = "Locked",
				desc = "Disable dragging and resizing",
				get = function() return barUI().locked end,
				set = function(v)
					barUI().locked = v
					if CBAB.Bar_RefreshChrome then CBAB.Bar_RefreshChrome() end
				end,
			},
			{
				type = "toggle", label = "Compact",
				get = function() return barUI().compact end,
				set = function(v) barUI().compact = v end,
			},
			{
				type = "number", label = "Scale", unit = "%", step = 5, min = 50, max = 200,
				get = function() return math.floor(barUI().scale * 100) end,
				set = function(v) barUI().scale = v / 100 end,
			},
		},
		reset = function()
			local d = CBAB.Defaults.char.ui.bar
			local bar = barUI()
			bar.locked, bar.compact, bar.scale, bar.shown = d.locked, d.compact, d.scale, d.shown
			if CBAB.Bar_SetShown then CBAB.Bar_SetShown(bar.shown) end
			if CBAB.Bar_RefreshChrome then CBAB.Bar_RefreshChrome() end
		end,
	},
	alert = {
		-- README's dot table gives Alert window #43A6E6 -- the Wisdom
		-- blessing's blue, not Theme.Colors.blue (#7cc0ef, the "push/
		-- secondary" accent used for Push-to-raid) -- so this is a literal
		-- hex rather than a Theme.Colors key.
		id = "alert", label = "Alert window", dot = "#43A6E6",
		subtitle = "Popup behavior when buffs are missing or expiring.",
		rows = {
			{
				type = "button", label = "Preview alert",
				desc = "Force-show the alert window even while clean, to reposition or resize it",
				buttonText = function()
					return CBAB.Alert_IsForceShown() and "Hide preview" or "Preview"
				end,
				onClick = function()
					CBAB.Alert_SetForceShown(not CBAB.Alert_IsForceShown())
				end,
			},
			{
				type = "toggle", label = "Auto-hide when clean",
				get = function() return alertUI().autoHide end,
				set = function(v) alertUI().autoHide = v end,
			},
			{
				type = "toggle", label = "Suppress in combat",
				get = function() return alertUI().hideInCombat end,
				set = function(v) alertUI().hideInCombat = v end,
			},
			{
				type = "toggle", label = "Locked",
				desc = "Disable dragging and resizing",
				get = function() return alertUI().locked end,
				set = function(v)
					alertUI().locked = v
					if CBAB.Alert_RefreshChrome then CBAB.Alert_RefreshChrome() end
				end,
			},
			{
				type = "number", label = "X offset", unit = "px", step = 10,
				get = function() return alertUI().x end,
				set = function(v) alertUI().x = v end,
			},
			{
				type = "number", label = "Y offset", unit = "px", step = 10,
				get = function() return alertUI().y end,
				set = function(v) alertUI().y = v end,
			},
		},
		reset = function()
			local d = CBAB.Defaults.char.ui.alert
			local alert = alertUI()
			alert.autoHide, alert.hideInCombat, alert.locked, alert.x, alert.y =
				d.autoHide, d.hideInCombat, d.locked, d.x, d.y
			if CBAB.Alert_RefreshChrome then CBAB.Alert_RefreshChrome() end
		end,
	},
	pets = {
		-- README's dot table gives Hunter pets #ABD473 -- the Hunter class
		-- color, not Theme.Colors.teal (#35D0A0, the "success/live" accent).
		id = "pets", label = "Hunter pets", dot = "#ABD473",
		subtitle = "Whether hunter pets receive blessings in the plan.",
		rows = {
			{
				-- Taller than ROW_HEIGHT: this note wraps to ~3 lines at the
				-- content column's width, unlike every other row's one-line
				-- label+desc.
				type = "note", height = 78,
				text = "Saved on the active PROFILE, not this character. Changing it alters "
					.. "the plan every paladin receives on the next solve / push -- it is not "
					.. "a personal display setting.",
			},
			{
				type = "toggle", label = "Pets enabled (this profile)",
				get = function()
					local w = wants()
					return w and w.petsEnabled
				end,
				set = function(v)
					local profile = CBAB.DB:Profile()
					if profile and profile.wants then
						profile.wants.petsEnabled = v
						profile.modified = time()
					end
				end,
			},
		},
		reset = function()
			local profile = CBAB.DB:Profile()
			if profile and profile.wants then
				profile.wants.petsEnabled = CBAB.Defaults.wants.petsEnabled
				profile.modified = time()
			end
		end,
	},
	debug = {
		-- README's dot table gives Debug #8E7BE6 -- the Kings blessing's
		-- purple, not a Theme.Colors accent key.
		id = "debug", label = "Debug", dot = "#8E7BE6",
		subtitle = "Diagnostic logging for troubleshooting.",
		rows = {
			{
				type = "toggle", label = "Enabled",
				get = function() return debugUI().enabled end,
				set = function(v) debugUI().enabled = v end,
			},
			{
				type = "toggle", label = "Verbose",
				desc = "Also echo the log to chat",
				get = function() return debugUI().verbose end,
				set = function(v) debugUI().verbose = v end,
			},
		},
		reset = function()
			for k, v in pairs(CBAB.Defaults.char.debug) do debugUI()[k] = v end
		end,
	},
}

local SECTION_ORDER = { "warnings", "pbar", "alert", "pets", "debug" }

-- Fixed y-offset for the first button rather than anchoring off
-- sidebarLabel's own height -- a freshly created FontString's rendered
-- height isn't reliable to read back before the first layout pass, so this
-- uses a plain pixel constant instead (same posture as the fixed nextY
-- offsets the pre-redesign file used throughout).
local FIRST_NAV_Y = -40

for i, id in ipairs(SECTION_ORDER) do
	local section = CBAB.Config.Sections[id]
	local btn = createNavButton(section)
	if i == 1 then
		btn:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 12, FIRST_NAV_Y)
		btn:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -12, FIRST_NAV_Y)
	else
		local prev = navButtons[SECTION_ORDER[i - 1]]
		btn:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -4)
		btn:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -4)
	end
	navButtons[id] = btn
end

-- ============================================================
-- layoutSection / refreshAll / Show / Toggle
-- ============================================================

layoutSection = function(id)
	local section = CBAB.Config.Sections[id]
	if not section then return end
	currentSectionId = id

	contentTitle:SetText(section.label)
	contentSubtitle:SetText(section.subtitle or "")
	updateSidebarActive()

	local anchor
	local totalHeight = 0
	for i = 1, MAX_ROWS do
		local row = getRow(i)
		local spec = section.rows[i]
		if spec then
			local height = spec.height or ROW_HEIGHT
			row:SetHeight(height)
			row.spec = spec
			CBAB.Config.RefreshRow(row)
			row:ClearAllPoints()
			if anchor then
				row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -ROW_GAP)
				row:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -ROW_GAP)
				totalHeight = totalHeight + ROW_GAP
			else
				row:SetPoint("TOPLEFT", rowScrollChild, "TOPLEFT", 0, 0)
				row:SetPoint("TOPRIGHT", rowScrollChild, "TOPRIGHT", 0, 0)
			end
			totalHeight = totalHeight + height
			row:Show()
			anchor = row
		else
			row.spec = nil
			row:Hide()
		end
	end

	rowScrollChild:SetHeight(math.max(1, totalHeight))
end

refreshAll = function()
	layoutSection(currentSectionId or SECTION_ORDER[1])
end

function CBAB.Config:Show()
	window:Show()
	refreshAll()
end

function CBAB.Config:Toggle()
	if window:IsShown() then
		window:Hide()
	else
		self:Show()
	end
end

CBAB.SlashCommands.config = function() CBAB.Config:Toggle() end
