--!strict
--[[
	Specimen.lua

	Owns: one labelled example in the Storybook -- a heading, an optional note about what the example
	is proving, and a bordered stage holding the real component.

	Every entry on every Storybook page is one of these, which is what makes adding a component to the
	gallery a five-line change instead of a layout exercise. It is also the reason the gallery reads as
	a reference rather than as a pile: the stage is the same width, the same inset and the same fill on
	every page, so two components shown side by side are genuinely comparable.

	The stage is drawn on Tokens.Color.Background, NOT on the panel's own Surface. Almost everything in
	this UI is designed to sit on Surface, so showing it on Surface would hide exactly the failure this
	gallery exists to catch -- a component that only reads against the ground it was authored over. A
	specimen that looks wrong here is telling the truth about a component that will look wrong the
	first time someone reuses it somewhere else.

	Built entirely on Components/Stack.lua and Components/Inset.lua, deliberately: the gallery is the
	first consumer of the layout primitives, so if they are awkward to use it shows up here before it
	shows up in a screen anyone ships.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Parent.Parent.Components.Inset)
local SectionHeading = require(script.Parent.Parent.Parent.Parent.Components.SectionHeading)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

export type SpecimenProps = {
	-- What the component is called. Rendered through SectionHeading, so it is a fixed noun.
	Title: string,
	-- What this particular specimen proves ("all four states", "at 0%, 40%, 100%"). Optional, and
	-- worth writing whenever the example is showing a RANGE rather than a single default.
	Note: string?,
	-- Stage height in pixels. Explicit rather than automatic: a stage that resizes itself to its
	-- contents makes two specimens on the same page different sizes, which is exactly the comparison
	-- this component exists to make possible.
	Height: number,
	-- How the examples inside the stage are arranged. Horizontal for a row of states (the common
	-- case), Vertical for anything full-width.
	Direction: ("Vertical" | "Horizontal")?,
	Gap: number?,
	-- Cross-axis alignment inside the stage. Defaults to centred, which is right for a row of chips
	-- and wrong for a full-width row -- those pass Top.
	AlignY: Enum.VerticalAlignment?,
	LayoutOrder: number,
	Children: { Instance },
}

local STAGE_INSET = Tokens.Space.M
local HEADING_HEIGHT = 24
local NOTE_HEIGHT = 18

local function Specimen(scope: Scope, props: SpecimenProps): Frame
	local body: { Instance } = {
		SectionHeading(scope, {
			Text = props.Title,
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, HEADING_HEIGHT),
		}),
	}

	if props.Note then
		table.insert(
			body,
			Label(scope, {
				Text = props.Note,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, NOTE_HEIGHT),
				LayoutOrder = 2,
			})
		)
	end

	table.insert(
		body,
		scope:New "Frame" {
			Name = "Stage",
			Size = UDim2.new(1, 0, 0, props.Height),
			LayoutOrder = 3,
			BackgroundColor3 = Tokens.Color.Background,
			BorderSizePixel = 0,
			-- A specimen that overflows its stage is a finding, not a rendering bug to let bleed into
			-- the next one down.
			ClipsDescendants = true,

			[Children] = {
				scope:New "UIStroke" {
					Color = Tokens.Border.Hairline.Color,
					Thickness = 1,
					Transparency = Tokens.Border.Hairline.Transparency,
				},
				Inset(scope, STAGE_INSET),
				Stack.New(scope, {
					Direction = props.Direction or "Horizontal",
					Gap = props.Gap or Tokens.Space.S,
					AlignY = props.AlignY or Enum.VerticalAlignment.Center,
					Children = props.Children,
				}),
			},
		}
	)

	return Stack.New(scope, {
		Name = `Specimen_{props.Title}`,
		Gap = Tokens.Space.XS,
		Size = UDim2.new(
			1,
			0,
			0,
			HEADING_HEIGHT + (if props.Note then NOTE_HEIGHT else 0) + props.Height + Tokens.Space.XS * 2
		),
		LayoutOrder = props.LayoutOrder,
		Children = body,
	})
end

return Specimen
