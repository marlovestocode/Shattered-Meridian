--!strict
--[[
	WorldArchitect/Inspector.lua

	Owns: the Inspect tab -- the selection's name, role, transform, shape, material, colour, transparency and physics
	flags, plus what can be done to a selection as a whole (duplicate, delete, group, ungroup, lock, hide, focus) and the
	arrange tools (align, distribute, mirror, uniform scale, array).

	READS THE FIRST SELECTED NODE, WRITES THE WHOLE SELECTION. Every field shows the primary node's value; a change is an
	Intent the driver applies to every selected node (a position change moves every selected item by the same offset,
	so a multi-selection keeps its layout). Only fields a role makes meaningful are offered: a group shows its pivot
	and name, never part properties it does not have.

	ROLE CHANGES APPLY THE ROLE'S PHYSICS. Picking Decor turns collision and queries off; picking Structure turns them
	back on -- the same defaults a new part of that role gets, stated in the prose under the chips.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local Dropdown = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local NumericField = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)
local Kit = require(script.Parent.Parent.DevMenu.Kit)

local Style = require(script.Parent.Style)
local WorldArchitectTypes = require(script.Parent.Types)

type Scope = Fusion.Scope<typeof(Fusion)>
type Handle = WorldArchitectTypes.Handle
type NodeRecord = WorldArchitectTypes.NodeRecord

local peek = Fusion.peek
local Limits = ArchitectConstants.Limits

-- The swatches: the starter kit's own palette, so hand-built pieces match placed templates.
local SWATCHES: { Color3 } = {
	Color3.fromRGB(104, 101, 106),
	Color3.fromRGB(74, 72, 79),
	Color3.fromRGB(40, 39, 46),
	Color3.fromRGB(70, 86, 62),
	Color3.fromRGB(84, 62, 46),
	Color3.fromRGB(58, 43, 34),
	Color3.fromRGB(112, 96, 70),
	Color3.fromRGB(84, 132, 116),
	Color3.fromRGB(96, 46, 44),
	Color3.fromRGB(150, 214, 228),
}

local function hexOf(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.round(color.R * 255),
		math.round(color.G * 255),
		math.round(color.B * 255)
	)
end

local function colorOf(hex: string): Color3?
	local r, g, b = string.match(hex, "^#?(%x%x)(%x%x)(%x%x)$")
	if r == nil then
		return nil
	end
	return Color3.fromRGB(tonumber(r, 16) :: number, tonumber(g, 16) :: number, tonumber(b, 16) :: number)
end

local function Inspector(scope: Scope, handle: Handle, visible: Fusion.UsedAs<boolean>): ScrollingFrame
	local primary = scope:Computed(function(use): NodeRecord?
		local selection = use(handle.Selection)
		local records = use(handle.Records)
		return if #selection > 0 then records[selection[1]] else nil
	end)
	local hasSelection = scope:Computed(function(use)
		return use(primary) ~= nil
	end)
	local isPart = scope:Computed(function(use)
		local record = use(primary)
		return record ~= nil and record.Kind == "Part"
	end)
	local isGroup = scope:Computed(function(use)
		local record = use(primary)
		return record ~= nil and record.Kind == "Group"
	end)
	local multi = scope:Computed(function(use)
		return #use(handle.Selection) > 1
	end)
	local three = scope:Computed(function(use)
		return #use(handle.Selection) > 2
	end)

	local function field<T>(pick: (NodeRecord) -> T, fallback: T): Fusion.Computed<T>
		return scope:Computed(function(use)
			local record = use(primary)
			return if record then pick(record) else fallback
		end)
	end

	local function patch(values: { [string]: any }): ()
		handle.Fire({ Kind = "Patch", Patch = values })
	end

	local summary = scope:Computed(function(use)
		local selection = use(handle.Selection)
		local records = use(handle.Records)
		if #selection == 0 then
			return "Nothing selected. Click a part in the world (Alt-click picks the part inside a group), or a row in Scene."
		end
		local parts, groups, locked = 0, 0, 0
		for _, id in selection do
			local record = records[id]
			if record then
				if record.Kind == "Group" then
					groups += 1
				else
					parts += 1
				end
				if record.Locked then
					locked += 1
				end
			end
		end
		local lockedText = if locked > 0 then ` · {locked} locked` else ""
		return `{#selection} selected · {parts} parts, {groups} groups{lockedText}`
	end)

	local nameText = scope:Value("")
	scope:Observer(primary):onChange(function()
		local record = peek(primary)
		nameText:set(if record then record.Name else "")
	end)

	local hexText = scope:Value("")
	scope:Observer(primary):onChange(function()
		local record = peek(primary)
		hexText:set(if record then hexOf(record.Color) else "")
	end)

	local function axisRow(
		label: string,
		fieldName: string,
		order: number,
		min: number,
		max: number,
		steps: { number },
		decimals: number
	): Instance
		local cells: { Instance } = {}
		for index, axis in { "X", "Y", "Z" } do
			table.insert(
				cells,
				NumericField.Mount(scope, {
					Label = `{label} {axis}`,
					Value = field(function(record)
						local v = (record :: any)[fieldName] :: Vector3
						return if axis == "X" then v.X elseif axis == "Y" then v.Y else v.Z
					end, 0),
					Min = min,
					Max = max,
					Steps = steps,
					Decimals = decimals,
					Slider = false,
					Compact = true,
					LayoutOrder = index,
					OnChanged = function(value: number)
						handle.Fire({ Kind = "SetAxis", Field = fieldName, Axis = axis, Value = value })
					end,
				})
			)
		end
		return Kit.Group(scope, order, cells, nil, Tokens.Space.XS)
	end

	local function flag(
		label: string,
		fieldName: string,
		order: number,
		hint: string?,
		disabled: Fusion.UsedAs<boolean>?
	): Instance
		return Kit.Holder(
			scope,
			fieldName,
			order,
			Toggle(scope, {
				Label = label,
				Value = field(function(record)
					return (record :: any)[fieldName] == true
				end, false),
				Disabled = disabled,
				Hint = hint,
				OnChanged = function(value: boolean)
					patch({ [fieldName] = value })
				end,
			}),
			isPart
		)
	end

	local swatchCells: { Instance } = {}
	for index, color in SWATCHES do
		table.insert(
			swatchCells,
			scope:New "TextButton" {
				Name = "Swatch",
				Size = UDim2.new(1 / #SWATCHES, -Tokens.Space.XS, 1, 0),
				BackgroundColor3 = color,
				AutoButtonColor = false,
				Text = "",
				LayoutOrder = index,
				[Fusion.OnEvent "Activated"] = function()
					patch({ Color = color })
				end,
			}
		)
	end

	local materialOptions: { Dropdown.DropdownOption } = {}
	for _, name in ArchitectConstants.Materials do
		table.insert(materialOptions, { Value = name, Text = name })
	end

	local roleOptions: { Kit.Option } = {}
	for _, role in ArchitectConstants.Roles do
		table.insert(roleOptions, { Value = role, Text = string.upper(role) })
	end
	local shapeOptions: { Kit.Option } = {
		{ Value = "Block", Text = "BLOCK" },
		{ Value = "Wedge", Text = "WEDGE" },
		{ Value = "CornerWedge", Text = "CORNER" },
		{ Value = "Cylinder", Text = "CYL" },
		{ Value = "Ball", Text = "BALL" },
	}

	local arrayCount = scope:Value(3)
	local arrayOffset = scope:Value(Vector3.new(8, 0, 0))

	local function button(
		text: string,
		order: number,
		count: number,
		intent: { [string]: any },
		enabled: Fusion.UsedAs<boolean>?
	): Frame
		return Kit.Button(scope, {
			Text = text,
			Order = order,
			Size = Kit.Cell(count),
			Disabled = if enabled == nil
				then nil
				else scope:Computed(function(use)
					return not use(enabled :: any)
				end),
			OnActivated = function()
				handle.Fire(table.clone(intent))
			end,
		})
	end

	local function alignRow(axis: string, order: number): Frame
		return Kit.Row(scope, order, {
			button(`{axis} MIN`, 1, 3, { Kind = "Align", Axis = axis, Mode = "Min" }),
			button(`{axis} MID`, 2, 3, { Kind = "Align", Axis = axis, Mode = "Center" }),
			button(`{axis} MAX`, 3, 3, { Kind = "Align", Axis = axis, Mode = "Max" }),
		}, multi)
	end

	return Kit.Page(scope, "Inspect", visible, {
		Style.Prose(scope, summary, 1, nil, Tokens.Color.TextSecondary),

		Kit.Heading(scope, "IDENTITY", 10, hasSelection),
		Kit.Holder(
			scope,
			"Name",
			11,
			TextField(scope, {
				Text = nameText,
				PlaceholderText = "Name",
				MaxLength = Limits.MaxNameLength,
				Size = UDim2.new(1, 0, 0, Kit.ButtonHeight),
				OnFocusLost = function(text: string)
					local record = peek(primary)
					if record and text ~= "" and text ~= record.Name then
						patch({ Name = text })
					end
				end,
			}),
			hasSelection
		),
		Kit.Segmented(scope, {
			Options = roleOptions,
			Selected = field(function(record)
				return record.Role
			end, ""),
			OnPick = function(role: string)
				handle.Fire({ Kind = "SetRole", Role = role })
			end,
			Order = 12,
			Visible = isPart,
		}),
		Style.Prose(
			scope,
			field(function(record)
				return (ArchitectConstants.RoleDescriptions :: any)[record.Role] or ""
			end, ""),
			13,
			isPart
		),

		Kit.Heading(scope, "TRANSFORM", 20, hasSelection),
		Kit.Holder(
			scope,
			"Position",
			21,
			axisRow("Position", "Position", 1, -Limits.WorldExtent, Limits.WorldExtent, { 0.5, 4 }, 2),
			hasSelection
		),
		Kit.Holder(scope, "Rotation", 22, axisRow("Rotation", "Orientation", 1, -180, 180, { 1, 15 }, 1), hasSelection),
		Kit.Holder(
			scope,
			"Size",
			23,
			axisRow("Size", "Size", 1, Limits.MinPartSize, Limits.MaxPartSize, { 0.25, 2 }, 2),
			isPart
		),

		Kit.Heading(scope, "APPEARANCE", 30, isPart),
		Kit.Segmented(scope, {
			Options = shapeOptions,
			Selected = field(function(record)
				return record.Shape
			end, ""),
			OnPick = function(shape: string)
				patch({ Shape = shape })
			end,
			Order = 31,
			Visible = isPart,
		}),
		Kit.Holder(
			scope,
			"Material",
			32,
			Dropdown.Mount(scope, {
				Label = "Material",
				Options = materialOptions,
				Value = field(function(record)
					return record.Material
				end, "Slate"),
				OnChanged = function(value: string)
					patch({ Material = value })
				end,
			}),
			isPart
		),
		Kit.Row(scope, 33, swatchCells, isPart, 24),
		Kit.Holder(
			scope,
			"Hex",
			34,
			TextField(scope, {
				Text = hexText,
				PlaceholderText = "#RRGGBB",
				MaxLength = 7,
				Size = UDim2.new(1, 0, 0, Kit.ButtonHeight),
				OnFocusLost = function(text: string)
					local color = colorOf(text)
					if color then
						patch({ Color = color })
					end
				end,
			}),
			isPart
		),
		Kit.Holder(
			scope,
			"Transparency",
			35,
			NumericField.Mount(scope, {
				Label = "Transparency",
				Value = field(function(record)
					return record.Transparency
				end, 0),
				Min = 0,
				Max = 1,
				Steps = { 0.05, 0.25 },
				Decimals = 2,
				Compact = true,
				OnChanged = function(value: number)
					patch({ Transparency = value })
				end,
			}),
			isPart
		),
		Kit.Holder(
			scope,
			"Reflectance",
			36,
			NumericField.Mount(scope, {
				Label = "Reflectance",
				Value = field(function(record)
					return record.Reflectance
				end, 0),
				Min = 0,
				Max = 1,
				Steps = { 0.05, 0.25 },
				Decimals = 2,
				Compact = true,
				OnChanged = function(value: number)
					patch({ Reflectance = value })
				end,
			}),
			isPart
		),

		Kit.Heading(scope, "PHYSICS", 40, isPart),
		flag("Anchored", "Anchored", 41, "Unanchored parts are simulated and fall."),
		flag("Collides", "CanCollide", 42, "Bodies stand on and are blocked by it."),
		flag(
			"Answers queries",
			"CanQuery",
			43,
			"Raycasts and parkour probes see it. Can only be off while it does not collide.",
			field(function(record)
				return record.CanCollide
			end, false)
		),
		flag("Fires touch events", "CanTouch", 44, "Nothing listens for touches on built parts."),
		flag("Casts shadow", "CastShadow", 45),

		Kit.Heading(scope, "SELECTION", 50, hasSelection),
		Kit.Row(scope, 51, {
			button("DUPLICATE", 1, 3, { Kind = "Duplicate" }),
			button("GROUP", 2, 3, { Kind = "Group" }),
			button("UNGROUP", 3, 3, { Kind = "Ungroup" }, isGroup),
		}, hasSelection),
		Kit.Row(scope, 52, {
			button("LOCK", 1, 4, { Kind = "SetLocked", Locked = true }),
			button("UNLOCK", 2, 4, { Kind = "SetLocked", Locked = false }),
			button("HIDE", 3, 4, { Kind = "SetHidden", Hidden = true }),
			button("FOCUS", 4, 4, { Kind = "Focus" }),
		}, hasSelection),
		Kit.Armed(scope, {
			Idle = "DELETE SELECTION",
			Armed = "CONFIRM DELETE",
			Order = 53,
			Visible = hasSelection,
			OnConfirm = function()
				handle.Fire({ Kind = "Delete" })
			end,
		}),

		Kit.Heading(scope, "ARRANGE", 60, hasSelection),
		Style.Prose(scope, "Align and distribute work on the top-level items of the selection.", 61, multi),
		alignRow("X", 62),
		alignRow("Y", 63),
		alignRow("Z", 64),
		Kit.Row(scope, 65, {
			button("SPREAD X", 1, 3, { Kind = "Distribute", Axis = "X" }, three),
			button("SPREAD Y", 2, 3, { Kind = "Distribute", Axis = "Y" }, three),
			button("SPREAD Z", 3, 3, { Kind = "Distribute", Axis = "Z" }, three),
		}, multi),
		Kit.Row(scope, 66, {
			button("MIRROR X", 1, 2, { Kind = "Mirror", Axis = "X" }),
			button("MIRROR Z", 2, 2, { Kind = "Mirror", Axis = "Z" }),
		}, hasSelection),
		Kit.Row(scope, 67, {
			button("×0.5", 1, 4, { Kind = "ScaleSet", Factor = 0.5 }),
			button("×0.9", 2, 4, { Kind = "ScaleSet", Factor = 0.9 }),
			button("×1.1", 3, 4, { Kind = "ScaleSet", Factor = 1.1 }),
			button("×2", 4, 4, { Kind = "ScaleSet", Factor = 2 }),
		}, hasSelection),
		Kit.Holder(
			scope,
			"ArrayCount",
			68,
			NumericField.Mount(scope, {
				Label = "Array copies",
				Value = arrayCount,
				Min = 1,
				Max = 50,
				Steps = { 1, 5 },
				Decimals = 0,
				Compact = true,
				OnChanged = function(value: number)
					arrayCount:set(value)
				end,
			}),
			hasSelection
		),
		Kit.Holder(
			scope,
			"ArrayOffset",
			69,
			Kit.Group(
				scope,
				1,
				(function()
					local cells: { Instance } = {}
					for index, axis in { "X", "Y", "Z" } do
						table.insert(
							cells,
							NumericField.Mount(scope, {
								Label = `Offset {axis}`,
								Value = scope:Computed(function(use)
									local v = use(arrayOffset)
									return if axis == "X" then v.X elseif axis == "Y" then v.Y else v.Z
								end),
								Min = -512,
								Max = 512,
								Steps = { 1, 8 },
								Decimals = 2,
								Slider = false,
								Compact = true,
								LayoutOrder = index,
								OnChanged = function(value: number)
									local v = peek(arrayOffset)
									arrayOffset:set(
										Vector3.new(
											if axis == "X" then value else v.X,
											if axis == "Y" then value else v.Y,
											if axis == "Z" then value else v.Z
										)
									)
								end,
							})
						)
					end
					return cells
				end)(),
				nil,
				Tokens.Space.XS
			),
			hasSelection
		),
		Kit.Button(scope, {
			Text = "MAKE ARRAY",
			Order = 70,
			Visible = hasSelection,
			OnActivated = function()
				handle.Fire({ Kind = "Array", Count = peek(arrayCount), Offset = peek(arrayOffset) })
			end,
		}),
	})
end

return Inspector
