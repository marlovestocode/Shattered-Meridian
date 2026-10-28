--!strict
--[[
	WorldArchitect/TerrainPanel.lua

	Owns: the Terrain tab -- the brush's mode, material, radius and strength, and how to use it. The strokes themselves
	are made in the world with the Terrain tool (EditorViewport); this tab only sets what a stroke will be.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)

local Dropdown = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local NumericField = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local Kit = require(script.Parent.Parent.DevMenu.Kit)

local Style = require(script.Parent.Style)
local WorldArchitectTypes = require(script.Parent.Types)

type Scope = Fusion.Scope<typeof(Fusion)>
type Handle = WorldArchitectTypes.Handle

local peek = Fusion.peek
local Terrain = ArchitectConstants.Terrain

local MODE_HELP: { [string]: string } = {
	Add = "Adds a ball of the material where you click.",
	Subtract = "Carves a ball out of the terrain.",
	Flatten = "Levels a disc at the height of the point you click: fills below, clears above.",
	Smooth = "Softens the surface inside the brush.",
	Paint = "Changes the material of terrain inside the brush; the shape stays.",
}

local function TerrainPanel(scope: Scope, handle: Handle, visible: Fusion.UsedAs<boolean>): ScrollingFrame
	local function setting<T>(key: string): Fusion.Computed<T>
		return scope:Computed(function(use)
			return (use(handle.Terrain) :: any)[key]
		end)
	end
	local function set(key: string, value: any): ()
		local updated = table.clone(peek(handle.Terrain)) :: any
		updated[key] = value
		handle.Terrain:set(updated)
	end

	local modeOptions: { Kit.Option } = {}
	for _, mode in Terrain.Modes do
		table.insert(modeOptions, { Value = mode, Text = string.upper(mode) })
	end
	local materialOptions: { Dropdown.DropdownOption } = {}
	for _, name in ArchitectConstants.TerrainMaterials do
		table.insert(materialOptions, { Value = name, Text = name })
	end

	return Kit.Page(scope, "Terrain", visible, {
		Kit.Button(scope, {
			Text = "USE TERRAIN BRUSH (6)",
			Order = 1,
			OnActivated = function()
				handle.Fire({ Kind = "SetTool", Tool = "Terrain" })
			end,
		}),
		Kit.Heading(scope, "BRUSH", 2),
		Kit.Segmented(scope, {
			Options = modeOptions,
			Selected = setting("Mode"),
			OnPick = function(mode: string)
				set("Mode", mode)
			end,
			Order = 3,
		}),
		Style.Prose(
			scope,
			scope:Computed(function(use)
				return MODE_HELP[use(handle.Terrain).Mode] or ""
			end),
			4
		),
		Kit.Holder(
			scope,
			"Material",
			5,
			Dropdown.Mount(scope, {
				Label = "Material",
				Options = materialOptions,
				Value = setting("Material"),
				OnChanged = function(value: string)
					set("Material", value)
				end,
			})
		),
		Kit.Holder(
			scope,
			"Radius",
			6,
			NumericField.Mount(scope, {
				Label = "Radius",
				Value = setting("Radius"),
				Min = Terrain.MinRadius,
				Max = Terrain.MaxRadius,
				Steps = { 1, 4 },
				Decimals = 0,
				Unit = "studs",
				Compact = true,
				OnChanged = function(value: number)
					set("Radius", value)
				end,
			})
		),
		Kit.Holder(
			scope,
			"Strength",
			7,
			NumericField.Mount(scope, {
				Label = "Strength",
				Value = setting("Strength"),
				Min = 0.05,
				Max = 1,
				Steps = { 0.05, 0.25 },
				Decimals = 2,
				Compact = true,
				OnChanged = function(value: number)
					set("Strength", value)
				end,
			})
		),
		Kit.Heading(scope, "USE", 10),
		Style.Prose(
			scope,
			"With the Terrain tool, click the ground to stroke; hold and drag to keep stroking. "
				.. "Each stroke is bounded by the brush, refused inside a protected area, and undoable "
				.. "while no later stroke overlaps it. Strokes are saved with the world and replayed when it loads.",
			11
		),
	})
end

return TerrainPanel
