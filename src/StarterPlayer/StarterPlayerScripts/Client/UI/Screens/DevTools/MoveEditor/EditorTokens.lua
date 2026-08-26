--!strict
--[[
	EditorTokens.lua

	Owns: the Move Creation System's own palette additions, taken from the Figma Make reference
	design for this screen (the "premium design" pass). Editor-scoped on purpose -- these are NOT
	added to Client/UI/Tokens.lua.

	WHY SCOPED, AND NOT GLOBAL. The reference specifies a violet chrome accent (#a080e0) very close
	to, but not identical with, Tokens.Color.AccentPrimary (#9a88c8), and Tokens.AccentPrimary is
	read by roughly every screen in the game -- HUD, onboarding, dev menu, bounty board, settings.
	Pulling the reference's value up into the global token would silently restyle all of them off
	the back of a design brief that covers one screen. If the whole game is meant to move to this
	palette that is a deliberate, separate decision; until then the two coexist and only this editor
	uses the values below.

	The phase colors are genuinely new vocabulary rather than a re-tint: the reference assigns a
	fixed meaning to each of Windup/Active/Recovery (violet/crimson/blue) and reuses those same three
	hues everywhere a phase is represented -- the frame timeline's segments, the preview's phase
	tabs, and the left border of each stat card. Defining them once here is what keeps those three
	surfaces agreeing; they were previously grey/violet/bronze in AnimationTimelineEditor.Phases,
	chosen before any of the other two surfaces existed.

	Does not own: anything already in Tokens.lua. Spacing, radii, type scale, and every non-phase
	color still come from there -- this file is additive, and a value that already has a global token
	must not be restated here.
]]

local EditorTokens = {}

-- Phase identity. Fixed meanings, reused by every surface that shows a phase (see this file's
-- header) rather than re-picked per component.
EditorTokens.Phase = {
	Windup = Color3.fromRGB(138, 116, 206),
	Active = Color3.fromRGB(192, 48, 74),
	Recovery = Color3.fromRGB(58, 110, 165),
}

-- Unsaved/dirty state. The reference turns the title-bar dot, the Save button, and the status bar
-- amber the moment a draft diverges from what is persisted -- one color for one meaning across all
-- three. Distinct from Tokens.Color.Warning (which means "this meter is in trouble") for the same
-- reason Tokens.lua's own header keeps Warning and AccentSecondary separate despite a shared
-- swatch: "there are unsaved changes" is not a warning about anything.
EditorTokens.Dirty = Color3.fromRGB(217, 164, 65)

-- Confirmation flash after a successful save -- the reference's green dot on the saved move row.
EditorTokens.Saved = Color3.fromRGB(88, 156, 118)

-- The editor's own violet chrome accent, per the reference. Deliberately a near-neighbour of
-- Tokens.Color.AccentPrimary rather than a replacement for it -- see this file's header.
EditorTokens.Accent = Color3.fromRGB(160, 128, 224)

-- The editor's own extended hue set, beyond the three phase colours above -- the vocabulary every
-- MULTI-SERIES surface here draws from (the animation timeline's clip bars, the Stats panel's
-- projected/measured plots and its per-source event scatter). File-local on purpose: callers take
-- ClipPalette or StatsSeries below, which say what a colour MEANS, rather than picking a hue by
-- name and re-deciding per surface what it stands for.
--
-- Named once here because it was previously not named at all: (150, 130, 235) was written out as a
-- literal in AnimationTimelineEditor.lua and twice more in StatsPanel.lua, byte-identical and with
-- nothing tying the three together.
local Series = {
	Violet = Color3.fromRGB(150, 130, 235),
	Teal = Color3.fromRGB(120, 200, 210),
	Amber = Color3.fromRGB(225, 170, 110),
	Rose = Color3.fromRGB(200, 130, 180),
	Green = Color3.fromRGB(140, 210, 150),
	Citron = Color3.fromRGB(210, 210, 130),
	Lilac = Color3.fromRGB(170, 160, 200),
	Coral = Color3.fromRGB(230, 140, 140),
	Mint = Color3.fromRGB(120, 210, 170),
}

-- Animation clip bars cycle through these by index, so two overlapping clips are visibly distinct
-- without the author assigning colours. Order matters (it is what clip 1 vs. clip 2 get) and the
-- list is deliberately long enough that a realistic timeline never wraps.
EditorTokens.ClipPalette = {
	Series.Violet,
	Series.Teal,
	Series.Amber,
	Series.Rose,
	Series.Green,
	Series.Citron,
	Series.Lilac,
	Series.Coral,
}

-- What each series on the Stats panel MEANS. Projected (what the move's own numbers say it will do)
-- against Measured (what a real test fire actually recorded) is the panel's central comparison, so
-- those two are the pair that has to stay maximally distinguishable; the three Source hues identify
-- which resolution stage produced an event and reuse the clip palette's own entries, since a reader
-- moving between the timeline and this panel benefits from one hue family rather than two.
EditorTokens.StatsSeries = {
	Projected = Series.Violet,
	Measured = Series.Mint,
	Primary = Series.Violet,
	ObjectStun = Series.Amber,
	FollowUp = Series.Rose,
}

-- Frames per second the frame timeline counts in. Roblox renders variably, so this is a DISPLAY
-- convention, not a simulation rate: the reference authors timing in frames ("36 FRAMES TOTAL ·
-- 0.60S AT 60FPS") while MoveDefinition stores seconds, and 60 is the divisor that makes the two
-- readings agree. Nothing in combat resolution reads this -- HitboxResolver works in seconds
-- throughout, so changing this number changes what the editor DISPLAYS and nothing about how a move
-- actually behaves.
EditorTokens.DisplayFPS = 60

-- Seconds -> whole frames at DisplayFPS, floored at 0. Rounded rather than truncated so a 0.05s
-- phase reads as 3 frames rather than 2.
function EditorTokens.ToFrames(seconds: number): number
	if typeof(seconds) ~= "number" or seconds ~= seconds then
		return 0
	end
	return math.max(0, math.round(seconds * EditorTokens.DisplayFPS))
end

return EditorTokens
