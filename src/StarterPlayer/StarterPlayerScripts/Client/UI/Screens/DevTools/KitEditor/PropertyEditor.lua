--!strict
--[[
	PropertyEditor.lua

	Owns: the Kit Editor's content pane -- the full authoring form for whichever draft is currently
	open (props.Draft), branching on KitDraft.Kind since a Race Trait and a Bloodline share almost
	nothing structurally beyond the Ability shape (see AbilityEditor.lua's own header). The Move
	Editor's convention (MoveEditor/Fields.lua): clone the current draft, mutate the one field that
	changed, hand the result to props.OnFieldChanged -- that closure (owned by init.lua) sets
	props.Draft immediately (optimistic) and fires the outer DraftFieldChanged signal, which
	KitEditorClient.lua debounces into the actual UpdateDraft network call.

	No Preview viewport, no per-section nav (unlike MoveEditor's own Sidebar-driven section split) --
	v1 has nothing to preview and this form is short enough (a handful of top-level fields plus one
	Ability sub-form, or a handful of fields plus a short Stages list) to read as one scrolling column,
	the same "explicit non-goal" the Race Traits + Bloodline Abilities plan states for this pass.

	Does not own: authorization (KitEditorSystem.lua re-checks server-side regardless of whether this
	screen is even visible) or the actual RemoteFunction calls (KitEditorClient.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)
local RaceTraitTypes = require(ReplicatedStorage.Shared.Race.RaceTraitTypes)
local BloodlineTypes = require(ReplicatedStorage.Shared.Bloodline.BloodlineTypes)
local KitTypes = require(ReplicatedStorage.Shared.Kit.KitTypes)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Parent.Parent.Components.Tab)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local NumericField = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local Section = require(script.Parent.Parent.Parent.Parent.Components.Section)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)

local KitEditorTypes = require(script.Parent.Types)
local ModifierListEditor = require(script.Parent.ModifierListEditor)
local AbilityEditor = require(script.Parent.AbilityEditor)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type KitDraft = KitEditorTypes.KitDraft

local KitLimits = Constants.Kit.Limits

local PropertyEditor = {}

export type PropertyEditorProps = {
	Draft: Fusion.Value<KitDraft?>,
	Width: number,
	Height: number,
	OnFieldChanged: (newDraft: KitDraft) -> (),
	OnSave: () -> (),
	StatusText: Fusion.Value<string>,
	IsDirty: Fusion.Computed<boolean>,
}

local RACE_IDS: { Types.RaceId } = { "Human", "Firmborn", "Rivenkin", "Hollowborn" }

local function raceTabRow(
	scope: Scope,
	layoutOrder: number,
	includeAny: boolean,
	selected: string?,
	onSelect: (Types.RaceId?) -> ()
): Frame
	local children: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	local order = 1
	if includeAny then
		table.insert(
			children,
			Tab(scope, {
				Text = "Any Race",
				Selected = selected == nil,
				Size = UDim2.fromOffset(110, Tokens.Control.StepButtonSize),
				LayoutOrder = order,
				OnActivated = function()
					onSelect(nil)
				end,
			})
		)
		order += 1
	end
	for _, raceId in ipairs(RACE_IDS) do
		table.insert(
			children,
			Tab(scope, {
				Text = raceId,
				Selected = selected == raceId,
				Size = UDim2.fromOffset(110, Tokens.Control.StepButtonSize),
				LayoutOrder = order,
				OnActivated = function()
					onSelect(raceId)
				end,
			})
		)
		order += 1
	end
	return scope:New "Frame" {
		Name = "RaceRow",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,
		[Children] = children,
	} :: Frame
end

--
-- Race Trait
--

local function raceTraitForm(
	scope: Scope,
	trait: RaceTraitTypes.RaceTraitDefinition,
	onChanged: (RaceTraitTypes.RaceTraitDefinition) -> ()
): { Instance }
	local function patch(fields: { [string]: any }): ()
		local updated = table.clone(trait) :: any
		for key, value in fields do
			updated[key] = value
		end
		onChanged(updated :: RaceTraitTypes.RaceTraitDefinition)
	end

	local traitIdText = scope:Value(trait.TraitId)

	return {
		Section(scope, "Identity", 1, {
			TextField(scope, {
				Text = traitIdText,
				PlaceholderText = "trait-id",
				MaxLength = 64,
				LayoutOrder = 1,
				OnFocusLost = function(text: string)
					patch({ TraitId = text })
				end,
			}),
			raceTabRow(scope, 2, false, trait.RaceId, function(raceId: Types.RaceId?)
				patch({ RaceId = raceId })
			end),
			NumericField.Mount(scope, {
				Label = "Required Tier",
				Value = trait.RequiredTier,
				Min = KitLimits.RequiredTier.Min,
				Max = KitLimits.RequiredTier.Max,
				Steps = { 1 },
				Slider = false,
				LayoutOrder = 3,
				Hint = "The minimum TierSystem tier a player must hold before this trait's Ability is granted.",
				OnChanged = function(newValue: number)
					patch({ RequiredTier = math.floor(newValue) })
				end,
			}),
		}, "A unique id, the race this trait belongs to, and the tier that unlocks it."),
		AbilityEditor.Mount(scope, {
			Title = "Ability",
			Ability = trait.Ability,
			LayoutOrder = 2,
			OnChanged = function(newAbility: KitTypes.KitAbilityDefinition)
				patch({ Ability = newAbility })
			end,
		}),
	}
end

--
-- Bloodline
--

local function stageForm(
	scope: Scope,
	stage: BloodlineTypes.BloodlineStageDefinition,
	index: number,
	onChanged: (BloodlineTypes.BloodlineStageDefinition) -> (),
	onRemove: () -> ()
): Frame
	local function patch(fields: { [string]: any }): ()
		local updated = table.clone(stage) :: any
		for key, value in fields do
			updated[key] = value
		end
		onChanged(updated :: BloodlineTypes.BloodlineStageDefinition)
	end

	local displayNameText = scope:Value(stage.DisplayName)
	local hasGrantedAbility = stage.GrantedAbility ~= nil

	local children: { Instance } = {
		NumericField.Mount(scope, {
			Label = "Stage Index",
			Value = stage.StageIndex,
			Min = KitLimits.StageIndex.Min,
			Max = KitLimits.StageIndex.Max,
			Steps = { 1 },
			Slider = false,
			LayoutOrder = 1,
			OnChanged = function(newValue: number)
				patch({ StageIndex = math.floor(newValue) })
			end,
		}),
		TextField(scope, {
			Text = displayNameText,
			PlaceholderText = "Stage Name",
			MaxLength = 64,
			LayoutOrder = 2,
			OnFocusLost = function(text: string)
				patch({ DisplayName = text })
			end,
		}),
		ModifierListEditor.Mount(scope, {
			Effects = stage.PassiveEffects,
			LayoutOrder = 3,
			OnChanged = function(newEffects)
				patch({ PassiveEffects = newEffects })
			end,
		}),
		Tab(scope, {
			Text = if hasGrantedAbility then "Remove Granted Ability" else "Grant an Ability at This Stage",
			Selected = hasGrantedAbility,
			Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
			LayoutOrder = 4,
			OnActivated = function()
				if hasGrantedAbility then
					patch({ GrantedAbility = nil })
				else
					patch({
						GrantedAbility = {
							Id = "",
							DisplayName = "New Ability",
							Description = "",
							Kind = "Active",
							CooldownSeconds = 0,
							QiCost = 0,
							Effects = {},
						} :: KitTypes.KitAbilityDefinition,
					})
				end
			end,
		}),
	}
	if stage.GrantedAbility then
		table.insert(
			children,
			AbilityEditor.Mount(scope, {
				Title = "Granted Ability",
				Ability = stage.GrantedAbility,
				LayoutOrder = 5,
				OnChanged = function(newAbility: KitTypes.KitAbilityDefinition)
					patch({ GrantedAbility = newAbility })
				end,
			})
		)
	end
	table.insert(
		children,
		Button(scope, {
			Text = "Remove Stage",
			Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
			LayoutOrder = 6,
			OnActivated = onRemove,
		})
	)

	return Section(scope, `Stage {index}`, index, children)
end

local function defaultStage(nextIndex: number): BloodlineTypes.BloodlineStageDefinition
	return { StageIndex = nextIndex, DisplayName = "New Stage", PassiveEffects = {} }
end

local function bloodlineForm(
	scope: Scope,
	bloodline: BloodlineTypes.BloodlineDefinition,
	onChanged: (BloodlineTypes.BloodlineDefinition) -> ()
): { Instance }
	local function patch(fields: { [string]: any }): ()
		local updated = table.clone(bloodline) :: any
		for key, value in fields do
			updated[key] = value
		end
		onChanged(updated :: BloodlineTypes.BloodlineDefinition)
	end

	local function patchCondition(fields: { [string]: any }): ()
		local updated = table.clone(bloodline.AwakeningCondition) :: any
		for key, value in fields do
			updated[key] = value
		end
		patch({ AwakeningCondition = updated :: BloodlineTypes.BloodlineAwakeningCondition })
	end

	local function patchParams(fields: { [string]: number }): ()
		local updated = table.clone(bloodline.AwakeningCondition.Params)
		for key, value in fields do
			updated[key] = value
		end
		patchCondition({ Params = updated })
	end

	local bloodlineIdText = scope:Value(bloodline.BloodlineId)
	local displayNameText = scope:Value(bloodline.DisplayName)
	local rarityTierText = scope:Value(bloodline.RarityTier)
	local flavorText = scope:Value(bloodline.FlavorText)
	local conditionKindText = scope:Value(bloodline.AwakeningCondition.Kind)

	local requiresAscended = (bloodline.AwakeningCondition.Params.RequiresAscended or 0) > 0

	local stages: { Instance } = {}
	for index, stage in ipairs(bloodline.Stages) do
		table.insert(
			stages,
			stageForm(scope, stage, index, function(updatedStage: BloodlineTypes.BloodlineStageDefinition)
				local newStages = table.clone(bloodline.Stages)
				newStages[index] = updatedStage
				patch({ Stages = newStages })
			end, function()
				local newStages = {}
				for otherIndex, otherStage in ipairs(bloodline.Stages) do
					if otherIndex ~= index then
						table.insert(newStages, otherStage)
					end
				end
				patch({ Stages = newStages })
			end)
		)
	end
	table.insert(
		stages,
		Button(scope, {
			Text = "+ Add Stage",
			Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
			LayoutOrder = #bloodline.Stages + 1,
			OnActivated = function()
				local maxIndex = 0
				for _, stage in ipairs(bloodline.Stages) do
					maxIndex = math.max(maxIndex, stage.StageIndex)
				end
				local newStages = table.clone(bloodline.Stages)
				table.insert(newStages, defaultStage(maxIndex + 1))
				patch({ Stages = newStages })
			end,
		})
	)

	return {
		Section(scope, "Identity", 1, {
			TextField(scope, {
				Text = bloodlineIdText,
				PlaceholderText = "bloodline-id",
				MaxLength = 64,
				LayoutOrder = 1,
				OnFocusLost = function(text: string)
					patch({ BloodlineId = text })
				end,
			}),
			TextField(scope, {
				Text = displayNameText,
				PlaceholderText = "Bloodline Name",
				MaxLength = 64,
				LayoutOrder = 2,
				OnFocusLost = function(text: string)
					patch({ DisplayName = text })
				end,
			}),
			TextField(scope, {
				Text = rarityTierText,
				PlaceholderText = "Rarity (e.g. Rare)",
				MaxLength = 64,
				LayoutOrder = 3,
				OnFocusLost = function(text: string)
					patch({ RarityTier = text })
				end,
			}),
			TextField(scope, {
				Text = flavorText,
				PlaceholderText = "Flavor text",
				Multiline = true,
				MaxLength = 800,
				Size = UDim2.new(1, 0, 0, 80),
				LayoutOrder = 4,
				OnFocusLost = function(text: string)
					patch({ FlavorText = text })
				end,
			}),
			raceTabRow(scope, 5, true, bloodline.NativeRaceId, function(raceId: Types.RaceId?)
				patch({ NativeRaceId = raceId })
			end),
		}, "A unique id, its name/flavor, and which race (if any) may awaken it."),
		Section(
			scope,
			"Awakening Condition",
			2,
			{
				TextField(scope, {
					Text = conditionKindText,
					PlaceholderText = "OnPlayerKilled",
					MaxLength = 64,
					LayoutOrder = 1,
					OnFocusLost = function(text: string)
						patchCondition({ Kind = text })
					end,
				}),
				NumericField.Mount(scope, {
					Label = "Required Kills",
					Value = bloodline.AwakeningCondition.Params.RequiredKills or 0,
					Min = 0,
					Max = 1000,
					Steps = { 1, 10 },
					LayoutOrder = 2,
					Hint = "Qualifying kills needed to first awaken this bloodline, and again for every "
						.. "subsequent stage advance -- the same threshold is reused for both.",
					OnChanged = function(newValue: number)
						patchParams({ RequiredKills = newValue })
					end,
				}),
				Tab(scope, {
					Text = if requiresAscended then "Requires Ascension: ON" else "Requires Ascension: OFF",
					Selected = requiresAscended,
					Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
					LayoutOrder = 3,
					OnActivated = function()
						patchParams({ RequiresAscended = if requiresAscended then 0 else 1 })
					end,
				}),
			},
			'v1 ships one trigger, "OnPlayerKilled" -- checked on every confirmed PvP kill. See BloodlineSystem.lua\'s own INTERIM DISPATCH NOTE.'
		),
		Section(
			scope,
			"Stages",
			3,
			stages,
			"Ordered by Stage Index. Each stage's passive effects apply for as long as it is the player's current stage."
		),
	}
end

function PropertyEditor.Mount(scope: Scope, props: PropertyEditorProps): Frame
	local content = scope:Computed(function(use)
		local draft = use(props.Draft)
		if not draft then
			return {
				Label(scope, {
					Text = "Select a Race Trait or Bloodline, or create a new one.",
					Scale = "BodyLarge",
					Color = Tokens.Color.TextSecondary,
				}),
			}
		end
		if draft.Kind == "RaceTrait" then
			return raceTraitForm(scope, draft.Trait, function(newTrait: RaceTraitTypes.RaceTraitDefinition)
				props.OnFieldChanged({ Kind = "RaceTrait", Trait = newTrait })
			end)
		end
		return bloodlineForm(scope, draft.Bloodline, function(newBloodline: BloodlineTypes.BloodlineDefinition)
			props.OnFieldChanged({ Kind = "Bloodline", Bloodline = newBloodline })
		end)
	end)

	local saveButtonText = scope:Computed(function(use)
		return if use(props.IsDirty) then "Save*" else "Save"
	end)

	return scope:New "Frame" {
		Name = "PropertyEditor",
		Size = UDim2.fromOffset(props.Width, props.Height),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "Toolbar",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = saveButtonText,
						Size = UDim2.fromOffset(120, Tokens.Control.RowHeight),
						LayoutOrder = 1,
						OnActivated = function()
							if peek(props.Draft) then
								props.OnSave()
							end
						end,
					}),
					Label(scope, {
						Text = props.StatusText,
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						LayoutOrder = 2,
					}),
				},
			},
			-- Takes whatever the toolbar row above leaves, instead of subtracting that row's height and
			-- the layout's gap -- see Components/Stack.lua.
			Stack.Fill(
				scope,
				ScrollArea(scope, {
					Name = "Content",
					Size = UDim2.fromScale(1, 1),
					LayoutOrder = 2,
					Children = {
						scope:New "UIListLayout" {
							FillDirection = Enum.FillDirection.Vertical,
							HorizontalAlignment = Enum.HorizontalAlignment.Left,
							Padding = UDim.new(0, Tokens.Space.S),
							SortOrder = Enum.SortOrder.LayoutOrder,
						},
						content,
					},
				})
			),
		},
	} :: Frame
end

return PropertyEditor
