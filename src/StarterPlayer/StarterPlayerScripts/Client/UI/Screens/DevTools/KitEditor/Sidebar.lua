--!strict
--[[
	Sidebar.lua

	Owns: the Kit Editor's left column -- two groups, "Race Traits" and "Bloodlines", each with its
	own "+ New" action and a scrollable list of every known entry in that group. Two content types,
	one column: they share one editor screen (the Race Traits + Bloodline Abilities plan's own design),
	so a second sidebar for the second content type would just be two columns arguing over the same
	space.

	A trait/bloodline row has exactly one destructive action (Delete); identity is edited in
	PropertyEditor.lua's own Identity section, not from the list.

	Does not own: the actual Save/Delete network round trips -- OnSelectRaceTrait/OnDeleteRaceTrait/
	OnSelectBloodline/OnDeleteBloodline etc. are plain closures wired by init.lua, which is what
	forwards a request to KitEditorClient.lua (the "screen exposes state/signals, client module drives
	from outside" boundary lives one level up, same as MoveEditor's own split).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local RaceTraitTypes = require(ReplicatedStorage.Shared.Race.RaceTraitTypes)
local BloodlineTypes = require(ReplicatedStorage.Shared.Bloodline.BloodlineTypes)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Panel = require(script.Parent.Parent.Parent.Parent.Components.Panel)
local Divider = require(script.Parent.Parent.Parent.Parent.Components.Divider)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local Inset = require(script.Parent.Parent.Parent.Parent.Components.Inset)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local Sidebar = {}

export type SidebarProps = {
	RaceTraits: UsedAs<{ RaceTraitTypes.RaceTraitDefinition }>,
	Bloodlines: UsedAs<{ BloodlineTypes.BloodlineDefinition }>,
	SelectedId: UsedAs<string?>,
	OnNewRaceTrait: () -> (),
	OnNewBloodline: () -> (),
	OnSelectRaceTrait: (traitId: string) -> (),
	OnSelectBloodline: (bloodlineId: string) -> (),
	OnDeleteRaceTrait: (traitId: string) -> (),
	OnDeleteBloodline: (bloodlineId: string) -> (),
}

local ROW_HEIGHT = 36
local ROW_ACCENT_WIDTH = 4
-- How long a Delete press stays Armed before disarming itself if not confirmed -- same idea and
-- magnitude as Constants.MoveEditor.ConfirmWindowSeconds.
local DELETE_ARM_SECONDS = 3

local function row(
	scope: Scope,
	id: string,
	displayName: string,
	layoutOrder: number,
	selectedId: UsedAs<string?>,
	onSelect: () -> (),
	onDelete: () -> ()
): Frame
	local isArmed = scope:Value(false)

	local isSelected = scope:Computed(function(use)
		return use(selectedId) == id
	end)
	local backgroundColor = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Wash.AccentFill.Color else Tokens.Color.Surface
	end)
	local backgroundTransparency = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Wash.AccentFill.Transparency else 0
	end)
	local nameColor = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Color.TextPrimary else Tokens.Color.TextSecondary
	end)
	local accentColor = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Color.AccentPrimary else Tokens.Color.Background
	end)
	local deleteText = scope:Computed(function(use)
		return if use(isArmed) then "Confirm?" else "Delete"
	end)

	return scope:New "Frame" {
		Name = "Row",
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundColor3 = backgroundColor,
		BackgroundTransparency = backgroundTransparency,
		LayoutOrder = layoutOrder,

		[Children] = {
			scope:New "Frame" {
				Name = "Accent",
				Size = UDim2.new(0, ROW_ACCENT_WIDTH, 1, 0),
				BackgroundColor3 = accentColor,
				BorderSizePixel = 0,
			},
			scope:New "TextButton" {
				Name = "NameButton",
				Position = UDim2.fromOffset(ROW_ACCENT_WIDTH + Tokens.Space.S, 0),
				Size = UDim2.new(1, -(ROW_ACCENT_WIDTH + Tokens.Space.S * 2 + 70), 1, 0),
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = "",

				[OnEvent "Activated"] = onSelect,

				[Children] = Label(scope, {
					Text = if displayName ~= "" then displayName else id,
					Scale = "Body",
					Color = nameColor,
					Size = UDim2.fromScale(1, 1),
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.fromScale(0, 0.5),
				}),
			},
			Button(scope, {
				Text = deleteText,
				Size = UDim2.fromOffset(64, ROW_HEIGHT - Tokens.Space.XS),
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -Tokens.Space.XS, 0.5, 0),
				OnActivated = function()
					if peek(isArmed) then
						isArmed:set(false)
						onDelete()
						return
					end
					isArmed:set(true)
					task.delay(DELETE_ARM_SECONDS, function()
						isArmed:set(false)
					end)
				end,
			}),
		},
	} :: Frame
end

local function group(scope: Scope, title: string, layoutOrder: number, onNew: () -> (), rows: unknown): Frame
	return scope:New "Frame" {
		Name = title,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "Header",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					Label(scope, {
						Text = title,
						Scale = "Body",
						Color = Tokens.Color.TextPrimary,
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.fromScale(0, 0.5),
						Size = UDim2.fromScale(0.6, 1),
					}),
					Button(scope, {
						Text = "+ New",
						Size = UDim2.fromOffset(80, Tokens.Control.StepButtonSize),
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.fromScale(1, 0.5),
						OnActivated = onNew,
					}),
				},
			},
			scope:New "Frame" {
				Name = "Rows",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					rows,
				},
			},
		},
	} :: Frame
end

function Sidebar.Mount(scope: Scope, width: number, height: number, props: SidebarProps): Frame
	local traitRows = scope:ForPairs(
		props.RaceTraits,
		function(_use, innerScope: Scope, index: number, trait: RaceTraitTypes.RaceTraitDefinition)
			return trait.TraitId,
				row(innerScope, trait.TraitId, trait.Ability.DisplayName, index, props.SelectedId, function()
					props.OnSelectRaceTrait(trait.TraitId)
				end, function()
					props.OnDeleteRaceTrait(trait.TraitId)
				end)
		end
	)

	local bloodlineRows = scope:ForPairs(
		props.Bloodlines,
		function(_use, innerScope: Scope, index: number, bloodline: BloodlineTypes.BloodlineDefinition)
			return bloodline.BloodlineId,
				row(innerScope, bloodline.BloodlineId, bloodline.DisplayName, index, props.SelectedId, function()
					props.OnSelectBloodline(bloodline.BloodlineId)
				end, function()
					props.OnDeleteBloodline(bloodline.BloodlineId)
				end)
		end
	)

	return Panel(scope, {
		Name = "Sidebar",
		Size = UDim2.fromOffset(width, height),

		Children = {
			Inset(scope, Tokens.Space.M),
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			ScrollArea(scope, {
				Name = "Content",
				Size = UDim2.fromScale(1, 1),
				Children = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Left,
						Padding = UDim.new(0, Tokens.Space.M),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					group(scope, "Race Traits", 1, props.OnNewRaceTrait, traitRows),
					Divider.Plain(scope, { LayoutOrder = 2 }),
					group(scope, "Bloodlines", 3, props.OnNewBloodline, bloodlineRows),
				},
			}),
		},
	}) :: Frame
end

return Sidebar
