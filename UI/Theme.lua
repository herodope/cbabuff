local ADDON, CBAB = ...

-- Shared visual design system for the redesigned UI (design handoff:
-- UI/redesign/design_handoff_cba_buff/README.md, "CBA Buff Redesign.dc.html").
-- Pure presentation helpers -- colors, fonts, panel/glow builders,
-- interaction states -- no game state, no event handling. UI/Bar.lua (and,
-- in later sessions, Roster/Config/Alert) call into this instead of
-- hand-rolling backdrops. Load order: right after Data/Spells.lua (needs
-- CBAB.Blessings' color field) and before any UI/*.lua file -- see the .toc.
--
-- Fonts: Rajdhani (headers/labels/numerics) and Barlow (body) per the
-- handoff's type scale. Ship the real families by dropping these files into
-- a Fonts/ folder next to this one:
--   Fonts/Rajdhani-Regular.ttf   (400)
--   Fonts/Rajdhani-Medium.ttf    (500)
--   Fonts/Rajdhani-SemiBold.ttf  (600)
--   Fonts/Rajdhani-Bold.ttf      (700)
--   Fonts/Barlow-Light.ttf       (300)
--   Fonts/Barlow-Regular.ttf     (400)
--   Fonts/Barlow-Medium.ttf      (500)
--   Fonts/Barlow-SemiBold.ttf    (600)
--   Fonts/Barlow-Bold.ttf        (700)
-- FontString:SetFont() returns false on a missing/bad file (Blizzard API
-- contract, not an error) -- every font object below falls back to the
-- closest stock WoW font via CopyFontObject when that happens, so the addon
-- looks right today (stock fonts) and upgrades automatically the moment the
-- real files are dropped in, no code change needed.

CBAB.Theme = {}
local Theme = CBAB.Theme

-- ============================================================
-- Color: hex <-> 0-1 RGB, and the CSS `color-mix(in srgb, A a%, B)` recipe
-- used throughout the handoff (blessing tile tinting, class header tint).
-- ============================================================

function Theme.Hex(hex)
	hex = hex:gsub("#", "")
	return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- Mixes hexA at pctA% (0-100) with hexB at the remainder -- a plain sRGB
-- lerp, matching color-mix(in srgb, ...) closely enough for tile tinting.
function Theme.MixHex(hexA, pctA, hexB)
	local ar, ag, ab = Theme.Hex(hexA)
	local br, bg, bb = Theme.Hex(hexB)
	local t = pctA / 100
	return ar * t + br * (1 - t), ag * t + bg * (1 - t), ab * t + bb * (1 - t)
end

-- ============================================================
-- Palette (design handoff README.md, "Design Tokens" -> "Core palette" /
-- "Accents" / "Text colors"). Semantic names, hex strings -- callers go
-- through Theme.Hex(Theme.Colors.x) or the convenience wrappers below.
-- ============================================================

Theme.Colors = {
	-- Bar/popup fill gradient (as rendered in the Combat Strip markup).
	barFillTop = "#161f27",
	barFillBottom = "#0f151b",
	-- Window fill gradient (Roster/Config/Alert -- later sessions).
	windowFillTop = "#0f161c",
	windowFillBottom = "#0a0e12",

	controlFill = "#141c23",
	fieldFill = "#101820",

	borderSubtle = "#1c2730",
	borderControl = "#2a3844", -- bar border, clean state
	borderControlAlt = "#33434f", -- chevron/stepper control border
	borderGaps = "#43302b", -- bar border, "gaps" state
	divider = "#28353f",
	dashedEmpty = "#2a3742",
	dashedEmptyExpanded = "#26323b",
	tileDark = "#0d1216", -- dark base tinted tiles mix into

	gold = "#E7B24C",
	goldDark = "#c8912f",
	goldText = "#f0d79a",
	goldText2 = "#f0c774",

	teal = "#35D0A0",
	tealText = "#8fb7ab",

	blue = "#7cc0ef",
	blueBorder = "#35506a",

	red = "#E1553F",
	redText = "#f0b3a8",

	textPrimary = "#f2f5f7",
	textSecondary = "#9aa6ae",
	textMuted = "#7f8b93",
	textFaint = "#5f6b73",
}

function Theme.C(name, alpha)
	local r, g, b = Theme.Hex(Theme.Colors[name])
	return r, g, b, alpha or 1
end

-- Same shape as Theme.C but for a raw hex string rather than a
-- Theme.Colors key. Needed anywhere a color call also wants a non-default
-- alpha: `f(Theme.Hex(x), a)` silently truncates to f(r, a) since
-- Theme.Hex(x) isn't the call's last argument there (Lua only expands a
-- multi-return call's full results when it IS the last argument) --
-- `f(Theme.HexA(x, a))` is a single last-argument call, so all 4 values
-- expand correctly.
function Theme.HexA(hex, alpha)
	local r, g, b = Theme.Hex(hex)
	return r, g, b, alpha or 1
end

function Theme.ClassColor(classToken)
	local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
	if c then return c.r, c.g, c.b end
	return Theme.C("textSecondary")
end

-- Fill/border/label triad for a blessing's tinted tile (README "Tinting
-- recipe"): fill mixes the blessing color at ~36% into the dark tile base,
-- border at ~55%, label text at ~60% into white.
function Theme.BlessingTint(blessingId)
	local blessing = CBAB.Blessings[blessingId]
	if not blessing or not blessing.color then return nil end
	local dark = Theme.Colors.tileDark
	return {
		fill = { Theme.MixHex(blessing.color, 36, dark) },
		border = { Theme.MixHex(blessing.color, 55, dark) },
		label = { Theme.MixHex(blessing.color, 60, "#ffffff") },
		solid = { Theme.Hex(blessing.color) },
	}
end

-- ============================================================
-- Fonts. One CreateFont() object per type-scale role (README "Type scale"),
-- built once at load. Sizes are used as-is per the handoff's "px, at 100%
-- UI scale" framing.
-- ============================================================

local FONT_DIR = "Interface\\AddOns\\" .. ADDON .. "\\Fonts\\"

local function buildFont(name, file, size, flags, fallbackObjectName)
	local font = CreateFont("CBABuffFont" .. name)
	local ok = file and font:SetFont(FONT_DIR .. file, size, flags or "")
	if not ok then
		local fallback = _G[fallbackObjectName] or GameFontNormal
		font:CopyFontObject(fallback)
		-- CopyFontObject brings the fallback's own size; re-apply the type
		-- scale's intended size on top so layout math elsewhere stays correct
		-- even before the real font files exist.
		local path, _, existingFlags = font:GetFont()
		font:SetFont(path, size, existingFlags)
	end
	return font
end

Theme.Fonts = {
	Title = buildFont("Title", "Rajdhani-Bold.ttf", 15, "", "GameFontNormal"),
	Subtitle = buildFont("Subtitle", "Rajdhani-Medium.ttf", 14, "", "GameFontNormal"),
	SectionHeader = buildFont("SectionHeader", "Rajdhani-Bold.ttf", 14, "", "GameFontNormal"),
	ColumnLabel = buildFont("ColumnLabel", "Rajdhani-SemiBold.ttf", 10.5, "", "GameFontNormalSmall"),
	Body = buildFont("Body", "Barlow-Regular.ttf", 13, "", "GameFontHighlightSmall"),
	ButtonLabel = buildFont("ButtonLabel", "Rajdhani-SemiBold.ttf", 13, "", "GameFontNormalSmall"),
	NumericValue = buildFont("NumericValue", "Rajdhani-Bold.ttf", 16, "", "GameFontNormal"),
	Name = buildFont("Name", "Rajdhani-Bold.ttf", 14, "", "GameFontNormal"),
}

-- Applies a font-object role, optional text color (a Theme.Colors key),
-- optional letter-spacing (SetLetterSpacing is a recent client addition --
-- probed defensively, same style as Core.lua's other API shims), and
-- optional forced uppercase (WoW has no text-transform equivalent).
function Theme.StyleText(fontString, fontKey, opts)
	opts = opts or {}
	local fontObj = Theme.Fonts[fontKey]
	if fontObj then fontString:SetFontObject(fontObj) end
	if opts.color then
		fontString:SetTextColor(Theme.C(opts.color, opts.alpha))
	end
	if opts.spacing and fontString.SetLetterSpacing then
		fontString:SetLetterSpacing(opts.spacing)
	end
	if opts.upper and fontString.originalSetText == nil then
		-- Wrap SetText once so callers can keep passing natural-case text
		-- (e.g. paladin names) and still get the type scale's UPPERCASE rule.
		fontString.originalSetText = fontString.SetText
		fontString.SetText = function(self, text)
			self.originalSetText(self, text and text:upper() or text)
		end
	end
end

-- ============================================================
-- Panel/backdrop helpers. WoW has no native gradient/box-shadow/rounded-
-- corner primitives; these approximate the handoff's look with plain
-- textures layered under/over a normal SetBackdrop frame, always via pcall
-- so a client-API mismatch degrades to a flat fill rather than an error
-- (same defensive posture as Core.lua's CBAB:ApplyBackdrop).
-- ============================================================

-- Vertical gradient fill sitting just inside the frame's backdrop edge.
function Theme.ApplyFill(frame, topHex, bottomHex, inset)
	inset = inset or 1
	if not frame.themeFill then
		frame.themeFill = frame:CreateTexture(nil, "BACKGROUND")
	end
	local tex = frame.themeFill
	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT", inset, -inset)
	tex:SetPoint("BOTTOMRIGHT", -inset, inset)

	local tr, tg, tb = Theme.Hex(topHex)
	local br, bg, bb = Theme.Hex(bottomHex)
	local ok = pcall(tex.SetGradientAlpha, tex, "VERTICAL", tr, tg, tb, 1, br, bg, bb, 1)
	if not ok then
		tex:SetColorTexture(tr, tg, tb, 1)
	end
	return tex
end

-- 3px top accent hairline (README: gold normally, red/teal on alert states
-- elsewhere). The CSS is a 3-stop transparent->accent->transparent
-- gradient; a flat accent bar is the cheap approximation (Fidelity note:
-- approximate rather than block on effects the API can't do).
function Theme.ApplyTopHairline(frame, hex)
	if not frame.themeHairline then
		frame.themeHairline = frame:CreateTexture(nil, "OVERLAY")
		frame.themeHairline:SetHeight(3)
	end
	local tex = frame.themeHairline
	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT", 1, -1)
	tex:SetPoint("TOPRIGHT", -1, -1)
	tex:SetColorTexture(Theme.Hex(hex))
	return tex
end

-- Soft additive-color halo approximating box-shadow/glow -- a plain color
-- texture on an ADD blend rather than a real blurred asset (no image
-- assets are available to ship in this session).
function Theme.ApplyGlow(frame, hex, opts)
	opts = opts or {}
	if not frame.themeGlow then
		frame.themeGlow = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
		frame.themeGlow:SetBlendMode("ADD")
	end
	local glow = frame.themeGlow
	local pad = opts.pad or 14
	glow:ClearAllPoints()
	glow:SetPoint("TOPLEFT", -pad, pad)
	glow:SetPoint("BOTTOMRIGHT", pad, -pad)
	glow:SetColorTexture(Theme.Hex(hex))
	glow:SetAlpha(opts.alpha or 0.12)
	return glow
end

-- Plain dark offset rectangle approximating box-shadow's drop-shadow read.
function Theme.ApplyDropShadow(frame, opts)
	opts = opts or {}
	if not frame.themeShadow then
		frame.themeShadow = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
		frame.themeShadow:SetColorTexture(0, 0, 0, 1)
	end
	local shadow = frame.themeShadow
	local pad = opts.pad or 10
	local yOffset = opts.yOffset or 6
	shadow:ClearAllPoints()
	shadow:SetPoint("TOPLEFT", -pad, pad - yOffset)
	shadow:SetPoint("BOTTOMRIGHT", pad, -pad - yOffset)
	shadow:SetAlpha(opts.alpha or 0.45)
	return shadow
end

-- Builds (once) a tinted tile look on a cell's existing backdrop + icon --
-- the blessing-tile pattern used by both the compact and expanded pbar
-- rows. `tint` is a Theme.BlessingTint() result, or nil for the empty/
-- dashed look.
function Theme.ApplyTileTint(cell, tint)
	if tint then
		cell:SetBackdropColor(tint.fill[1], tint.fill[2], tint.fill[3], 1)
		cell:SetBackdropBorderColor(tint.border[1], tint.border[2], tint.border[3], 1)
	else
		cell:SetBackdropColor(Theme.HexA(Theme.Colors.tileDark, 0.4))
		cell:SetBackdropBorderColor(Theme.HexA(Theme.Colors.dashedEmpty, 1))
	end
end

-- ============================================================
-- Interaction states (README: hover brightness(1.17), press
-- scale(.96)/brightness(.9)). Layered on top of whatever OnEnter/OnLeave a
-- caller already set via HookScript, which chains rather than replaces --
-- safe alongside e.g. Bar.lua's own popout OnEnter/OnLeave on class
-- buttons. translateY is skipped: cells here are re-anchored via
-- ClearAllPoints()/SetPoint on every refresh pass, so a stored position
-- nudge would need bookkeeping against that and isn't worth the fragility
-- for a 1px cosmetic effect.
-- ============================================================

-- `target` is usually a Texture (cell.icon) -- brightened via SetVertexColor,
-- the same >1.0-clamped-at-output trick many addons use to fake a
-- brightness boost. Frames/FontStrings have no SetVertexColor, only
-- SetAlpha, so this degrades to a subtle alpha dip instead -- still a
-- visible hover/press cue, just not the CSS brightness() approximation.
function Theme.ApplyInteractionState(frame, target)
	target = target or frame
	local function apply(mult)
		if target.SetVertexColor then
			target:SetVertexColor(mult, mult, mult)
		elseif target.SetAlpha then
			target:SetAlpha(mult >= 1 and 1 or math.max(0.6, mult))
		end
	end
	frame:HookScript("OnEnter", function() apply(1.17) end)
	frame:HookScript("OnLeave", function() apply(1) end)
	frame:HookScript("OnMouseDown", function() apply(0.9) end)
	frame:HookScript("OnMouseUp", function() apply(frame:IsMouseOver() and 1.17 or 1) end)
end
