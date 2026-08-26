--!strict
--[[
	PrimitivePage.lua

	Owns: the Storybook page that proves the layout primitives actually do what their headers claim.

	THIS PAGE EXISTS BECAUSE THE TEST SUITE CANNOT ANSWER THE QUESTION. src/Tests/UI/
	LayoutPrimitives.spec.lua asserts that UIFlexItem exists, that Fill is a real FlexMode, and that
	Stack.Fill attaches one -- all of which are structural facts a headless place can check. What it
	cannot check is whether the fill child actually CLAIMS the leftover space, because a server place
	has no render pipeline and AbsoluteSize never resolves. That is a question for eyes, and this is
	where the eyes go.

	So the specimens here are not decoration. The two Stack.Fill stages are deliberately different
	heights with identical children: if Fill works, the accented row is visibly taller in the first
	and shorter in the second, and every fixed row is the same size in both. If Fill silently does
	nothing, both accented rows collapse to zero and the failure is obvious at a glance rather than
	three screens later in a shipped menu.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)
local Layer = require(script.Parent.Parent.Parent.Components.Layer)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)
local StatusTag = require(script.Parent.Parent.Parent.Components.StatusTag)
local MeridianField = require(script.Parent.Parent.Parent.Components.MeridianField)

local Specimen = require(script.Parent.Specimen)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

-- One labelled band inside a Stack demo. `height` nil means "this is the fill child" -- it gets a
-- scale-1 height that the flex item then overrides, and the accent fill so it is unmistakable.
local function band(scope: Scope, text: string, height: number?, layoutOrder: number): Frame
	local isFill = height == nil
	return scope:New "Frame" {
		Name = if isFill then "FillBand" else `Band{layoutOrder}`,
		Size = if isFill then UDim2.fromScale(1, 1) else UDim2.new(1, 0, 0, height :: number),
		LayoutOrder = layoutOrder,
		BackgroundColor3 = if isFill then Tokens.Color.AccentPrimary else Tokens.Color.SurfaceElevated,
		BackgroundTransparency = if isFill then 0.72 else 0,
		BorderSizePixel = 0,

		[Children] = {
			scope:New "UIStroke" {
				Color = if isFill then Tokens.Color.AccentPrimary else Tokens.Border.Hairline.Color,
				Thickness = 1,
				Transparency = if isFill then 0.4 else Tokens.Border.Hairline.Transparency,
			},
			Inset(scope, { X = Tokens.Space.S }),
			Label(scope, {
				Text = text,
				Scale = "Detail",
				Color = if isFill then Tokens.Color.AccentPrimaryBright else Tokens.Color.TextSecondary,
				Size = UDim2.fromScale(1, 1),
			}),
		},
	} :: Frame
end

-- One Stack.Fill stage: three fixed bands and one that absorbs the remainder, in a container of the
-- given height. Two of these at different heights is the whole proof.
local function fillStage(scope: Scope, containerHeight: number, layoutOrder: number): Frame
	return scope:New "Frame" {
		Name = `FillStage{containerHeight}`,
		Size = UDim2.new(0.5, -Tokens.Space.S / 2, 0, containerHeight),
		LayoutOrder = layoutOrder,
		BackgroundTransparency = 1,

		[Children] = Stack.New(scope, {
			Gap = Tokens.Space.XS,
			Children = {
				band(scope, `container {containerHeight}px`, 22, 1),
				band(scope, "fixed 30", 30, 2),
				Stack.Fill(scope, band(scope, "Stack.Fill", nil, 3)),
				band(scope, "fixed 22", 22, 4),
			},
		}),
	} :: Frame
end

