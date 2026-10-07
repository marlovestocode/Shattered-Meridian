--!strict
--[[
	MoveEditor/TimingTab.lua

	Owns: the Timing tab -- the three phases and the cooldown as the author types them, the clip the
	swing is timed against, and COMMITMENT: what the swing holds the thrower to (the two movement locks)
	and whether they may back out of it (feintable). Three sections: PHASES, CLIP, COMMITMENT.

	COMMITMENT IS ONE PLACE (2026-10-01). The movement locks used to sit on the Hitbox tab, beside the
	volume they have nothing to do with, and feintability under a "read" heading beside the power level;
	all three answer the same question -- what is the thrower bound to while this plays -- so they are one
	section here. The power level went the other way, to the Impact tab's COST: what it changes is a price.

	A DOMAIN EXPANSION IS STILL A MOVE, so it keeps this whole tab: its clip, its windup (the realm begins to
	unfurl the moment it ends), its cooldown and its locks are a swing's. Only the words change -- each phase's
	hint is the realm's reading of that phase (Copy.DomainTiming), since a cast opens no hitbox.

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
	local isDomain = scope:Computed(function(use)
		local move = use(context.Draft)
		return move ~= nil and move.Domain ~= nil
	end)
	local function fact(read: (MoveTypes.MoveDefinition) -> string)
		return scope:Computed(function(use)
			local move = use(context.Draft)
			return if move then read(move) else "-"
		end)
	end
	-- A hint that reads as the realm's when the move is a domain expansion.
	local function hint(swing: string, realm: string)
		return scope:Computed(function(use)
			return if use(isDomain) then realm else swing
		end)
	end

	local function phase(
		label: string,
		order: number,
		hintText: UsedAs<string>,
		field: string,
		range: { Min: number, Max: number }
	)
		return Fields.Number(scope, context, {
			Label = label,
			Unit = "seconds",
			Range = range,
			Steps = { 0.01, 0.1 },
			Hint = hintText,
			LayoutOrder = order,
			Get = function(move)
				return (move :: any)[field]
			end,
			Set = function(move, value)
				(move :: any)[field] = value
			end,
		})
	end
	local function lockToggle(label: string, order: number, hintText: string, field: string)
		return Fields.Toggle(scope, context, {
			Label = label,
			LayoutOrder = order,
			Hint = hintText,
			Visible = isCustom,
			Get = function(move)
				return (move :: any)[field] == true
			end,
			Set = function(move, on)
				(move :: any)[field] = on
			end,
		})
	end

	local realm = Copy.DomainTiming
	local children: { Instance } = {
		Fields.Section(scope, {
			Title = "PHASES",
			Summary = scope:Computed(function(use)
				local move = use(context.Draft)
				if not move then
					return ""
				end
				return string.format(
					"%.2f / %.2f / %.2f  ·  %gs cd",
					move.WindupSeconds,
					move.ActiveSeconds,
					move.RecoverySeconds,
					move.Cooldown
				)
			end),
			LayoutOrder = 1,
			Build = function()
				return {
					phase("Windup", 1, hint(Copy.Hints.Windup, realm.Windup), "WindupSeconds", LIMITS.PhaseSeconds),
					phase("Active", 2, hint(Copy.Hints.Active, realm.Active), "ActiveSeconds", LIMITS.PhaseSeconds),
					phase(
						"Recovery",
						3,
						hint(Copy.Hints.Recovery, realm.Recovery),
						"RecoverySeconds",
						LIMITS.PhaseSeconds
					),
					phase("Cooldown", 4, hint(Copy.Hints.Cooldown, realm.Cooldown), "Cooldown", LIMITS.CooldownSeconds),
					-- Legacy path (Variant nil): its disabled state follows the entry, and a Variant button
					-- peeks its props once.
					Button(scope, {
						Text = "Match timing to clip",
						Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
						LayoutOrder = 5,
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
					Fields.Prose(scope, Copy.Hints.MatchTiming, 6),
				}
			end,
		}),

		Fields.Section(scope, {
			Title = "CLIP",
			Summary = scope:Computed(function(use)
				local move = use(context.Draft)
				if not move or use(context.IsDefault) then
					return "the weapon's"
				end
				return if move.AnimationId ~= "" then move.AnimationId else "none"
			end),
			LayoutOrder = 2,
			Build = function()
				return {
					Fields.Text(scope, context, {
						Label = "Animation id",
						Placeholder = "rbxassetid://... or a bare id",
						MaxLength = LIMITS.AnimationIdLength,
						Hint = Copy.Hints.AnimationId,
						LayoutOrder = 1,
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
						2,
						context.IsDefault
					),
				}
			end,
		}),

		Fields.Section(scope, {
			Title = "COMMITMENT",
			Summary = scope:Computed(function(use)
				local move = use(context.Draft)
				if not move then
					return ""
				end
				local parts = {}
				if move.LocksWindup == true then
					table.insert(parts, "locked in windup")
				end
				if move.LocksMovement then
					table.insert(parts, "locked while active")
				end
				table.insert(parts, if MoveTypes.IsFeintable(move) then "feintable" else "no feint")
				return table.concat(parts, "  ·  ")
			end),
			LayoutOrder = 3,
			Build = function()
				return {
					lockToggle("Lock movement while winding up", 1, Copy.Hints.LocksWindup, "LocksWindup"),
					lockToggle("Lock movement while active", 2, Copy.Hints.LocksMovement, "LocksMovement"),
					Fields.Toggle(scope, context, {
						Label = "Feintable",
						Hint = Copy.Hints.Feintable,
						LayoutOrder = 3,
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
						"Feintable  (by stage)",
						fact(function(move)
							return if MoveTypes.IsFeintable(move) then "Yes" else "No"
						end),
						4,
						context.IsDefault
					),
					Fields.Fact(
						scope,
						"Weapon speed x tempo",
						fact(function(move)
							return string.format("%.2f x %.2f", move.WeaponSpeed or 1, move.Tempo or 1)
						end),
						5,
						context.IsDefault
					),
				}
			end,
		}),
	}

	return Fields.Page(scope, "TimingTab", visible, children)
end

return TimingTab
