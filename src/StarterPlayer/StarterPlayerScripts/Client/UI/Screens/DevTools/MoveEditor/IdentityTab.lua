--!strict
--[[
	MoveEditor/IdentityTab.lua

	Owns: the Identity tab -- what the move is called, where it files, what it is for, and whether it is
	an ART: a move in a tree that players unlock, equip and pay Qi to cast (MoveTypes.MoveArtBinding).

	THE ART BLOCK IS THE ONLY WAY A CUSTOM MOVE REACHES A PLAYER. A hotbar slot can only hold an art
	(ArtSystem owns every slot), so a custom move without this block is testable from the editor and
	unreachable in play -- the readout says so in its notes. That is why the block lives on this tab,
	next to the move's name, rather than buried in a tab of mechanics.

	A Default move's identity is fixed by its place in the roster, so everything here is a fact for it.

	NOTHING HERE IS TYPED THAT COULD BE PICKED (2026-10-07). The prerequisite is chosen from the arts the
	editor knows (Fields.MovePicker), and the category offers every category already in use under its box, so
	a typo cannot quietly create a second browser group.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Copy = require(script.Parent.Copy)
local Fields = require(script.Parent.Fields)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local LIMITS = Constants.MoveEditor.Limits

local TREE_OPTIONS = {}
for _, tree in ipairs(ArtConstants.ArtTrees) do
	table.insert(TREE_OPTIONS, { Value = tree.TreeId, Text = tree.DisplayName })
end

local function IdentityTab(scope: Scope, context: Fields.FormContext, visible: UsedAs<boolean>): ScrollingFrame
	local isCustom = scope:Computed(function(use)
		return not use(context.IsDefault)
	end)
	local isArt = scope:Computed(function(use)
		local move = use(context.Draft)
		return move ~= nil and move.Art ~= nil and not use(context.IsDefault)
	end)
	local function fact(read: (MoveTypes.MoveDefinition) -> string)
		return scope:Computed(function(use)
			local move = use(context.Draft)
			return if move then read(move) else "-"
		end)
	end
	-- Every category a custom move files under, alphabetised -- the Category field's suggestions.
	local categories = scope:Computed(function(use): { string }
		local seen: { [string]: boolean } = {}
		local list: { string } = {}
		for _, entry in use(context.Entries) do
			local category = entry.Move.Category
			if entry.Source == "Custom" and category ~= "" and not seen[category] then
				seen[category] = true
				table.insert(list, category)
			end
		end
		table.sort(list)
		return list
	end)

	local function artNumber(
		label: string,
		order: number,
		field: string,
		range: { Min: number, Max: number },
		decimals: number
	)
		return Fields.Number(scope, context, {
			Label = label,
			Range = range,
			Steps = { 1 },
			Decimals = decimals,
			LayoutOrder = order,
			Visible = isArt,
			Get = function(move)
				return if move.Art then (move.Art :: any)[field] else range.Min
			end,
			Set = function(move, value)
				if move.Art then
					(move.Art :: any)[field] = if decimals == 0 then math.floor(value + 0.5) else value
				end
			end,
		})
	end

	local children: { Instance } = {
		Fields.Heading(scope, "NAME", 1),
		Fields.Text(scope, context, {
			Label = "Display name",
			MaxLength = LIMITS.DisplayNameLength,
			LayoutOrder = 2,
			Visible = isCustom,
			Get = function(move)
				return move.DisplayName
			end,
			Set = function(move, value)
				move.DisplayName = value
			end,
		}),
		Fields.Text(scope, context, {
			Label = "Category",
			Placeholder = "Signature, Experimental ...",
			MaxLength = LIMITS.CategoryLength,
			Hint = Copy.Hints.Category,
			LayoutOrder = 3,
			Visible = isCustom,
			Get = function(move)
				return move.Category
			end,
			Set = function(move, value)
				move.Category = value
			end,
			-- The categories other custom moves already file under, one press each -- so "Signature" and
			-- "signature " do not become two groups in the browser.
			Extra = {
				Fields.Suggestions(scope, context, categories, function(move)
					return move.Category
				end, function(move, value)
					move.Category = value
				end),
			},
		}),
		Fields.Text(scope, context, {
			Label = "Intent",
			Placeholder = "What is this move for?",
			MaxLength = LIMITS.DescriptionLength,
			Multiline = true,
			Hint = Copy.Hints.Description,
			LayoutOrder = 4,
			Visible = isCustom,
			Get = function(move)
				return move.Description
			end,
			Set = function(move, value)
				move.Description = value
			end,
		}),
		Fields.Fact(
			scope,
			"Name  (set by the roster)",
			fact(function(move)
				return move.DisplayName
			end),
			5,
			context.IsDefault
		),
		Fields.Fact(
			scope,
			"Move id",
			fact(function(move)
				return if move.MoveId ~= "" then move.MoveId else "assigned on first preview"
			end),
			6
		),
		Fields.Fact(
			scope,
			"Author",
			fact(function(move)
				return move.Author
			end),
			7,
			isCustom
		),

		Fields.Heading(scope, "ART", 10, isCustom),
		Fields.Prose(scope, Copy.Hints.Art, 11, isCustom),
		Fields.Toggle(scope, context, {
			Label = "This move is an art",
			LayoutOrder = 12,
			Visible = isCustom,
			Get = function(move)
				return move.Art ~= nil
			end,
			Set = function(move, on)
				if not on then
					move.Art = nil
					return
				end
				local limits = ArtConstants.Limits
				move.Art = {
					TreeId = if TREE_OPTIONS[1] then TREE_OPTIONS[1].Value else "",
					Node = limits.Node.Min,
					QiCost = limits.QiCost.Min,
					RequiredTier = limits.RequiredTier.Min,
					Prerequisite = nil,
				}
			end,
		}),
		Fields.Choice(scope, context, {
			Label = "Tree",
			Options = TREE_OPTIONS,
			LayoutOrder = 13,
			Visible = isArt,
			Get = function(move)
				return if move.Art then move.Art.TreeId else ""
			end,
			Set = function(move, value)
				if move.Art then
					move.Art.TreeId = value
				end
			end,
		}),
		artNumber("Node  (depth in the tree)", 14, "Node", ArtConstants.Limits.Node, 0),
		artNumber("Qi cost", 15, "QiCost", ArtConstants.Limits.QiCost, 0),
		artNumber("Required tier", 16, "RequiredTier", ArtConstants.Limits.RequiredTier, 0),
		Fields.MovePicker(scope, context, {
			Label = "Prerequisite",
			BlankText = "No prerequisite",
			Accepts = function(entry)
				return entry.Move.Art ~= nil
			end,
			Hint = Copy.Hints.Prerequisite,
			LayoutOrder = 17,
			Visible = isArt,
			Get = function(move)
				return if move.Art then move.Art.Prerequisite or "" else ""
			end,
			Set = function(move, value)
				if move.Art then
					move.Art.Prerequisite = if value ~= "" then value else nil
				end
			end,
		}),
	}

	return Fields.Page(scope, "IdentityTab", visible, children)
end

return IdentityTab
