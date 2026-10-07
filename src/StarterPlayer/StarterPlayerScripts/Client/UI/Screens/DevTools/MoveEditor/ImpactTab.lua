--!strict
--[[
	MoveEditor/ImpactTab.lua

	Owns: the Impact tab -- what a landed hit costs (health, guard, and the power level a block is drained
	by) and what it does to the target's body: a knockback (Shared/Damage/Knockback.lua, optionally opening
	an air string) or a grab (Server/Combat/Grab/GrabSystem.lua). Three sections: COST, KNOCKBACK, GRAB.

	Power level lives HERE, beside the damage it prices (2026-10-01): it used to sit on the Timing tab as a
	"read" property, but what it changes is how much guard a blocked hit drains -- a cost. The cost and
	knockback fields are PriceFields', shared with a domain expansion's STRIKE PRICE (Effects tab), which
	has no Impact tab: a realm lands no volume of its own (init.lua's move type bar).

	Knockback and Grab are OPTIONAL BLOCKS, each behind its own toggle: off means the block is absent
	(nil) on the move, not zeroed -- absent is what every system reads as "does not do this". Turning one
	on seeds it from sensible defaults (GrabConstants.Defaults for a grab) rather than zeros, because a
	zero-velocity knockback or a zero-second hold reads as broken the first time it is tried.

	A weapon stage carries neither: its launch and finish are the air combo's (AirComboSystem), so a
	Default move shows only its costs. A projectile move carries no grab (Validate refuses the pair),
	so its GRAB section is hidden; its knockback pushes along the shot's flight.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Copy = require(script.Parent.Copy)
local Fields = require(script.Parent.Fields)
local PriceFields = require(script.Parent.PriceFields)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Move = MoveTypes.MoveDefinition

local LIMITS = Constants.MoveEditor.Limits

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
	local hasGrab = scope:Computed(function(use)
		local move = use(context.Draft)
		return move ~= nil and move.Grab ~= nil and not use(context.IsDefault)
	end)
	-- A projectile move cannot grab (MoveRegistryManager.Validate refuses the pair), so its GRAB section is
	-- not offered at all; the move type bar drops any grab when a move becomes a projectile or a realm.
	local canGrab = scope:Computed(function(use)
		local move = use(context.Draft)
		return use(isCustom) and move ~= nil and move.Projectile == nil and move.Domain == nil
	end)
	local isCustomProjectile = scope:Computed(function(use)
		local move = use(context.Draft)
		return use(isCustom) and move ~= nil and move.Projectile ~= nil
	end)
	local function grabClip(label: string, field: string, hint: string, order: number): Frame
		return Fields.Text(scope, context, {
			Label = label,
			Placeholder = "rbxassetid://... or a bare id",
			MaxLength = LIMITS.AnimationIdLength,
			Hint = hint,
			LayoutOrder = order,
			Visible = hasGrab,
			Get = function(move)
				return if move.Grab then (move.Grab :: any)[field] or "" else ""
			end,
			Set = function(move, value)
				if move.Grab then
					(move.Grab :: any)[field] = value
				end
			end,
		})
	end

	local function grabBody(): { Instance }
		local children: { Instance } = {
			Fields.Toggle(scope, context, {
				Label = "Grab instead of knocking away",
				Hint = Copy.Hints.Grab,
				LayoutOrder = 1,
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
						ThrowAnimation = "",
						VictimThrowAnimation = "",
						ThrowReleaseAt = defaults.ThrowReleaseAt,
						HoldSeconds = defaults.HoldSeconds,
						ThrowUpVelocity = defaults.ThrowUpVelocity,
						ThrowHorizontalVelocity = defaults.ThrowHorizontalVelocity,
						ThrowImpactDamage = defaults.ThrowImpactDamage,
						ThrowSelfDamage = defaults.ThrowSelfDamage,
					}
				end,
			}),
			Fields.Chips(scope, context, {
				Label = "Hold",
				Options = GRAB_MODE_OPTIONS,
				Hint = Copy.Hints.GrabMode,
				LayoutOrder = 2,
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
			grabClip("Held target's animation id", "VictimAnimation", Copy.Hints.GrabVictimAnimation, 10),
			grabClip("Your hold animation id", "AttackerAnimation", Copy.Hints.GrabAttackerAnimation, 11),
			grabClip("Your throw animation id", "ThrowAnimation", Copy.Hints.GrabThrowAnimation, 12),
			Fields.Number(scope, context, {
				Label = "Release at",
				Unit = "of the throw clip",
				Range = GrabConstants.Limits.ThrowReleaseAt,
				Steps = { 0.01, 0.1 },
				Decimals = 2,
				Hint = Copy.Hints.GrabThrowReleaseAt,
				LayoutOrder = 13,
				Visible = hasGrab,
				Get = function(move: Move)
					return if move.Grab then move.Grab.ThrowReleaseAt or GrabConstants.Defaults.ThrowReleaseAt else 1
				end,
				Set = function(move: Move, value)
					if move.Grab then
						move.Grab.ThrowReleaseAt = value
					end
				end,
			}),
			grabClip("Thrown target's animation id", "VictimThrowAnimation", Copy.Hints.GrabVictimThrowAnimation, 14),
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
					LayoutOrder = 2 + index,
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
		return children
	end

	local children: { Instance } = {
		Fields.Section(scope, {
			Title = "COST",
			Summary = scope:Computed(function(use)
				return PriceFields.Summary(use(context.Draft))
			end),
			LayoutOrder = 1,
			Build = function()
				return PriceFields.Cost(scope, context)
			end,
		}),
		Fields.Section(scope, {
			Title = "KNOCKBACK",
			Summary = scope:Computed(function(use)
				local move = use(context.Draft)
				local knockback = if move then move.Knockback else nil
				if not knockback then
					return "Off"
				end
				local line = `{knockback.HorizontalVelocity} push  ·  {knockback.UpVelocity} lift`
				return if knockback.StartsAirCombo then `{line}  ·  launcher` else line
			end),
			LayoutOrder = 2,
			Visible = isCustom,
			Build = function()
				return PriceFields.Knockback(scope, context)
			end,
		}),
		Fields.Section(scope, {
			Title = "GRAB",
			Summary = scope:Computed(function(use)
				local move = use(context.Draft)
				local grab = if move then move.Grab else nil
				return if grab then `{grab.Mode or GrabConstants.DefaultMode}  ·  {grab.HoldSeconds}s hold` else "Off"
			end),
			LayoutOrder = 3,
			Visible = canGrab,
			Build = grabBody,
		}),
		Fields.Prose(
			scope,
			"A weapon stage has no knockback or grab of its own: the string's launch and finish belong to the air combo.",
			10,
			context.IsDefault
		),
		Fields.Prose(
			scope,
			"A projectile's knockback pushes along the shot's flight, not away from the thrower. It cannot grab. A reflected shot's damage and posture damage are scaled by its reflected damage (Hitbox tab, PARRY).",
			11,
			isCustomProjectile
		),
	}

	return Fields.Page(scope, "ImpactTab", visible, children)
end

return ImpactTab
