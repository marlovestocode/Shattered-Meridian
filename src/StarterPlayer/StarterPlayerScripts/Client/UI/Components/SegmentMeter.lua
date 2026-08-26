--!strict
--[[
	SegmentMeter.lua

	Owns: the segmented progress readout -- a fixed run of discrete blocks that light up left to
	right, as distinct from Components/Bar.lua's continuous fill.

	WHY BOTH EXIST. Bar.lua answers "how full is this right now" for a quantity that slides
	continuously (health draining, a cooldown burning down) and its exact fraction is the whole
	message. A segment run answers "how far along a ladder am I", where the useful read is a countable
	number of blocks rather than a pixel width -- tier progress, which moves in visible jumps of one
	kill's worth of Meridian XP and is looked at rather than watched. Using Bar for that hides the
	step, and using this for a vital would quantize a number the player needs exactly.

	Deliberately does NOT own a critical state. Bar.lua bakes docs/ui-ux-philosophy.md's
	"never color alone" rule in via CriticalBelow because a vital emptying is an emergency; a
	progress ladder has no bad end -- being at 1/15 of the next tier is not a warning -- so there is
	no state here for a second cue to signal, and adding the prop anyway would be surface with no
	caller (the same restraint Bar.lua's own header applies to the tick marks it declined to add).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type SegmentMeterProps = {
	Value: UsedAs<number>,
	Max: UsedAs<number>,
	-- Block count. Defaults to the design's 15, which is fine enough to show a kill's worth of
	-- progress on a Tier 1 span and coarse enough to still read as countable.
	Segments: number?,
	-- The lit color. Defaults to the bronze accent -- Tokens.Color.AccentSecondary is this palette's
	-- "committed / already earned" register, which is exactly what a filled progress block means.
	FillColor: UsedAs<Color3>?,
	Size: UsedAs<UDim2>?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	LayoutOrder: UsedAs<number>?,
}

local DEFAULT_SEGMENTS = 15
local SEGMENT_GAP = 2
local DEFAULT_HEIGHT = 4

local function SegmentMeter(scope: Scope, props: SegmentMeterProps): Frame
	local segments = props.Segments or DEFAULT_SEGMENTS
	local fillColor: UsedAs<Color3> = props.FillColor or Tokens.Color.AccentSecondary
	local emptyTint = Tokens.Border.Hairline

	local fraction = scope:Computed(function(use)
		local max = use(props.Max)
		if max <= 0 then
			return 0
		end
		return math.clamp(use(props.Value) / max, 0, 1)
	end)

	local children: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, SEGMENT_GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}

	for index = 1, segments do
		-- A block lights when the fraction has passed its LEFT edge, so the first sliver of progress
		-- lights block one rather than leaving the meter looking untouched -- the design's own
		-- `i / segs < pct` test, which is what makes "0 XP into this tier" and "1 XP into this tier"
		-- visually different.
		local isLit = scope:Computed(function(use)
			return (index - 1) / segments < use(fraction)
		end)

		table.insert(
			children,
			scope:New "Frame" {
				Name = `Segment{index}`,
				LayoutOrder = index,
				-- Each block takes an equal share of the width minus its share of the inter-block gaps,
				-- so the run always ends flush with the container's right edge instead of trailing a
				-- gap's worth of dead space -- the same "anchor a fraction, correct with an offset"
				-- arithmetic Divider.Flourish's own RULE_SIZE uses.
				Size = UDim2.new(1 / segments, -SEGMENT_GAP * (segments - 1) / segments, 1, 0),
				BackgroundColor3 = scope:Computed(function(use)
					return if use(isLit) then use(fillColor) else emptyTint.Color
				end),
				BackgroundTransparency = scope:Computed(function(use)
					return if use(isLit) then 0 else emptyTint.Transparency
				end),
				BorderSizePixel = 0,

				[Children] = scope:New "UICorner" {
					-- The one place this UI softens a corner: a lit block is 4px tall, and at that
					-- size a hard rectangle reads as an artifact rather than as intent (see
					-- Tokens.Radius's own comment on exactly this case).
					CornerRadius = Tokens.Radius.Hairline,
				},
			}
		)
	end

	return scope:New "Frame" {
		Name = "SegmentMeter",
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.new(1, 0, 0, DEFAULT_HEIGHT),
		LayoutOrder = props.LayoutOrder,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,

		[Children] = children,
	} :: Frame
end

return SegmentMeter