-- One inset example: a box with the given padding and a filled child, captioned with the literal
-- spec that produced it -- so the caption IS the call site, not a description of one.
local function insetBox(scope: Scope, caption: string, spec: Inset.InsetSpec, layoutOrder: number): Frame
	return Stack.New(scope, {
		Gap = Tokens.Space.XS,
		Size = UDim2.fromOffset(150, 80),
		LayoutOrder = layoutOrder,
		Children = {
			scope:New "Frame" {
				Name = "Box",
				Size = UDim2.new(1, 0, 0, 56),
				LayoutOrder = 1,
				BackgroundColor3 = Tokens.Color.SurfaceElevated,
				BorderSizePixel = 0,

				[Children] = {
					Inset(scope, spec),
					scope:New "Frame" {
						Name = "Fill",
						Size = UDim2.fromScale(1, 1),
						BackgroundColor3 = Tokens.Color.AccentPrimary,
						BackgroundTransparency = 0.6,
						BorderSizePixel = 0,
					},
				},
			},
			Label(scope, {
				Text = caption,
				Scale = "NumeralSmall",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, 16),
				LayoutOrder = 2,
			}),
		},
	})
end

local function PrimitivePage(scope: Scope, layoutOrder: number, visible: Fusion.UsedAs<boolean>, width: number): Frame
	local entries: { Instance } = {
		Specimen(scope, {
			Title = "Stack.Fill",
			Note = "Same four children, two container heights. Only the accented band changes size.",
			Height = 200,
			AlignY = Enum.VerticalAlignment.Top,
			LayoutOrder = 1,
			Children = {
				fillStage(scope, 176, 1),
				fillStage(scope, 120, 2),
			},
		}),

		Specimen(scope, {
			Title = "Layer",
			Note = "The rule and the corner marker are in Over -- the row's layout never touches them.",
			Height = 96,
			AlignY = Enum.VerticalAlignment.Top,
			LayoutOrder = 2,
			Children = {
				Layer(scope, {
					Size = UDim2.new(1, 0, 0, 72),
					BackgroundColor3 = Tokens.Color.Surface,
					BackgroundTransparency = 0,
					Under = {
						MeridianField(scope, { ZIndex = 1, Intensity = 1.6 }),
					},
					Content = Stack.Row(scope, {
						Gap = Tokens.Space.S,
						AlignY = Enum.VerticalAlignment.Center,
						Children = {
							Inset(scope, { X = Tokens.Space.M }),
							StatusTag(scope, { Label = "Flow", Color = Tokens.Color.AccentPrimary, Tracked = true }),
							StatusTag(scope, { Label = "Arranged", Tracked = true }),
							StatusTag(scope, { Label = "By a layout", Tracked = true }),
						},
					}),
					Over = {
						-- Anchored to the container's own bottom edge. In a plain Stack this would be
						-- swept into the chip row as a fourth item -- see Layer.lua's header.
						scope:New "Frame" {
							Name = "ClosingRule",
							AnchorPoint = Vector2.new(0, 1),
							Position = UDim2.fromScale(0, 1),
							Size = UDim2.new(1, 0, 0, 2),
							BackgroundColor3 = Tokens.Color.AccentSecondary,
							BorderSizePixel = 0,
						},
						scope:New "Frame" {
							Name = "CornerMarker",
							AnchorPoint = Vector2.new(1, 0),
							Position = UDim2.fromScale(1, 0),
							Size = UDim2.fromOffset(10, 10),
							Rotation = 45,
							BackgroundColor3 = Tokens.VitalColor.Qi,
							BorderSizePixel = 0,
						},
					},
				}),
			},
		}),

		Specimen(scope, {
			Title = "Inset",
			Note = "Uniform, axis shorthand, and a named side overriding the axis it belongs to.",
			Height = 104,
			LayoutOrder = 3,
			Children = {
				insetBox(scope, "16", 16, 1),
				insetBox(scope, "{ X = 24 }", { X = 24 }, 2),
				insetBox(scope, "{ X = 16, Right = 0 }", { X = 16, Right = 0 }, 3),
			},
		}),
	}

	return Stack.New(scope, {
		Name = "PrimitivePage",
		Gap = Tokens.Space.L,
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder,
		Visible = visible,
		Children = entries,
	})
end

return PrimitivePage
