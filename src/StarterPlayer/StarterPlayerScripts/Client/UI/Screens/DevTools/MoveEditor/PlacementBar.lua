--!strict
--[[
	MoveEditor/PlacementBar.lua

	Owns: the small bar Place mode shows while the editor's modal is out of the way -- which gizmo is
	active (Move / Rotate / Resize), the snap step, where the volume is right now, and Done.

	ITS OWN SCREENGUI, NOT PART OF THE MODAL. Place mode closes the ScreenFrame so the camera and the
	cursor are free to orbit and grab a handle; a bar inside that frame would close with it. It is a
	Shell/Surface in the Overlay band -- above the HUD, below any panel the player opens -- and unscaled,
	like the other developer readouts: it draws no chrome that must agree with the dock.

	The keys are HitboxWorldPreview's (it binds them only while placing, so they cannot also fire a
	hotbar slot) and the camera controls are PlacementCamera's; this bar only lists them. Escape and
	Ctrl+Z also work here -- the legend keeps to what is particular to Place mode.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Inset = require(script.Parent.Parent.Parent.Parent.Components.Inset)
local KeyLegend = require(script.Parent.Parent.Parent.Parent.Components.KeyLegend)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Panel = require(script.Parent.Parent.Parent.Parent.Components.Panel)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local Layers = require(script.Parent.Parent.Parent.Parent.Shell.Layers)
local Surface = require(script.Parent.Parent.Parent.Parent.Shell.Surface)

type Scope = Fusion.Scope<typeof(Fusion)>

export type PlacementBarProps = {
	PlayerGui: PlayerGui,
	Active: Fusion.Value<boolean>,
	Tool: Fusion.Value<string>,
	Snap: Fusion.Value<number>,
	Draft: Fusion.Value<MoveTypes.MoveDefinition?>,
}

local TOOLS = { "Move", "Rotate", "Resize" }
-- Studs; 0 is free. Rotation snaps to PlacementMath.RotationSnapDegrees whenever this is not 0.
local SNAPS = { 0, 0.25, 0.5, 1 }

local BAR_WIDTH = 760
local BAR_HEIGHT = 96
local BUTTON_HEIGHT = Tokens.Control.StepButtonSize
-- Clears the hotbar dock beneath it.
local BOTTOM_MARGIN = 150

local function signed(value: number): string
	local text = string.gsub(string.format("%.2f", value), "^%-", "−")
	return text
end

local function PlacementBar(scope: Scope, props: PlacementBarProps): ScreenGui
	-- Legacy-path buttons (Variant nil): the selected one's text changes live, and a Variant button
	-- reads its props once.
	local function choice(text: string, order: number, isSelected: () -> boolean, onPick: () -> ()): Instance
		return Button(scope, {
			Text = scope:Computed(function(use)
				use(props.Tool)
				use(props.Snap)
				return if isSelected() then `[{text}]` else text
			end),
			Size = UDim2.fromOffset(if #text > 4 then 76 else 56, BUTTON_HEIGHT),
			LayoutOrder = order,
			OnActivated = onPick,
		})
	end

	local toolButtons: { Instance } = {}
	for index, tool in TOOLS do
		table.insert(
			toolButtons,
			choice(tool, index, function()
				return Fusion.peek(props.Tool) == tool
			end, function()
				props.Tool:set(tool)
			end)
		)
	end
	local snapButtons: { Instance } = {}
	for index, step in SNAPS do
		table.insert(
			snapButtons,
			choice(if step == 0 then "Free" else tostring(step), 10 + index, function()
				return Fusion.peek(props.Snap) == step
			end, function()
				props.Snap:set(step)
			end)
		)
	end

	local readout = scope:Computed(function(use)
		local move = use(props.Draft)
		if not move then
			return ""
		end
		local position = move.Offset.Position
		local rotation = move.OffsetRotation
		-- The form's names and signs: forward is plus (HitboxTab's FORWARD IS PLUS).
		return `right {signed(position.X)}  up {signed(position.Y)}  forward {signed(
			if position.Z == 0 then 0 else -position.Z
		)}   ·   yaw {math.floor(rotation.Y + 0.5)}°  pitch {math.floor(rotation.X + 0.5)}°  roll {math.floor(
			rotation.Z + 0.5
		)}°`
	end)

	local children: { Instance } = {}
	for _, button in toolButtons do
		table.insert(children, button)
	end
	for _, button in snapButtons do
		table.insert(children, button)
	end
	table.insert(
		children,
		Button(scope, {
			Text = "Done",
			Variant = "Primary",
			Size = UDim2.fromOffset(72, BUTTON_HEIGHT),
			LayoutOrder = 99,
			OnActivated = function()
				props.Active:set(false)
			end,
		})
	)

	return Surface.New(scope, {
		Name = "MoveEditorPlacementBar",
		Layer = Layers.Overlay,
		Parent = props.PlayerGui,
		Scaled = false,
		Enabled = props.Active,
		Children = Panel(scope, {
			Name = "Bar",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -BOTTOM_MARGIN),
			Size = UDim2.fromOffset(BAR_WIDTH, BAR_HEIGHT),
			Active = true,
			Children = {
				Inset(scope, Tokens.Space.M),
				Stack.New(scope, {
					Name = "Rows",
					Gap = Tokens.Space.S,
					Children = {
						Stack.Row(scope, {
							Name = "Controls",
							Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
							Gap = Tokens.Space.XS,
							LayoutOrder = 1,
							Children = children,
						}),
						Label(scope, {
							Text = readout,
							Scale = "NumeralSmall",
							Color = Tokens.Color.TextPrimary,
							Size = UDim2.new(1, 0, 0, Tokens.Type.NumeralSmall.Size + Tokens.Space.XS),
							LayoutOrder = 2,
						}),
						KeyLegend(scope, {
							LayoutOrder = 3,
							Entries = {
								{ Key = "1", Text = "Move" },
								{ Key = "2", Text = "Rotate" },
								{ Key = "3", Text = "Resize" },
								{ Key = "RMB", Text = "Orbit" },
								{ Key = "WASD", Text = "Pan" },
								{ Key = "Wheel", Text = "Zoom" },
								{ Key = "F", Text = "Focus" },
								{ Key = "Enter", Text = "Done" },
							},
						}),
					},
				}),
			},
		}),
	})
end

return PlacementBar
