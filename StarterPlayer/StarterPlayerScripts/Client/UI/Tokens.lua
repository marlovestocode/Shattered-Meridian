--!strict
--[[
	Tokens.lua

	Owns: the single shared design token set (colors, spacing, corner radius, type scale) for
	every UI surface -- docs/ui-ux-philosophy.md's "UI equivalent of Constants.lua." No component
	or screen should hardcode a color, spacing value, or font size that belongs here.

	Palette direction: cold blue-grey Soulslike register (Lords of the Fallen as the closest
	reference point), sharp edges, restrained ornamentation -- see docs/ui-ux-philosophy.md's
	Aesthetic direction and Color Language sections. This is locked visual identity; don't
	introduce a new hue family without revisiting that doc first.
]]

local Tokens = {}

Tokens.Color = {
	-- Backgrounds and surfaces, darkest to lightest.
	Background = Color3.fromRGB(13, 17, 23),
	Surface = Color3.fromRGB(21, 27, 36),
	SurfaceElevated = Color3.fromRGB(30, 38, 51),

	-- Borders and dividers.
	BorderSubtle = Color3.fromRGB(45, 55, 68),
	BorderAccent = Color3.fromRGB(79, 168, 216),

	-- Text.
	TextPrimary = Color3.fromRGB(232, 236, 239),
	TextSecondary = Color3.fromRGB(139, 154, 171),
	TextDisabled = Color3.fromRGB(82, 92, 102),

	-- Critical/state colors. Per docs/ui-ux-philosophy.md's Critical States rule these are never
	-- the only signal for a state change -- components pair them with a shape/motion cue (see
	-- Bar.lua/VitalIcon.lua's CriticalBelow prop for the reference implementation).
	Danger = Color3.fromRGB(176, 58, 46),
	Warning = Color3.fromRGB(199, 149, 34),
	Positive = Color3.fromRGB(74, 122, 108),

	-- Player Status vitals (docs/ui-ux-philosophy.md's Gameplay State Colors). Each vital keeps
	-- its own token even where a value happens to match a critical/state color above -- the two
	-- are different concepts (what a vital always looks like vs. what any meter looks like when
	-- critical) that shouldn't be coupled just because a hue is shared today.
	Health = Color3.fromRGB(196, 48, 56), -- crimson / blood-like
	Qi = Color3.fromRGB(163, 224, 235), -- pale cyan / frost blue
	Posture = Color3.fromRGB(199, 149, 34), -- amber / burnished gold

	-- Faction accents (world-bible.md).
	FactionCelestial = Color3.fromRGB(158, 196, 219),
	FactionDemonic = Color3.fromRGB(176, 58, 46),
	FactionUnbound = Color3.fromRGB(158, 150, 176),
}

Tokens.Space = {
	XS = 4,
	S = 8,
	M = 12,
	L = 16,
	XL = 24,
	XXL = 32,
	XXXL = 48,
}

-- Shared control-sizing tokens -- born out of Screens/DevMenu/init.lua, whose ~24 rows/buttons
-- across the Spawn/Admin/Tuning tabs each hand-typed their own literal UDim2.new/fromOffset height
-- (`0, 40` on every full-width action button and the Health/Godmode/Flight/Collide split rows; `32`
-- on every hitbox/standalone/flight-tuning stepper's "<"/">" buttons AND the value Label/Tab beside
-- them, since those need to line up on the same row height). Two different literals repeated ~23
-- times combined with zero shared name -- exactly the "UI equivalent of Constants.lua" gap this
-- file's own header warns against. Named generically (not "DevMenuRowHeight") since nothing about
-- either value is DevMenu-specific -- any future screen with the same "one action per row" or
-- "icon-button beside a value label" shape reuses these instead of re-guessing 40/32.
Tokens.Control = {
	-- Standard height for a single-row control: a full-width action button (e.g. "Spawn Training
	-- Dummy", "Reset Stage to Default") or one cell of a split row (Heal Full / Set HP to 1, the
	-- Godmode/Flight/Collide toggle trio).
	RowHeight = 40,
	-- Standard size for a small square icon/step button (hitbox/standalone/flight tuner's "<"/">"
	-- cycle buttons, the +-0.01/+-0.1 stepper buttons) -- also reused as the plain HEIGHT for the
	-- value Label/Tab sitting beside one of these buttons on the same row, so the row's contents stay
	-- vertically aligned without a separate token for "the same number, but as a height."
	StepButtonSize = 32,
	-- Horizontal clearance (offset studs) the header's target-name label reserves from the panel's
	-- right edge so its right-aligned text never sits underneath the circular close ("X") button
	-- anchored there.
	CloseButtonClearance = 36,
}

-- Fully sharp corners per docs/ui-ux-philosophy.md's Shape Language ("avoid perfect rounded
-- rectangles"). True angular/hexagonal cut corners need custom polygon geometry or image assets
-- neither of which exist in this repo yet -- see that doc's Implementation Notes for the gap.
Tokens.CornerRadius = UDim.new(0, 0)

Tokens.Type = {
	Display = { Font = Enum.Font.GothamBold, Size = 32 },
	Heading = { Font = Enum.Font.GothamBold, Size = 22 },
	Subheading = { Font = Enum.Font.GothamMedium, Size = 18 },
	Body = { Font = Enum.Font.Gotham, Size = 15 },
	Caption = { Font = Enum.Font.Gotham, Size = 12 },
}

-- Spring (scope:Spring) Speed/Damping presets -- were module-local constants duplicated across 5
-- components (AbilitySlot/LockOnReticle/VitalIcon/DamageNumberLabel/PostureBreakBanner) with no
-- shared reference point despite this file's own header calling it "the UI equivalent of
-- Constants.lua." Centralized here so a future animation-feel pass tunes one place instead of
-- hunting through 5 files; each preset keeps the exact numbers its one current caller already used,
-- named for what it's for rather than forced into a shared value just because two happened to
-- match numerically.
Tokens.Motion = {
	-- VitalIcon's hotbar fill catching up to the real value.
	FillSpring = { Speed = 20, Damping = 1 },
	-- LockOnReticle chasing a moving combat target -- snappier than a vital's fill.
	FollowSpring = { Speed = 24, Damping = 1 },
	-- AbilitySlot's edge highlight easing in/out on a state change.
	StateSpring = { Speed = 24, Damping = 1 },
	-- DamageNumberLabel's one-shot rise-and-fade. RiseOffset is the rise distance itself (pixels).
	RiseSpring = { Speed = 6, Damping = 1, RiseOffset = 34 },
	-- PostureBreakBanner/StatusBanner's one-shot entrance fade-in.
	FadeSpring = { Speed = 14, Damping = 0.7 },
	-- ParryReadyGlint's screen-edge flash -- fast, near-critically-damped so it pops in and melts
	-- out without ringing, matching the "instant acknowledgment" intent of the local parry cue.
	-- StrokeThickness/PeakTransparency are the glint's own visual-tuning siblings to Speed/Damping.
	GlintSpring = { Speed = 32, Damping = 1, StrokeThickness = 5, PeakTransparency = 0.2 },
}

return Tokens
