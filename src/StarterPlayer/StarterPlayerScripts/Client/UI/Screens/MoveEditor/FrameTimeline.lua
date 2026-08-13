--!strict
--[[
	FrameTimeline.lua

	Owns: the Timing section's hero element from the Figma Make reference -- a bordered card holding
	a header readout ("FRAME TIMELINE - 36 FRAMES TOTAL - 0.60S AT 60FPS"), a single segmented bar
	drawn to scale in the three phase colors, and a per-segment frame count beneath it (W:12 A:6
	R:18). Everything updates live off the draft, so an author dragging Windup sees the segment grow
	and every count re-read in the same frame.

	FRAMES ARE A DISPLAY UNIT, NOT A SCHEMA CHANGE. MoveDefinition stores WindupSeconds/
	ActiveSeconds/RecoverySeconds and HitboxResolver resolves in seconds end to end; this card
	converts for readability only (EditorTokens.ToFrames). Nothing here writes to the draft -- it is
	a readout, and the numeric fields below it remain the authoring surface.

	ONE BAR, NOT TWO -- and this is a deliberate departure from what this element replaced.
	PropertyEditor previously drew a second bar underneath for Cooldown, normalised to the same span,
	with a long comment explaining that cooldown is measured from the move's START so appending it as
	a fourth segment would draw an idle gap that does not exist. That reasoning is still correct, and
	it is why Cooldown is absent from this card entirely rather than being folded in as a segment:
	the reference's timeline is explicitly the MOVE's own length ("36 FRAMES TOTAL" is Windup+Active+
	Recovery, not the cooldown cycle), and Cooldown keeps its own numeric field and its own stat card
	in the preview panel. Showing it here in any form would reintroduce exactly the misreading the
	old two-bar layout existed to prevent.

	Does not own: the phase colors (EditorTokens.Phase, shared with the preview's phase tabs and the
	stat cards so all three agree), the timing values themselves (props.Draft), or any editing
	affordance.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local EditorTokens = require(script.Parent.EditorTokens)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type MoveDefinition = MoveTypes.MoveDefinition

local FrameTimeline = {}

local CARD_PADDING = Tokens.Space.M
local BAR_HEIGHT = 14
local HEADER_GAP = Tokens.Space.M
local LABEL_GAP = Tokens.Space.XS
local LABEL_HEIGHT = 14

type PhaseSpec = {
	Key: string,
	Short: string,
	Color: Color3,
	Seconds: (MoveDefinition) -> number,
}

-- Order is the order they occur in, which is also the order they are drawn -- a horizontal
-- UIListLayout renders them left to right by LayoutOrder, so the bar's reading order and the move's
-- real sequence can never diverge.
local PHASES: { PhaseSpec } = {
	{
		Key = "Windup",
		Short = "W",
		Color = EditorTokens.Phase.Windup,
		Seconds = function(d)
			return d.WindupSeconds
		end,
	},
	{
		Key = "Active",
		Short = "A",
		Color = EditorTokens.Phase.Active,
		Seconds = function(d)
			return d.ActiveSeconds
		end,
	},
	{
		Key = "Recovery",
		Short = "R",
		Color = EditorTokens.Phase.Recovery,
		Seconds = function(d)
			return d.RecoverySeconds
		end,
	},
}

local function totalSeconds(draft: MoveDefinition?): number
	if not draft then
		return 0
	end
	return draft.WindupSeconds + draft.ActiveSeconds + draft.RecoverySeconds
end

-- Builds the card. `draft` is the same Fusion state PropertyEditor already holds, passed in rather
-- than re-derived, so this element and the numeric fields below it can never disagree about what
-- move is being edited.
function FrameTimeline.Build(scope: Scope, draft: Fusion.UsedAs<MoveDefinition?>, layoutOrder: number): Frame
	-- Guarded against a zero-length move (every phase at 0, reachable while a field is mid-edit):
	-- the divisor floors at a hair above zero so a segment's fraction is 0/x rather than 0/0, which
	-- would resolve to NaN and collapse the whole bar rather than just that segment.
	local spanSeconds = scope:Computed(function(use)
		return math.max(totalSeconds(use(draft)), 0.001)
	end)

	local headerText = scope:Computed(function(use)
		local d = use(draft)
		if not d then
			return "FRAME TIMELINE"
		end
		local seconds = totalSeconds(d)
		return string.format(
			"FRAME TIMELINE  ·  %d FRAMES TOTAL  ·  %.2fS AT %dFPS",
			EditorTokens.ToFrames(seconds),
			seconds,
			EditorTokens.DisplayFPS
		)
	end)

	local segments: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	local counts: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}

	for index, phase in ipairs(PHASES) do
		-- One shared width Computed per phase, used by BOTH the colored segment and the count label
		-- beneath it. That is what keeps "W:12" centred under the windup band at every ratio -- two
		-- independently-computed widths would drift apart the moment rounding differed.
		local widthScale = scope:Computed(function(use)
			local d = use(draft)
			if not d then
				return 0
			end
			return phase.Seconds(d) / use(spanSeconds)
		end)

		table.insert(
			segments,
			scope:New "Frame" {
				Name = phase.Key .. "Segment",
				LayoutOrder = index,
				Size = scope:Computed(function(use)
					return UDim2.fromScale(use(widthScale), 1)
				end),
				BackgroundColor3 = phase.Color,
				BorderSizePixel = 0,
			}
		)

		table.insert(
			counts,
			scope:New "Frame" {
				Name = phase.Key .. "Count",
				LayoutOrder = index,
				Size = scope:Computed(function(use)
					return UDim2.new(use(widthScale), 0, 0, LABEL_HEIGHT)
				end),
				BackgroundTransparency = 1,
				-- A narrow phase's label would otherwise overflow into its neighbour's column and
				-- read as belonging to the wrong segment.
				ClipsDescendants = true,

				[Children] = Label(scope, {
					Text = scope:Computed(function(use)
						local d = use(draft)
						if not d then
							return ""
						end
						return `{phase.Short}:{EditorTokens.ToFrames(phase.Seconds(d))}`
					end),
					Scale = "NumeralSmall",
					Color = phase.Color,
					Size = UDim2.fromScale(1, 1),
					TextXAlignment = Enum.TextXAlignment.Center,
				}),
			}
		)
	end

	return scope:New "Frame" {
		Name = "FrameTimeline",
		LayoutOrder = layoutOrder,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Tokens.Color.Surface,
		BorderSizePixel = 0,

		[Children] = {
			scope:New "UIStroke" {
				Color = Tokens.Border.Standard.Color,
				Transparency = Tokens.Border.Standard.Transparency,
			},
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, CARD_PADDING),
				PaddingBottom = UDim.new(0, CARD_PADDING),
				PaddingLeft = UDim.new(0, CARD_PADDING),
				PaddingRight = UDim.new(0, CARD_PADDING),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, LABEL_GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			Label(scope, {
				Text = headerText,
				Scale = "NumeralSmall",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, LABEL_HEIGHT),
				LayoutOrder = 1,
			}),
			-- Spacer rather than a larger UIListLayout Padding: the gap belongs between the header
			-- and the bar only, not between the bar and its counts, which sit tight together.
			scope:New "Frame" {
				Name = "HeaderGap",
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, HEADER_GAP - LABEL_GAP),
				BackgroundTransparency = 1,
			},
			scope:New "Frame" {
				Name = "Bar",
				LayoutOrder = 3,
				Size = UDim2.new(1, 0, 0, BAR_HEIGHT),
				BackgroundColor3 = Tokens.Wash.TrackBase.Color,
				BackgroundTransparency = Tokens.Wash.TrackBase.Transparency,
				BorderSizePixel = 0,

				[Children] = segments,
			},
			scope:New "Frame" {
				Name = "Counts",
				LayoutOrder = 4,
				Size = UDim2.new(1, 0, 0, LABEL_HEIGHT),
				BackgroundTransparency = 1,

				[Children] = counts,
			},
		},
	} :: Frame
end

return FrameTimeline
