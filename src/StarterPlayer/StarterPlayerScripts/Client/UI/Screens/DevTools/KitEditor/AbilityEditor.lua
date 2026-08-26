--!strict
--[[
	AbilityEditor.lua

	Owns: the shared KitAbilityDefinition sub-form -- Id/DisplayName/Description/Kind/CooldownSeconds/
	QiCost/Effects -- reused by both a Race Trait's own single Ability field (PropertyEditor.lua) and
	a Bloodline stage's optional GrantedAbility field, rather than either hand-rolling this form a
	second time. The same anti-duplication reasoning KitTypes.lua's own header gives for sharing the
	KitAbilityDefinition shape itself extends one level up to the FORM that authors it.

	CooldownSeconds/QiCost are always shown, regardless of Kind -- KitAbilityDefinition's own header
	says a Passive entry is not required to author them as 0, it simply has them ignored at use time,
	so hiding the fields would only cost an author who switches Kind back and forth their own
	already-typed numbers for no real benefit.

	Does not own: which draft this ability belongs to, or the Effects list editor itself
	(ModifierListEditor.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local KitTypes = require(ReplicatedStorage.Shared.Kit.KitTypes)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Section = require(script.Parent.Parent.Parent.Parent.Components.Section)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local NumericField = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local Tab = require(script.Parent.Parent.Parent.Parent.Components.Tab)
local ModifierListEditor = require(script.Parent.ModifierListEditor)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local KitLimits = Constants.Kit.Limits

local AbilityEditor = {}

export type AbilityEditorProps = {
	Title: string,
	Ability: KitTypes.KitAbilityDefinition,
	OnChanged: (newAbility: KitTypes.KitAbilityDefinition) -> (),
	LayoutOrder: UsedAs<number>?,
}

local ABILITY_KINDS: { KitTypes.KitAbilityKind } = { "Passive", "Active" }

function AbilityEditor.Mount(scope: Scope, props: AbilityEditorProps): Frame
	local ability = props.Ability

	local function patch(fields: { [string]: any }): ()
		local updated = table.clone(ability) :: any
		for key, value in fields do
			updated[key] = value
		end
		props.OnChanged(updated :: KitTypes.KitAbilityDefinition)
	end

	local idText = scope:Value(ability.Id)
	local displayNameText = scope:Value(ability.DisplayName)
	local descriptionText = scope:Value(ability.Description)

	local kindTabs: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	for order, kind in ipairs(ABILITY_KINDS) do
		table.insert(
			kindTabs,
			Tab(scope, {
				Text = kind,
				Selected = ability.Kind == kind,
				Size = UDim2.fromOffset(110, Tokens.Control.StepButtonSize),
				LayoutOrder = order,
				OnActivated = function()
					patch({ Kind = kind })
				end,
			})
		)
	end

	return Section(scope, props.Title, if typeof(props.LayoutOrder) == "number" then props.LayoutOrder else 1, {
		TextField(scope, {
			Text = idText,
			PlaceholderText = "ability-id",
			MaxLength = 64,
			LayoutOrder = 1,
			OnFocusLost = function(text: string)
				patch({ Id = text })
			end,
		}),
		TextField(scope, {
			Text = displayNameText,
			PlaceholderText = "Ability Name",
			MaxLength = 64,
			LayoutOrder = 2,
			OnFocusLost = function(text: string)
				patch({ DisplayName = text })
			end,
		}),
		TextField(scope, {
			Text = descriptionText,
			PlaceholderText = "Description",
			Multiline = true,
			MaxLength = 400,
			Size = UDim2.new(1, 0, 0, 60),
			LayoutOrder = 3,
			OnFocusLost = function(text: string)
				patch({ Description = text })
			end,
		}),
		scope:New "Frame" {
			Name = "KindRow",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 4,
			[Children] = kindTabs,
		} :: Frame,
		NumericField.Mount(scope, {
			Label = "Cooldown",
			Unit = "seconds",
			Value = ability.CooldownSeconds,
			Min = KitLimits.CooldownSeconds.Min,
			Max = KitLimits.CooldownSeconds.Max,
			Steps = { 1, 5 },
			LayoutOrder = 5,
			Hint = "Only enforced for an Active ability -- ignored for a Passive one.",
			OnChanged = function(newValue: number)
				patch({ CooldownSeconds = newValue })
			end,
		}),
		NumericField.Mount(scope, {
			Label = "Qi Cost",
			Value = ability.QiCost,
			Min = KitLimits.QiCost.Min,
			Max = KitLimits.QiCost.Max,
			Steps = { 5, 25 },
			LayoutOrder = 6,
			OnChanged = function(newValue: number)
				patch({ QiCost = newValue })
			end,
		}),
		ModifierListEditor.Mount(scope, {
			Effects = ability.Effects,
			LayoutOrder = 7,
			OnChanged = function(newEffects)
				patch({ Effects = newEffects })
			end,
		}),
	}, "What this ability grants, and what it costs to use.")
end

return AbilityEditor
