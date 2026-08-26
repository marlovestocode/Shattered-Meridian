--!strict
--[[
	ModifierListEditor.lua

	Owns: the repeatable editor for a { Types.ActiveModifierSpec } array -- the one control both
	AbilityEditor.lua's Effects field and a Bloodline stage's own PassiveEffects field reuse, rather
	than each hand-rolling its own effects list (the same anti-duplication reasoning KitTypes.lua's
	own header gives for sharing KitAbilityDefinition itself). Named to avoid colliding with the
	existing, unrelated MoveEditor/EffectsEditor.lua (that file edits a MoveDefinition's Movement/
	Knockback/Grab/Projectile sub-tables; this one edits a generic modifier spec list).

	One row per effect: Kind (AttributeDelta/Tag/QiRestore), Lifetime (Instant/Timed/Bound), then
	exactly the fields Types.ActiveModifierSpec's own header says are meaningful for the chosen Kind/
	Lifetime -- the same "only render what the current selection actually reads" rule NumericField's
	own Visible prop already serves elsewhere in this editor family. A field the current Kind/Lifetime
	doesn't use is left on the underlying spec table (KitValidation.lua's own server-side Validate is
	what actually drops it), not cleared here -- switching Kind and back keeps whatever numbers were
	last typed rather than silently discarding them.

	Reactivity: scope:ForPairs keyed by array INDEX (an ActiveModifierSpec has no id of its own to key
	by) -- see MoveEditor/MoveList.lua's own header for why ForPairs, not ForValues, is this
	codebase's dynamic-list primitive. Every edit replaces the WHOLE array via props.OnChanged (add,
	remove, or patch one entry) -- there is no in-place mutation, matching PropertyEditor.lua's own
	"clone the current draft, mutate the one field that changed" convention one level up.

	Does not own: which draft (Race Trait Ability, Bloodline stage PassiveEffects/GrantedAbility.
	Effects) this list belongs to -- the caller supplies the array and receives the replacement.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Parent.Components.Tab)
local TextField = require(script.Parent.Parent.Parent.Components.TextField)
local NumericField = require(script.Parent.Parent.Parent.Components.NumericField)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local KitLimits = Constants.Kit.Limits

local ModifierListEditor = {}

export type ModifierListEditorProps = {
	Effects: UsedAs<{ Types.ActiveModifierSpec }>,
	OnChanged: (newEffects: { Types.ActiveModifierSpec }) -> (),
	LayoutOrder: UsedAs<number>?,
}

local MODIFIER_KINDS: { Types.ActiveModifierKind } = { "AttributeDelta", "Tag", "QiRestore" }
local MODIFIER_LIFETIMES: { Types.ActiveModifierLifetime } = { "Instant", "Timed", "Bound" }
local ATTRIBUTE_KEYS: { Types.ActiveModifierAttributeKey } =
	{ "Vitality", "Fortitude", "MeridianFlow", "Might", "Pressure", "Fleetness" }

local function defaultSpec(): Types.ActiveModifierSpec
	return { Kind = "AttributeDelta", Lifetime = "Bound", AttributeKey = "Vitality", Delta = 0 }
end

-- Replaces index `index` of `current` with `updated`, returning a fresh array (Fusion.Value
-- reactivity, same "always a new top-level array" rule MoveEditor/init.lua's patchMovesDisplay
-- already follows).
local function replaceAt(
	current: { Types.ActiveModifierSpec },
	index: number,
	updated: Types.ActiveModifierSpec?
): { Types.ActiveModifierSpec }
	local newList: { Types.ActiveModifierSpec } = {}
	for entryIndex, entry in ipairs(current) do
		if entryIndex == index then
			if updated then
				table.insert(newList, updated)
			end
		else
			table.insert(newList, entry)
		end
	end
	return newList
end

-- Narrower than Tab.lua's own 120px default -- these rows pack up to six tabs ("AttributeDelta",
-- "Fortitude", ...) side by side inside a form column, and every label here is short enough to fit.
local TAB_WIDTH = 110

local function tabRow(
	scope: Scope,
	layoutOrder: number,
	tabs: { { Text: string, Selected: boolean, OnActivated: () -> () } }
): Frame
	local children: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	for order, tab in ipairs(tabs) do
		table.insert(
			children,
			Tab(scope, {
				Text = tab.Text,
				Selected = tab.Selected,
				Size = UDim2.fromOffset(TAB_WIDTH, Tokens.Control.StepButtonSize),
				LayoutOrder = order,
				OnActivated = tab.OnActivated,
			})
		)
	end
	return scope:New "Frame" {
		Name = "TabRow",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,
		[Children] = children,
	} :: Frame
end

