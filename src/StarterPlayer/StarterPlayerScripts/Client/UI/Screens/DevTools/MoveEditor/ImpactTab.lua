--!strict
--[[
	MoveEditor/ImpactTab.lua

	Owns: the Impact tab -- what a landed hit costs (health and guard) and what it does to the target's
	body: a knockback (Shared/Damage/Knockback.lua, optionally opening an air string) or a grab
	(Server/Combat/Grab/GrabSystem.lua).

	Knockback and Grab are OPTIONAL BLOCKS, each behind its own toggle: off means the block is absent
	(nil) on the move, not zeroed -- absent is what every system reads as "does not do this". Turning one
	on seeds it from sensible defaults (GrabConstants.Defaults for a grab) rather than zeros, because a
	zero-velocity knockback or a zero-second hold reads as broken the first time it is tried.

	A weapon stage carries neither: its launch and finish are the air combo's (AirComboSystem), so a
	Default move shows only its two costs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Copy = require(script.Parent.Copy)
local Fields = require(script.Parent.Fields)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Move = MoveTypes.MoveDefinition

local LIMITS = Constants.MoveEditor.Limits

-- What a freshly enabled knockback starts as: a solid shove, a little lift.
local DEFAULT_KNOCKBACK: MoveTypes.MoveKnockback = {
	UpVelocity = 15,
	HorizontalVelocity = 45,
	StartsAirCombo = false,
}

local GRAB_FIELDS = {
	{ Field = "HoldSeconds", Label = "Hold", Unit = "seconds", Steps = { 0.1, 1 } },
	{ Field = "ThrowUpVelocity", Label = "Throw lift", Unit = "studs/s", Steps = { 1, 10 } },
	{ Field = "ThrowHorizontalVelocity", Label = "Throw push", Unit = "studs/s", Steps = { 1, 10 } },
	{ Field = "ThrowImpactDamage", Label = "Impact damage", Unit = "to who they hit", Steps = { 1, 10 } },
	{ Field = "ThrowSelfDamage", Label = "Landing damage", Unit = "to the thrown", Steps = { 1, 10 } },
}

-- The hold-mode dropdown, in GrabConstants.ModeOrder with each mode's own Label -- adding a mode there
-- adds it here.
local GRAB_MODE_OPTIONS = {}
for _, modeName in GrabConstants.ModeOrder do
	table.insert(GRAB_MODE_OPTIONS, { Value = modeName, Text = GrabConstants.Modes[modeName].Label })
end

local function ImpactTab(scope: Scope, context: Fields.FormContext, visible: UsedAs<boolean>): ScrollingFrame
	local isCustom = scope:Computed(function(use)
		return not use(context.IsDefault)
	end)
	local hasKnockback = scope:Computed(function(use)
		local move = use(context.Draft)
		return move ~= nil and move.Knockback ~= nil and not use(context.IsDefault)
	end)
	local hasGrab = scope:Computed(function(use)
		local move = use(context.Draft)
		return move ~= nil and move.Grab ~= nil and not use(context.IsDefault)
	end)

	local children: { Instance } = {
		Fields.Heading(scope, "COST", 1),
		Fields.Number(scope, context, {
			Label = "Damage",
			Unit = "health",
			Range = LIMITS.Damage,
			Steps = { 1, 5 },
			Decimals = 1,
			LayoutOrder = 2,
			Get = function(move)
				return move.Damage
			end,
			Set = function(move, value)
				move.Damage = value
			end,
		}),
		Fields.Number(scope, context, {
			Label = "Posture damage",
			Unit = "guard",
			Range = LIMITS.PostureDamage,
			Steps = { 1, 5 },
			Decimals = 1,
			Hint = Copy.Hints.PostureDamage,
			LayoutOrder = 3,
			Get = function(move)
				return move.PostureDamage
			end,
			Set = function(move, value)
				move.PostureDamage = value
			end,
		}),

		Fields.Heading(scope, "KNOCKBACK", 10, isCustom),
		Fields.Toggle(scope, context, {
			Label = "Knock the target back",
			LayoutOrder = 11,
			Visible = isCustom,
			Get = function(move)
				return move.Knockback ~= nil
			end,
			Set = function(move, on)
				move.Knockback = if on then table.clone(DEFAULT_KNOCKBACK) else nil
			end,
		}),
		Fields.Number(scope, context, {
			Label = "Push",
			Unit = "studs/s",
			Range = LIMITS.KnockbackVelocity,
			Steps = { 1, 10 },
			Decimals = 0,
			LayoutOrder = 12,
			Visible = hasKnockback,
			Get = function(move)
				return if move.Knockback then move.Knockback.HorizontalVelocity else 0
			end,
			Set = function(move, value)
				if move.Knockback then
					move.Knockback.HorizontalVelocity = value
				end
			end,
		}),
		Fields.Number(scope, context, {
			Label = "Lift",
			Unit = "studs/s",
			Range = LIMITS.KnockbackVelocity,
			Steps = { 1, 10 },
			Decimals = 0,
			LayoutOrder = 13,
			Visible = hasKnockback,
			Get = function(move)
				return if move.Knockback then move.Knockback.UpVelocity else 0
			end,
			Set = function(move, value)
				if move.Knockback then
					move.Knockback.UpVelocity = value
				end
			end,
		}),
		Fields.Toggle(scope, context, {
			Label = "Launcher -- opens an air string",
			Hint = Copy.Hints.StartsAirCombo,
			LayoutOrder = 14,
			Visible = hasKnockback,
			Get = function(move)
				return move.Knockback ~= nil and move.Knockback.StartsAirCombo == true
			end,
			Set = function(move, on)
				if move.Knockback then
					move.Knockback.StartsAirCombo = on
				end
			end,
		}),

		Fields.Heading(scope, "GRAB", 20, isCustom),
		Fields.Toggle(scope, context, {
			Label = "Grab instead of knocking away",
			Hint = Copy.Hints.Grab,
			LayoutOrder = 21,
			Visible = isCustom,
			Get = function(move)
				return move.Grab ~= nil
			end,
			Set = function(move, on)
				if not on then
					move.Grab = nil
					return
				end
				local defaults = GrabConstants.Defaults
				move.Grab = {
					Mode = defaults.Mode :: any,
					VictimAnimation = "",
					AttackerAnimation = "",
					HoldSeconds = defaults.HoldSeconds,
					ThrowUpVelocity = defaults.ThrowUpVelocity,
					ThrowHorizontalVelocity = defaults.ThrowHorizontalVelocity,
					ThrowImpactDamage = defaults.ThrowImpactDamage,
					ThrowSelfDamage = defaults.ThrowSelfDamage,
				}
			end,
		}),

		Fields.Choice(scope, context, {
			Label = "Hold",
			Options = GRAB_MODE_OPTIONS,
			LayoutOrder = 22,
			Visible = hasGrab,
			Get = function(move)
				return if move.Grab then move.Grab.Mode or GrabConstants.DefaultMode else GrabConstants.DefaultMode
			end,
			Set = function(move, value)
				if move.Grab then
					move.Grab.Mode = value :: any
				end
			end,
		}),
		Fields.Prose(scope, Copy.Hints.GrabMode, 23, hasGrab),
		Fields.Text(scope, context, {
			Label = "Held target's animation id",
			Placeholder = "rbxassetid://... or a bare id",
			MaxLength = LIMITS.AnimationIdLength,
			Hint = Copy.Hints.GrabVictimAnimation,
			LayoutOrder = 29,
			Visible = hasGrab,
			Get = function(move)
				return if move.Grab then move.Grab.VictimAnimation or "" else ""
			end,
			Set = function(move, value)
				if move.Grab then
					move.Grab.VictimAnimation = value
				end
			end,
		}),
		Fields.Text(scope, context, {
			Label = "Your hold animation id",
			Placeholder = "rbxassetid://... or a bare id",
			MaxLength = LIMITS.AnimationIdLength,
			Hint = Copy.Hints.GrabAttackerAnimation,
			LayoutOrder = 30,
			Visible = hasGrab,
			Get = function(move)
				return if move.Grab then move.Grab.AttackerAnimation or "" else ""
			end,
			Set = function(move, value)
				if move.Grab then
					move.Grab.AttackerAnimation = value
				end
			end,
		}),

		Fields.Prose(
			scope,
			"A weapon stage has no knockback or grab of its own: the string's launch and finish belong to the air combo.",
			40,
			context.IsDefault
		),
	}

	for index, grabField in GRAB_FIELDS do
		table.insert(
			children,
			Fields.Number(scope, context, {
				Label = grabField.Label,
				Unit = grabField.Unit,
				Range = (GrabConstants.Limits :: any)[grabField.Field],
				Steps = grabField.Steps,
				Decimals = if grabField.Field == "HoldSeconds" then 2 else 0,
				LayoutOrder = 23 + index,
				Visible = hasGrab,
				Get = function(move: Move)
					return if move.Grab then (move.Grab :: any)[grabField.Field] else 0
				end,
				Set = function(move: Move, value)
					if move.Grab then
						(move.Grab :: any)[grabField.Field] = value
					end
				end,
			})
		)
	end

	return Fields.Page(scope, "ImpactTab", visible, children)
end

return ImpactTab
