--!strict
--[[
	Cinematic.lua

	Owns: the intro cinematic's staged text reveals + hold-to-skip progress ring, rendered full-
	screen over the sky-facing camera OnboardingClient.lua points the real Camera at while this stage
	is active. Purely presentational -- every timing decision (which line is revealed, how far a held
	skip has progressed, when the skip hint itself becomes visible, when to actually leave this
	stage) lives in OnboardingClient.lua per this folder's "screen exposes state, client module
	drives from outside" convention (init.lua's own header); this file only renders whatever
	RevealIndex/HoldProgress/SkipHintRevealed currently say.

	No panel, no rail, no chrome at all -- per the designer's own direction, the panel's ABSENCE here
	is what gives the Origin screen's arrival weight; this stage must never gain a Panel.lua/
	CreatorFrame.lua treatment.

	CINEMATIC_LINES is real, final copy for this pass (world-bible.md's Shattering/Meridian Particle
	lore), not placeholder text -- cut from 6 lines/19s to 4 lines/~12s (designer direction) while
	preserving the same arc (the Shattering -> the fragment implanted in you -> the world doesn't
	care what you were -> the question), paced by OnboardingClient.lua's own reveal timer against
	Constants.CharacterCreation.CinematicDurationSeconds. RevealIndex is clamped defensively against
	#CINEMATIC_LINES here so a pacing mismatch degrades to "stop revealing," never an out-of-bounds
	render.

	Match cut: the last line ("What will you be?") renders at Title scale -- the same scale
	RaceSelect.lua's own header uses for its identical text -- rather than a smaller in-between size,
	so the two screens' words are stylistically continuous even though nothing here can guarantee
	PIXEL-exact position continuity across two independently, responsively laid-out screens (a real
	shared-Instance handoff would need Cinematic.lua and RaceSelect.lua to coordinate directly, which
	neither this screen nor Onboarding/init.lua's current stage-swap model supports -- see that
	module's own header on Visible toggling between stage layers). Matching scale/weight/color is the
	"nearly free" version of the beat; true pixel continuity is a larger follow-up if it's ever worth
	the coordination cost.

	The skip hint (ring + "Hold to skip") fades in via a CanvasGroup once SkipHintRevealed flips true
	(~4s in, not t=0 -- "telling the player they may leave before giving them a reason to stay is
	backwards") rather than a plain Frame, because GroupTransparency is the only way in this UI
	framework to compose that reveal-fade with the ring's OWN independent hold-brightening
	transparency without the two fighting over one property.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local OnboardingTypes = require(script.Parent.Types)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type CinematicProps = OnboardingTypes.CinematicProps

local CINEMATIC_LINES = {
	"Before the Shattering, there was one Meridian.",
	"It broke. And in breaking, it hid itself inside everything that lives.",
	"A fragment sleeps in you now, and it does not care what you were before you woke.",
	"What will you be?",
}

local function Cinematic(scope: Scope, props: CinematicProps): Frame
	local lineTransparencies: { Fusion.Computed<number> } = {}
	for index in ipairs(CINEMATIC_LINES) do
		local isRevealed = scope:Computed(function(use)
			return use(props.RevealIndex) >= index
		end)
		-- One-shot fade per line as it's revealed -- "mechanical unfolding," not an instant snap, per
		-- docs/ui-ux-philosophy.md's Animation Philosophy.
		local fadeIn = scope:Spring(
			scope:Computed(function(use)
				return if use(isRevealed) then 1 else 0
			end),
			Tokens.Motion.FadeSpring.Speed,
			Tokens.Motion.FadeSpring.Damping
		)
		lineTransparencies[index] = scope:Computed(function(use)
			return 1 - use(fadeIn)
		end)
	end

	local lineLabels: { Instance } = {}
	for index, line in ipairs(CINEMATIC_LINES) do
		table.insert(
			lineLabels,
			Label(scope, {
				Text = line,
				-- The final line ("What will you be?") is the match cut -- Title scale, the same
				-- step RaceSelect.lua's own header uses for the identical words, so the beat reads
				-- as continuous even without pixel-exact position tracking (see file header).
				Scale = if index == #CINEMATIC_LINES then "Title" else "Body",
				Color = Tokens.Color.TextPrimary,
				TextTransparency = lineTransparencies[index],
				Size = UDim2.new(1, 0, 0, if index == #CINEMATIC_LINES then 44 else 28),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = index,
			})
		)
	end

	-- Gates the WHOLE skip hint's visibility (ring + label) -- see file header on why this has to be
	-- a CanvasGroup rather than a second transparency value fighting the ring's own hold-brightening.
	local skipHintGroupTransparency = scope:Spring(
		scope:Computed(function(use)
			return if use(props.SkipHintRevealed) then 0 else 1
		end),
		Tokens.Motion.FadeSpring.Speed,
		Tokens.Motion.FadeSpring.Damping
	)

	local holdRingTransparency = scope:Computed(function(use)
		return if use(props.HoldProgress) > 0 then 0.3 else 1
	end)

	return scope:New "Frame" {
		Name = "Cinematic",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "Frame" {
				Name = "TextStack",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.42),
				Size = UDim2.fromOffset(760, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.L),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					table.unpack(lineLabels),
				},
			},

			scope:New "CanvasGroup" {
				Name = "SkipHintGroup",
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, -Tokens.Space.XXL),
				Size = UDim2.fromOffset(240, 22),
				BackgroundTransparency = 1,
				GroupTransparency = skipHintGroupTransparency,

				[Children] = {
					-- Hold-to-skip progress ring: a bottom-of-screen thin bar that fills left-to-right
					-- while the skip input is held, using the same UIStroke-thickens-under-emphasis
					-- language Bar.lua's CriticalBelow cue already establishes elsewhere in this UI.
					scope:New "Frame" {
						Name = "SkipHint",
						AnchorPoint = Vector2.new(0.5, 0),
						Position = UDim2.fromScale(0.5, 0),
						Size = UDim2.fromOffset(240, 6),
						BackgroundColor3 = Tokens.Color.Background,
						BackgroundTransparency = 0.4,
						BorderSizePixel = 0,

						[Children] = {
							scope:New "UICorner" {
								CornerRadius = Tokens.Radius.Sharp,
							},
							scope:New "UIStroke" {
								Color = Tokens.Color.AccentPrimary,
								Thickness = 1,
								Transparency = holdRingTransparency,
							},
							scope:New "Frame" {
								Name = "Fill",
								Size = scope:Computed(function(use)
									return UDim2.fromScale(use(props.HoldProgress), 1)
								end),
								BackgroundColor3 = Tokens.Color.AccentPrimary,
								BorderSizePixel = 0,

								[Children] = scope:New "UICorner" {
									CornerRadius = Tokens.Radius.Sharp,
								},
							},
						},
					},
					Label(scope, {
						Text = "Hold to skip",
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						AnchorPoint = Vector2.new(0.5, 0),
						Position = UDim2.fromOffset(0, 12),
						Size = UDim2.new(1, 0, 0, 16),
						TextXAlignment = Enum.TextXAlignment.Center,
					}),
				},
			},
		},
	} :: Frame
end

return Cinematic
