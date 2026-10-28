--!strict
--[[
	WorldArchitect/Toolbar.lua

	Owns: the tool strip along the top of the World Architect -- the six tools (each with its number key), the snapping
	controls (grid step and turn step cycle on click; World/Local space; surface snap), and Undo / Redo labelled with
	what they will undo.

	Every chip writes a handle Value or fires an Intent; nothing here talks to the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Parent.Components.Panel)
local Tab = require(script.Parent.Parent.Parent.Parent.Components.Tab)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)

local WorldArchitectTypes = require(script.Parent.Types)

type Scope = Fusion.Scope<typeof(Fusion)>
type Handle = WorldArchitectTypes.Handle

local peek = Fusion.peek

local TOOLS: { { Id: WorldArchitectTypes.Tool, Text: string } } = {
	{ Id = "Select", Text = "1 SELECT" },
	{ Id = "Move", Text = "2 MOVE" },
	{ Id = "Rotate", Text = "3 ROTATE" },
	{ Id = "Scale", Text = "4 SCALE" },
	{ Id = "Place", Text = "5 PLACE" },
	{ Id = "Terrain", Text = "6 TERRAIN" },
}

local TOOL_WIDTH = 80
local CHIP_WIDTH = 84

local function cycle(list: { number }, current: number): number
	local index = table.find(list, current) or 0
	return list[(index % #list) + 1]
end

local function divider(scope: Scope, order: number): Frame
	return scope:New "Frame" {
		Name = "Divider",
		Size = UDim2.new(0, 1, 0.6, 0),
		BackgroundColor3 = Tokens.Border.Standard.Color,
		BackgroundTransparency = Tokens.Border.Standard.Transparency,
		BorderSizePixel = 0,
		LayoutOrder = order,
	} :: Frame
end

local function Toolbar(
	scope: Scope,
	handle: Handle,
	position: UDim2,
	height: number,
	scale: Fusion.UsedAs<number>
): Frame
	local children: { Instance } = {
		scope:New "UIPadding" {
			PaddingLeft = UDim.new(0, Tokens.Space.S),
			PaddingRight = UDim.new(0, Tokens.Space.S),
		},
	}
	local order = 0
	local function add(child: Instance)
		order += 1
		(child :: any).LayoutOrder = order
		table.insert(children, child)
	end
	local chipSize = UDim2.new(0, CHIP_WIDTH, 1, -Tokens.Space.S * 2)

	for _, tool in TOOLS do
		add(Tab(scope, {
			Text = tool.Text,
			Selected = scope:Computed(function(use)
				return use(handle.Tool) == tool.Id
			end),
			Size = UDim2.new(0, TOOL_WIDTH, 1, -Tokens.Space.S * 2),
			OnActivated = function()
				handle.Fire({ Kind = "SetTool", Tool = tool.Id })
			end,
		}))
	end
	add(divider(scope, 0))
	add(Button(scope, {
		Text = scope:Computed(function(use)
			local grid = use(handle.Grid)
			return if grid == 0 then "GRID OFF" else `GRID {grid}`
		end),
		Size = chipSize,
		OnActivated = function()
			handle.Grid:set(cycle(ArchitectConstants.Editor.GridSteps :: any, peek(handle.Grid)))
		end,
	}))
	add(Button(scope, {
		Text = scope:Computed(function(use)
			local step = use(handle.RotationStep)
			return if step == 0 then "TURN FREE" else `TURN {step}°`
		end),
		Size = chipSize,
		OnActivated = function()
			handle.RotationStep:set(cycle(ArchitectConstants.Editor.RotationSteps :: any, peek(handle.RotationStep)))
		end,
	}))
	add(Tab(scope, {
		Text = scope:Computed(function(use)
			return if use(handle.Space) == "Local" then "LOCAL" else "WORLD"
		end),
		Selected = scope:Computed(function(use)
			return use(handle.Space) == "Local"
		end),
		Size = chipSize,
		OnActivated = function()
			handle.Space:set(if peek(handle.Space) == "Local" then "World" else "Local")
		end,
	}))
	add(Tab(scope, {
		Text = "PICK PART",
		Selected = handle.DeepPick,
		Size = chipSize,
		OnActivated = function()
			handle.Fire({ Kind = "ToggleDeepPick" })
		end,
	}))
	add(Tab(scope, {
		Text = "SURFACE",
		Selected = handle.SurfaceSnap,
		Size = chipSize,
		OnActivated = function()
			handle.SurfaceSnap:set(not peek(handle.SurfaceSnap))
		end,
	}))
	add(divider(scope, 0))
	add(Button(scope, {
		Text = "UNDO",
		Size = UDim2.new(0, 72, 1, -Tokens.Space.S * 2),
		Disabled = scope:Computed(function(use)
			return use(handle.UndoLabel) == nil
		end),
		OnActivated = function()
			handle.Fire({ Kind = "Undo" })
		end,
	}))
	add(Button(scope, {
		Text = "REDO",
		Size = UDim2.new(0, 72, 1, -Tokens.Space.S * 2),
		Disabled = scope:Computed(function(use)
			return use(handle.RedoLabel) == nil
		end),
		OnActivated = function()
			handle.Fire({ Kind = "Redo" })
		end,
	}))

	return Panel(scope, {
		Name = "Toolbar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = position,
		Size = UDim2.fromOffset(0, height),
		AutomaticSize = Enum.AutomaticSize.X,
		Scale = scale,
		Active = true,
		Elevated = true,
		Children = {
			Stack.Row(scope, {
				Name = "Strip",
				Size = UDim2.fromOffset(0, height),
				AutomaticSize = Enum.AutomaticSize.X,
				Gap = Tokens.Space.XS,
				AlignY = Enum.VerticalAlignment.Center,
				Children = children,
			}),
		},
	})
end

return Toolbar
