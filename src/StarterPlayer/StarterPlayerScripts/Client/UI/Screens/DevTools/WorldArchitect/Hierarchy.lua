--!strict
--[[
	WorldArchitect/Hierarchy.lua

	Owns: the Scene tab -- the managed world as a tree of groups and parts: expand and collapse groups, click to select
	(Shift adds or removes), lock and hide per row, filter by name, and the whole-scene actions (select all, deselect,
	expand / collapse all, show everything hidden).

	BOUNDED. The tree is flattened through the expanded groups only, and at most ROW_CAP rows are built; past that the
	list says how many it is not showing and asks for a filter. A six-thousand-node world therefore costs the same
	few hundred rows as a small one. Rows rebuild when the world, the expansion or the filter changes -- never on a
	selection change, which each row reads for its own highlight.

	Hide is the admin's own view (EditorViewport sets LocalTransparencyModifier on their client); it never changes what
	players see. Lock is server state -- a locked node refuses every edit until unlocked.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local Kit = require(script.Parent.Parent.DevMenu.Kit)

local Style = require(script.Parent.Style)
local WorldArchitectTypes = require(script.Parent.Types)

type Scope = Fusion.Scope<typeof(Fusion)>
type Handle = WorldArchitectTypes.Handle
type NodeRecord = WorldArchitectTypes.NodeRecord

local peek = Fusion.peek

local ROW_HEIGHT = 32
local ROW_CAP = 400
local INDENT = 14

type Row = {
	Id: string,
	Name: string,
	Kind: string,
	Depth: number,
	HasChildren: boolean,
	Expanded: boolean,
	Detail: string,
	Locked: boolean,
}

local function flatten(
	records: { [string]: NodeRecord },
	expanded: { [string]: boolean },
	query: string
): ({ Row }, number)
	local childrenOf: { [string]: { NodeRecord } } = {}
	local roots: { NodeRecord } = {}
	for _, record in records do
		if record.Parent and records[record.Parent] then
			local list = childrenOf[record.Parent] or {}
			table.insert(list, record)
			childrenOf[record.Parent] = list
		else
			table.insert(roots, record)
		end
	end
	local function byName(a: NodeRecord, b: NodeRecord): boolean
		if a.Kind ~= b.Kind then
			return a.Kind == "Group"
		end
		if a.Name ~= b.Name then
			return a.Name < b.Name
		end
		return a.Id < b.Id
	end
	local rows: { Row } = {}
	local total = 0
	local function rowOf(record: NodeRecord, depth: number): Row
		local children = childrenOf[record.Id]
		return {
			Id = record.Id,
			Name = record.Name,
			Kind = record.Kind,
			Depth = depth,
			HasChildren = children ~= nil,
			Expanded = expanded[record.Id] == true,
			Detail = if record.Kind == "Group"
				then `{if children then #children else 0}`
				else `{record.Material} · {record.Role}`,
			Locked = record.Locked,
		}
	end
	if query ~= "" then
		local needle = string.lower(query)
		local matched: { NodeRecord } = {}
		for _, record in records do
			if string.find(string.lower(record.Name), needle, 1, true) then
				table.insert(matched, record)
			end
		end
		table.sort(matched, byName)
		for _, record in matched do
			total += 1
			if #rows < ROW_CAP then
				table.insert(rows, rowOf(record, 0))
			end
		end
		return rows, total
	end
	table.sort(roots, byName)
	local function visit(record: NodeRecord, depth: number)
		total += 1
		if #rows < ROW_CAP then
			table.insert(rows, rowOf(record, depth))
		end
		if expanded[record.Id] and childrenOf[record.Id] then
			local children = childrenOf[record.Id]
			table.sort(children, byName)
			for _, child in children do
				visit(child, depth + 1)
			end
		end
	end
	for _, root in roots do
		visit(root, 0)
	end
	return rows, total
end

local function Hierarchy(scope: Scope, handle: Handle, visible: Fusion.UsedAs<boolean>): ScrollingFrame
	local query = scope:Value("")
	local flattened = scope:Computed(function(use)
		local rows, total = flatten(use(handle.Records), use(handle.Expanded), use(query))
		return { Rows = rows, Total = total }
	end)
	local rowsOnly = scope:Computed(function(use)
		return use(flattened).Rows
	end)

	local rows = scope:ForPairs(rowsOnly, function(_use, inner: Scope, index: number, row: Row)
		local selected = inner:Computed(function(use)
			return table.find(use(handle.Selection), row.Id) ~= nil
		end)
		local hidden = inner:Computed(function(use)
			return use(handle.Hidden)[row.Id] == true
		end)
		local indent = row.Depth * INDENT
		local element = inner:New "TextButton" {
			Name = "Node",
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			BackgroundColor3 = Tokens.Color.FactionCelestial,
			BackgroundTransparency = inner:Computed(function(use)
				return if use(selected) then 0.82 else 1
			end),
			AutoButtonColor = false,
			Text = "",
			LayoutOrder = index,
			[Fusion.OnEvent "Activated"] = function()
				handle.Fire({
					Kind = "SelectFromList",
					Id = row.Id,
					Additive = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
						or UserInputService:IsKeyDown(Enum.KeyCode.RightShift),
				})
			end,
			[Fusion.Children] = {
				inner:New "TextButton" {
					Name = "Chevron",
					Position = UDim2.fromOffset(indent, 0),
					Size = UDim2.fromOffset(18, ROW_HEIGHT),
					BackgroundTransparency = 1,
					Text = if row.HasChildren then (if row.Expanded then "▾" else "▸") else "",
					TextColor3 = Tokens.Color.TextSecondary,
					TextSize = 14,
					FontFace = Tokens.Type.Body.Face,
					[Fusion.OnEvent "Activated"] = function()
						if row.HasChildren then
							local expanded = table.clone(peek(handle.Expanded))
							expanded[row.Id] = not expanded[row.Id] or nil
							handle.Expanded:set(expanded)
						end
					end,
				},
				Label(inner, {
					Text = row.Name,
					Scale = if row.Kind == "Group" then "BodyLarge" else "Body",
					Color = inner:Computed(function(use)
						return if use(hidden) then Style.Quiet else Tokens.Color.TextPrimary
					end),
					Position = UDim2.fromOffset(indent + 20, 0),
					Size = UDim2.new(1, -(indent + 20 + 150), 1, 0),
					TextTruncate = Enum.TextTruncate.AtEnd,
				}),
				Label(inner, {
					Text = row.Detail,
					Scale = "Numeral",
					Color = Style.Quiet,
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, -60, 0, 0),
					Size = UDim2.fromOffset(88, ROW_HEIGHT),
					TextXAlignment = Enum.TextXAlignment.Right,
					TextTruncate = Enum.TextTruncate.AtEnd,
				}),
				inner:New "TextButton" {
					Name = "Lock",
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, -30, 0, 0),
					Size = UDim2.fromOffset(28, ROW_HEIGHT),
					BackgroundTransparency = 1,
					Text = "L",
					TextColor3 = if row.Locked then Tokens.Color.Warning else Style.Quiet,
					TextTransparency = if row.Locked then 0 else 0.5,
					TextSize = 16,
					FontFace = Tokens.Type.Abbrev.Face,
					[Fusion.OnEvent "Activated"] = function()
						handle.Fire({ Kind = "SetLocked", Ids = { row.Id }, Locked = not row.Locked })
					end,
				},
				inner:New "TextButton" {
					Name = "Hide",
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.fromScale(1, 0),
					Size = UDim2.fromOffset(28, ROW_HEIGHT),
					BackgroundTransparency = 1,
					Text = "H",
					TextColor3 = inner:Computed(function(use)
						return if use(hidden) then Tokens.Color.FactionCelestial else Style.Quiet
					end),
					TextTransparency = inner:Computed(function(use)
						return if use(hidden) then 0 else 0.5
					end),
					TextSize = 16,
					FontFace = Tokens.Type.Abbrev.Face,
					[Fusion.OnEvent "Activated"] = function()
						handle.Fire({ Kind = "SetHidden", Ids = { row.Id }, Hidden = not peek(hidden) })
					end,
				},
			},
		}
		return index, element
	end)

	local overflow = scope:Computed(function(use)
		local data = use(flattened)
		if data.Total > #data.Rows then
			return `Showing {#data.Rows} of {data.Total}. Filter by name to find the rest.`
		end
		return ""
	end)

	return Kit.Page(scope, "Scene", visible, {
		Kit.Holder(
			scope,
			"Filter",
			1,
			TextField(scope, {
				Text = query,
				PlaceholderText = "Filter by name",
				MaxLength = 48,
				Size = UDim2.new(1, 0, 0, Kit.ButtonHeight),
			})
		),
		Kit.Row(scope, 2, {
			Kit.Button(scope, {
				Text = "SELECT ALL",
				Order = 1,
				Size = Kit.Cell(2),
				OnActivated = function()
					handle.Fire({ Kind = "SelectAll" })
				end,
			}),
			Kit.Button(scope, {
				Text = "DESELECT",
				Order = 2,
				Size = Kit.Cell(2),
				OnActivated = function()
					handle.Fire({ Kind = "Deselect" })
				end,
			}),
		}),
		Kit.Row(scope, 3, {
			Kit.Button(scope, {
				Text = "EXPAND",
				Order = 1,
				Size = Kit.Cell(3),
				OnActivated = function()
					local expanded: { [string]: boolean } = {}
					for id, record in peek(handle.Records) do
						if record.Kind == "Group" then
							expanded[id] = true
						end
					end
					handle.Expanded:set(expanded)
				end,
			}),
			Kit.Button(scope, {
				Text = "COLLAPSE",
				Order = 2,
				Size = Kit.Cell(3),
				OnActivated = function()
					handle.Expanded:set({})
				end,
			}),
			Kit.Button(scope, {
				Text = "SHOW ALL",
				Order = 3,
				Size = Kit.Cell(3),
				OnActivated = function()
					handle.Fire({ Kind = "ShowAll" })
				end,
			}),
		}),
		Style.Prose(
			scope,
			"Shift-click adds to the selection. L locks a node against every edit; H hides it in your view only.",
			4
		),
		Kit.Group(scope, 5, { rows :: any }, nil, 0),
		Style.Prose(
			scope,
			overflow,
			6,
			scope:Computed(function(use)
				return use(overflow) ~= ""
			end),
			Tokens.Color.Warning
		),
	})
end

return Hierarchy