local function effectRow(
	scope: Scope,
	effect: Types.ActiveModifierSpec,
	index: number,
	onChange: (Types.ActiveModifierSpec) -> (),
	onRemove: () -> ()
): Frame
	local function patch(fields: { [string]: any }): ()
		local updated = table.clone(effect) :: any
		for key, value in fields do
			updated[key] = value
		end
		onChange(updated :: Types.ActiveModifierSpec)
	end

	local kindTabs = tabRow(
		scope,
		1,
		(function()
			local tabs = {}
			for _, kind in ipairs(MODIFIER_KINDS) do
				table.insert(tabs, {
					Text = kind,
					Selected = effect.Kind == kind,
					OnActivated = function()
						patch({ Kind = kind })
					end,
				})
			end
			return tabs
		end)()
	)

	local lifetimeTabs = tabRow(
		scope,
		2,
		(function()
			local tabs = {}
			for _, lifetime in ipairs(MODIFIER_LIFETIMES) do
				table.insert(tabs, {
					Text = lifetime,
					Selected = effect.Lifetime == lifetime,
					OnActivated = function()
						patch({ Lifetime = lifetime })
					end,
				})
			end
			return tabs
		end)()
	)

	local kindFields: { Instance } = {}
	if effect.Kind == "AttributeDelta" then
		table.insert(
			kindFields,
			tabRow(
				scope,
				3,
				(function()
					local tabs = {}
					for _, key in ipairs(ATTRIBUTE_KEYS) do
						table.insert(tabs, {
							Text = key,
							Selected = effect.AttributeKey == key,
							OnActivated = function()
								patch({ AttributeKey = key })
							end,
						})
					end
					return tabs
				end)()
			)
		)
		table.insert(
			kindFields,
			NumericField.Mount(scope, {
				Label = "Delta",
				Value = effect.Delta or 0,
				Min = KitLimits.Delta.Min,
				Max = KitLimits.Delta.Max,
				Steps = { 1, 5 },
				LayoutOrder = 4,
				OnChanged = function(newValue: number)
					patch({ Delta = newValue })
				end,
			})
		)
	elseif effect.Kind == "Tag" then
		local tagText = scope:Value(effect.Tag or "")
		table.insert(
			kindFields,
			TextField(scope, {
				Text = tagText,
				PlaceholderText = "Tag name",
				MaxLength = 64,
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 3,
				OnFocusLost = function(text: string)
					patch({ Tag = text })
				end,
			})
		)
		table.insert(
			kindFields,
			NumericField.Mount(scope, {
				Label = "Magnitude",
				Value = effect.Magnitude or 0,
				Min = KitLimits.Magnitude.Min,
				Max = KitLimits.Magnitude.Max,
				Steps = { 1, 5 },
				LayoutOrder = 4,
				OnChanged = function(newValue: number)
					patch({ Magnitude = newValue })
				end,
			})
		)
	elseif effect.Kind == "QiRestore" then
		table.insert(
			kindFields,
			NumericField.Mount(scope, {
				Label = "Qi Restored",
				Value = effect.QiRestoreAmount or 0,
				Min = KitLimits.QiRestoreAmount.Min,
				Max = KitLimits.QiRestoreAmount.Max,
				Steps = { 5, 25 },
				LayoutOrder = 3,
				OnChanged = function(newValue: number)
					patch({ QiRestoreAmount = newValue })
				end,
			})
		)
	end

	local durationField: Instance? = nil
	if effect.Lifetime == "Timed" then
		durationField = NumericField.Mount(scope, {
			Label = "Duration",
			Unit = "seconds",
			Value = effect.DurationSeconds or KitLimits.DurationSeconds.Min,
			Min = KitLimits.DurationSeconds.Min,
			Max = KitLimits.DurationSeconds.Max,
			Steps = { 1, 5 },
			LayoutOrder = 5,
			OnChanged = function(newValue: number)
				patch({ DurationSeconds = newValue })
			end,
		})
	end

	return scope:New "Frame" {
		Name = "EffectRow",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Tokens.Wash.Inset.Color,
		BackgroundTransparency = Tokens.Wash.Inset.Transparency,
		LayoutOrder = index,

		[Children] = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.S),
				PaddingBottom = UDim.new(0, Tokens.Space.S),
				PaddingLeft = UDim.new(0, Tokens.Space.S),
				PaddingRight = UDim.new(0, Tokens.Space.S),
			},
			scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
			scope:New "UIStroke" {
				Color = Tokens.Border.Standard.Color,
				Thickness = 1,
				Transparency = Tokens.Border.Standard.Transparency,
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			kindTabs,
			lifetimeTabs,
			table.unpack(kindFields),
			durationField,
			Button(scope, {
				Text = "Remove Effect",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 6,
				OnActivated = onRemove,
			}),
		},
	} :: Frame
end

function ModifierListEditor.Mount(scope: Scope, props: ModifierListEditorProps): Frame
	local rows = scope:ForPairs(
		props.Effects,
		function(_use, innerScope: Scope, index: number, effect: Types.ActiveModifierSpec)
			return index,
				effectRow(innerScope, effect, index, function(updated: Types.ActiveModifierSpec)
					props.OnChanged(replaceAt(peek(props.Effects), index, updated))
				end, function()
					props.OnChanged(replaceAt(peek(props.Effects), index, nil))
				end)
		end
	)

	return scope:New "Frame" {
		Name = "ModifierListEditor",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			rows,
			Button(scope, {
				Text = "+ Add Effect",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 1e6,
				OnActivated = function()
					local current = peek(props.Effects)
					local newList = table.clone(current)
					table.insert(newList, defaultSpec())
					props.OnChanged(newList)
				end,
			}),
		},
	} :: Frame
end

return ModifierListEditor
