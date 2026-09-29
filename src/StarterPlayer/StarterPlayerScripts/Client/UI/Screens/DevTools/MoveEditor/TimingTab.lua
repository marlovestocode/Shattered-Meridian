--!strict
--[[
	MoveEditor/TimingTab.lua

	Owns: the Timing tab -- the three phases and the cooldown as the author types them, the clip the
	swing is timed against, and the two properties that change how the swing is READ by a defender
	(weight class and feintability).

	What the swing actually does once the clip has had its say is the readout's timeline, not this tab:
	these are inputs, that is the result. Each hint says which input the clip can override, and "Match
	timing to clip" writes the server's MoveEditorTypes.ClipMatch into Windup and Recovery so the typed
	numbers stop disagreeing with the clip -- the effective timeline does not move, the authored one
	catches up to it.

	A Default move's clip, weight and feintability belong to its weapon and its place in the string
	(Shared/Attack/AttackAnimations, MoveTypes.PowerLevelByStage/FeintableByStage), so they are shown as
	facts.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Constants = require(ReplicatedStorage.Shared.Constants)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)

local Copy = require(script.Parent.Copy)
local Fields = require(script.Parent.Fields)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local LIMITS = Constants.MoveEditor.Limits

local function TimingTab(scope: Scope, context: Fields.FormContext, visible: UsedAs<boolean>): ScrollingFrame
	local isCustom = scope:Computed(function(use)
		return not use(context.IsDefault)
	end)
	local function fact(read: (MoveTypes.MoveDefinition) -> string)
		return scope:Computed(function(use)
			local move = use(context.Draft)
			return if move then read(move) else "-"
		end)
	end

	local function phase(label: string, order: number, hint: string, field: string, range: { Min: number, Max: number })
		return Fields.Number(scope, context, {
			Label = label,
			Unit = "seconds",
			Range = range,
			Steps = { 0.01, 0.1 },
			Hint = hint,
			LayoutOrder = order,
			Get = function(move)
				return (move :: any)[field]
			end,
			Set = function(move, value)
				(move :: any)[field] = value
			end,
		})
	end

	local children: { Instance } = {
		Fields.Heading(scope, "PHASES", 1),
		phase("Windup", 2, Copy.Hints.Windup, "WindupSeconds", LIMITS.PhaseSeconds),
		phase("Active", 3, Copy.Hints.Active, "ActiveSeconds", LIMITS.PhaseSeconds),
		phase("Recovery", 4, Copy.Hints.Recovery, "RecoverySeconds", LIMITS.PhaseSeconds),
		phase("Cooldown", 5, Copy.Hints.Cooldown, "Cooldown", LIMITS.CooldownSeconds),
		-- Legacy path (Variant nil): its disabled state follows the entry, and a Variant button peeks its
		-- props once.
		Button(scope, {
			Text = "Match timing to clip",
			Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
			LayoutOrder = 6,
			Disabled = scope:Computed(function(use)
				local entry = use(context.Entry)
				return entry == nil or entry.ClipMatch == nil
			end),
			OnActivated = function()
				local entry = peek(context.Entry)
				local match = if entry then entry.ClipMatch else nil
				if not match then
					return
				end
				context.Edit(function(move)
					move.WindupSeconds = match.WindupSeconds
					move.RecoverySeconds = match.RecoverySeconds
				end)
			end,
		}),
		Fields.Prose(scope, Copy.Hints.MatchTiming, 7),

		Fields.Heading(scope, "CLIP", 10),
		Fields.Text(scope, context, {
			Label = "Animation id",
			Placeholder = "rbxassetid://... or a bare id",
			MaxLength = LIMITS.AnimationIdLength,
			Hint = Copy.Hints.AnimationId,
			LayoutOrder = 11,
			Visible = isCustom,
			Get = function(move)
				return move.AnimationId
			end,
			Set = function(move, value)
				move.AnimationId = value
			end,
		}),
		Fields.Prose(
			scope,
			"A weapon move's clip comes from the weapon's own Animations folders (Shared/Attack/AttackAnimations). The readout shows which one it resolved to.",
			12,
			context.IsDefault
		),

		Fields.Heading(scope, "READ", 20),
		Fields.Number(scope, context, {
			Label = "Power level",
			Range = MoveTypes.PowerLevelLimits,
			Steps = { 1 },
			Decimals = 0,
			Hint = Copy.Hints.PowerLevel,
			LayoutOrder = 21,
			Visible = isCustom,
			Get = function(move)
				return MoveTypes.PowerLevelOf(move)
			end,
			Set = function(move, value)
				move.PowerLevel = math.floor(value + 0.5)
			end,
		}),
		Fields.Toggle(scope, context, {
			Label = "Feintable",
			Hint = Copy.Hints.Feintable,
			LayoutOrder = 22,
			Visible = isCustom,
			Get = function(move)
				return MoveTypes.IsFeintable(move)
			end,
			Set = function(move, on)
				move.Feintable = if on then true else nil
			end,
		}),
		Fields.Fact(
			scope,
			"Power level  (by stage)",
			fact(function(move)
				return tostring(MoveTypes.PowerLevelOf(move))
			end),
			23,
			context.IsDefault
		),
		Fields.Fact(
			scope,
			"Feintable  (by stage)",
			fact(function(move)
				return if MoveTypes.IsFeintable(move) then "Yes" else "No"
			end),
			24,
			context.IsDefault
		),
		Fields.Fact(
			scope,
			"Weapon speed x tempo",
			fact(function(move)
				return string.format("%.2f x %.2f", move.WeaponSpeed or 1, move.Tempo or 1)
			end),
			25,
			context.IsDefault
		),
	}

	return Fields.Page(scope, "TimingTab", visible, children)
end

return TimingTab
