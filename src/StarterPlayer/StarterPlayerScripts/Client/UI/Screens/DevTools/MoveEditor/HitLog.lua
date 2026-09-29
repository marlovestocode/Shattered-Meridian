--!strict
--[[
	MoveEditor/HitLog.lua

	Owns: the readout's HIT LOG -- one row per contact a Test swing of the open move made, newest first:
	how it resolved, what it cost, how deep the string was, how long after the swing started it landed,
	and on whom.

	The footer's "Landed:" line answers "did my last test hit"; this answers "what have my tests been
	doing" -- a block, then a clean hit, then a parry, side by side, with the timing of each.

	The rows are the driver's (MoveEditorClient fills Handle.HitLog from Combat_Feedback, filtered to the
	move last tested); this file only lays them out. Kind is a StatusTag whose colour follows what the
	contact means for the ATTACKER -- a landed hit Positive, an answered one Warning, a void one muted --
	always beside the word itself, never instead of it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local SectionHeading = require(script.Parent.Parent.Parent.Parent.Components.SectionHeading)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local StatusTag = require(script.Parent.Parent.Parent.Parent.Components.StatusTag)

local MoveEditorScreenTypes = require(script.Parent.Types)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type HitLogEntry = MoveEditorScreenTypes.HitLogEntry

export type HitLogProps = {
	LayoutOrder: number,
	Visible: UsedAs<boolean>,
	Entries: UsedAs<{ HitLogEntry }>,
	OnClear: () -> (),
}

local ROW_HEIGHT = 20

local function kindColor(kind: string): Color3
	if kind == "Clean" or kind == "Backstab" then
		return Tokens.Color.Positive
	elseif kind == "Blocked" or kind == "GuardBroken" then
		return Tokens.Color.Warning
	end
	return Tokens.Color.TextDisabled
end

local function HitLog(scope: Scope, props: HitLogProps): Frame
	local isEmpty = scope:Computed(function(use)
		return #use(props.Entries) == 0
	end)

	local rows = scope:ForPairs(props.Entries, function(_use, innerScope: Scope, index: number, entry: HitLogEntry)
		return index,
			Stack.Row(innerScope, {
				Name = `Hit{index}`,
				Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
				Gap = Tokens.Space.S,
				LayoutOrder = index,
				Children = {
					StatusTag(innerScope, { Label = entry.Kind, Color = kindColor(entry.Kind), LayoutOrder = 1 }),
					Label(innerScope, {
						Text = string.format(
							"%.0f dmg · %.0f guard · x%d · +%.2fs · %s",
							entry.Damage,
							entry.GuardDrain,
							entry.ComboStage,
							entry.SinceSwing,
							entry.Target
						),
						Scale = "NumeralSmall",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.fromScale(0, 1),
						AutomaticSize = Enum.AutomaticSize.X,
						TextTruncate = Enum.TextTruncate.AtEnd,
						LayoutOrder = 2,
					}),
				},
			})
	end)

	return Stack.New(scope, {
		Name = "HitLog",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		Children = {
			SectionHeading(scope, { Text = "HIT LOG", LayoutOrder = 0 }),
			Label(scope, {
				Text = "Contacts from Test swings of this move, newest first: damage, guard, combo stage, time after the swing started, target.",
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.fromScale(1, 0),
				AutoHeight = true,
				TextWrapped = true,
				LineHeight = Tokens.Leading.Prose,
				LayoutOrder = 0,
			}),
			rows :: any,
			Label(scope, {
				Text = "Nothing yet. Test the move with something in reach.",
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
				LayoutOrder = 998,
				Visible = isEmpty,
			}),
			Button(scope, {
				Text = "Clear log",
				Variant = "Secondary",
				Size = UDim2.new(0.5, 0, 0, Tokens.Control.StepButtonSize),
				LayoutOrder = 999,
				OnActivated = props.OnClear,
			}),
		},
	})
end

return HitLog
