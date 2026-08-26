--!strict
--[[
	TrackedLabel.lua

	Owns: letter-spaced ("tracked") text -- the widely-spaced small caps the redesign uses for every
	label that isn't prose: step-rail labels, the CHARACTER CREATION eyebrow, archetype chips, button
	text, stat abbreviations. Renders one TextLabel per character over a horizontal UIListLayout whose
	Padding is the gap, because Roblox has no letter-spacing property and no RichText tag for one --
	this is the only mechanism that can express Tokens.Type's `Tracking` field at all.

	Scope is deliberately narrow, and the narrowness is load-bearing rather than laziness:

	- `Text` is a plain string, NOT a UsedAs<string>. The character run is composed once at build
	  time; a reactive text would have to tear down and rebuild N instances on every change, inside a
	  Fusion scope that has no mechanism for that. Same call HoverLabelProps.Text already makes, for
	  the same reason -- see that file's header.
	- No wrapping, no truncation, no alignment beyond what the parent layout gives it. A tracked run
	  is a fixed-width object.
	- Short ALL-CAPS strings only. Per-character layout costs one instance per character, which is
	  fine for "ATTRIBUTES" and absurd for a sentence. Tokens.Type only marks five steps as tracked,
	  and all five are label-shaped.

	Only the tracked steps of Tokens.Type are namable here (TrackedScale below), and Label.lua's
	LabelScale union deliberately excludes those same five. The two unions are disjoint, so under
	--!strict "tracked step rendered without tracking" and "prose rendered one letter at a time" are
	both compile errors rather than something you notice in a screenshot later.

	Spaces render as fixed-width spacer Frames rather than as space-glyph TextLabels: an
	AutomaticSize'd TextLabel containing only " " collapses to near-zero width in most faces, which
	would silently eat the word gaps in a string like "CHARACTER CREATION".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

-- The five Tokens.Type steps carrying a Tracking value. Disjoint from Label.lua's LabelScale by
-- construction -- see this file's header.
export type TrackedScale = "Micro" | "Eyebrow" | "Action" | "Chip" | "Abbrev"

export type TrackedLabelProps = {
	-- Plain string, not reactive -- see this file's header.
	Text: string,
	Scale: TrackedScale,
	Color: UsedAs<Color3>?,
	-- Applied to every character uniformly. Decorative fade only, same contract as LabelProps.
	TextTransparency: UsedAs<number>?,
	-- Native TextLabel outline, applied per character -- the same pass-through Label.lua already
	-- exposes, and for the same reason its own comment gives: text over a busy, arbitrary background
	-- (the game world, rather than a panel) has to carry its own contrast, because there is no fill
	-- behind it to do the job. A tracked caps run sat over open gameplay is exactly that case.
	StrokeColor3: UsedAs<Color3>?,
	StrokeTransparency: UsedAs<number>?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	LayoutOrder: UsedAs<number>?,
	ZIndex: UsedAs<number>?,
	-- Horizontal alignment of the character run inside this frame. The frame itself is
	-- AutomaticSize.XY, so this only matters when a caller gives it a fixed Size.
	HorizontalAlignment: Enum.HorizontalAlignment?,
	Size: UsedAs<UDim2>?,
}

-- A space's width as a fraction of the step's font size. Roughly the advance width of a space in
-- the sans/mono faces this component is used with -- exact enough for word gaps in short caps runs,
-- and not worth a TextService round trip (which would either yield or need an Enum.Font).
local SPACE_WIDTH_RATIO = 0.32

local function TrackedLabel(scope: Scope, props: TrackedLabelProps): Frame
	local scaleStep = Tokens.Type[props.Scale]
	local tracking = scaleStep.Tracking or 0

	local glyphs: { Instance } = {}
	for index = 1, #props.Text do
		local character = props.Text:sub(index, index)

		if character == " " then
			table.insert(
				glyphs,
				scope:New "Frame" {
					Name = "Space",
					Size = UDim2.fromOffset(math.round(scaleStep.Size * SPACE_WIDTH_RATIO), scaleStep.Size),
					BackgroundTransparency = 1,
					LayoutOrder = index,
				}
			)
		else
			table.insert(
				glyphs,
				scope:New "TextLabel" {
					Name = "Glyph",
					-- AutomaticSize.X so each character is exactly its own advance width; the
					-- UIListLayout's Padding below is what actually creates the tracking.
					Size = UDim2.fromOffset(0, scaleStep.Size),
					AutomaticSize = Enum.AutomaticSize.X,
					BackgroundTransparency = 1,
					LayoutOrder = index,
					Text = character,
					FontFace = scaleStep.Face,
					TextSize = scaleStep.Size,
					TextColor3 = props.Color or Tokens.Color.TextPrimary,
					TextTransparency = props.TextTransparency,
					TextStrokeColor3 = props.StrokeColor3,
					TextStrokeTransparency = props.StrokeTransparency,
					TextXAlignment = Enum.TextXAlignment.Center,
					ZIndex = props.ZIndex,
				}
			)
		end
	end

	return scope:New "Frame" {
		Name = "TrackedLabel",
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.fromOffset(0, 0),
		AutomaticSize = if props.Size then Enum.AutomaticSize.None else Enum.AutomaticSize.XY,
		LayoutOrder = props.LayoutOrder,
		BackgroundTransparency = 1,
		ZIndex = props.ZIndex,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				HorizontalAlignment = props.HorizontalAlignment or Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, tracking),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			table.unpack(glyphs),
		},
	} :: Frame
end

return TrackedLabel
