--!strict
--[[
	EffectsEditor.lua

	Owns: the Move Editor's four "what happens on or around a hit" sections -- Movement, Knockback,
	Grab and Projectile. Each is a self-contained enable Toggle plus a handful of NumericFields over
	one OPTIONAL sub-table of the draft (draft.Movement, draft.Knockback, draft.Grab,
	draft.Projectile), with no coupling to any section outside this file and only one to each other
	(Projectile's toggle nudges MaxTargets -- see its own comment).

	Four Build* functions rather than one, because each is still its OWN nav section with its own card
	and its own hidden-for-a-Default-move rule -- PropertyEditor.lua's sectionContent supplies that
	chrome, exactly as it does for HitboxEditor/AnimationTimelineEditor/ObjectStunEditor. What these
	four share is the shape of the edit, not the surface it renders on.

	They live here rather than inline in PropertyEditor.lua because that file was 1662 lines and these
	were ~340 of them with nothing tying them to their neighbours. The sibling-module split was already
	the established pattern for four other sections; this applies it to the group that most obviously
	forms one.

	EVERY numeric commit here goes through applyToSubTable below, never DraftBinding.Apply directly.
	That is not stylistic -- Apply's clone is SHALLOW (see its own header), so writing straight through
	`draft.Knockback.UpVelocity` would also rewrite the PREVIOUS draft object, which MoveList.lua's
	MovesDisplay cache is still holding. One helper is the whole defence: there is no site here where
	that clone could be forgotten, because no site does its own.

	Does not own: whether these sections are REACHABLE (Sidebar.lua's nav, gated by
	MoveEditor/Types.lua's HiddenForDefaultSections), the section cards themselves, or any validation
	-- MoveRegistryManager.Validate re-clamps every number below server-side against the same bounds,
	and silently drops a sub-table it can't read rather than trusting the client's copy.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)
local NumericField = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local Copy = require(script.Parent.Copy)
local DraftBinding = require(script.Parent.DraftBinding)

type Scope = Fusion.Scope<typeof(Fusion)>
type MoveDefinition = MoveTypes.MoveDefinition
type DraftContext = DraftBinding.DraftContext

local EffectsEditorModule = {}

-- Commits an edit to ONE of this panel's four optional sub-tables, cloning it first. See this file's
-- header for what a missing clone corrupts. A nil sub-table is a no-op rather than an error: every
-- field that calls this is Visible-gated on its own toggle, so the only way to reach here with the
-- block already off is a race between the toggle and an in-flight field commit, and dropping that
-- edit is the correct outcome -- the author just said they don't want the block at all.
local function applyToSubTable<T>(context: DraftContext, key: string, mutate: (T) -> ()): ()
	DraftBinding.Apply(context, function(draft)
		local existing = (draft :: any)[key]
		if not existing then
			return
		end
		local updated = table.clone(existing)
		mutate(updated);
		(draft :: any)[key] = updated
	end)
end

-- Movement ------------------------------------------------------------------------------------

function EffectsEditorModule.BuildMovement(scope: Scope, context: DraftContext): { Instance }
	local hasMovement = DraftBinding.Field(context, scope, function(draft): boolean
		return draft.Movement ~= nil
	end, false)
	local lungeDistance = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Movement then draft.Movement.LungeDistanceStuds else 8
	end, 8)
	local lungeDuration = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Movement then draft.Movement.LungeDurationSeconds else 0.2
	end, 0.2)

	return {
		Toggle(scope, {
			Label = "Enable Forward Lunge",
			Value = hasMovement,
			LayoutOrder = 3,
			OnChanged = function(enabled: boolean)
				DraftBinding.Apply(context, function(draft)
					draft.Movement = if enabled then { LungeDistanceStuds = 8, LungeDurationSeconds = 0.2 } else nil
				end)
			end,
		}),
		DraftBinding.Row(scope, 4, 2, {
			NumericField.Mount(scope, {
				Label = "Lunge Distance",
				Unit = Copy.Field("Movement.LungeDistance").Unit,
				Hint = Copy.Field("Movement.LungeDistance").Hint,
				Value = lungeDistance,
				Min = 0,
				Max = 30,
				Steps = { 1, 5 },
				Decimals = 1,
				Visible = hasMovement,
				OnChanged = function(value: number)
					applyToSubTable(context, "Movement", function(movement: MoveTypes.MoveMovementGrant)
						movement.LungeDistanceStuds = value
					end)
				end,
			}),
			NumericField.Mount(scope, {
				Label = "Lunge Duration",
				Unit = Copy.Field("Movement.LungeDuration").Unit,
				Hint = Copy.Field("Movement.LungeDuration").Hint,
				Value = lungeDuration,
				Min = 0.05,
				Max = 3,
				Steps = { 0.05, 0.2 },
				Visible = hasMovement,
				OnChanged = function(value: number)
					applyToSubTable(context, "Movement", function(movement: MoveTypes.MoveMovementGrant)
						movement.LungeDurationSeconds = value
					end)
				end,
			}),
		}),
	}
end

-- Knockback -----------------------------------------------------------------------------------

function EffectsEditorModule.BuildKnockback(scope: Scope, context: DraftContext): { Instance }
	local hasKnockback = DraftBinding.Field(context, scope, function(draft): boolean
		return draft.Knockback ~= nil
	end, false)
	local knockUp = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Knockback then draft.Knockback.UpVelocity else 20
	end, 20)
	local knockHorizontal = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Knockback then draft.Knockback.HorizontalVelocity else 10
	end, 10)
	local knockRagdoll = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Knockback then draft.Knockback.RagdollSeconds else 0.6
	end, 0.6)
	local knockStartsAirCombo = DraftBinding.Field(context, scope, function(draft): boolean
		return draft.Knockback ~= nil and draft.Knockback.StartsAirCombo == true
	end, false)

	return {
		Toggle(scope, {
			Label = "Enable Knockback",
			Value = hasKnockback,
			LayoutOrder = 3,
			OnChanged = function(enabled: boolean)
				DraftBinding.Apply(context, function(draft)
					draft.Knockback = if enabled
						then {
							UpVelocity = 20,
							HorizontalVelocity = 10,
							RagdollSeconds = 0.6,
							StartsAirCombo = false,
						}
						else nil
				end)
			end,
		}),
		-- One field per row, not a DraftBinding.Row -- a full NumericField (label, unit, value readout,
		-- two step buttons) does not fit two-up at this content pane's width, which is the same reason
		-- the Hitbox section's own Size fields stack.
		NumericField.Mount(scope, {
			Label = "Up Velocity",
			Unit = Copy.Field("Knockback.UpVelocity").Unit,
			Hint = Copy.Field("Knockback.UpVelocity").Hint,
			Value = knockUp,
			Min = 0,
			Max = 150,
			Steps = { 5, 20 },
			Decimals = 0,
			Visible = hasKnockback,
			LayoutOrder = 4,
			OnChanged = function(value: number)
				applyToSubTable(context, "Knockback", function(knockback: MoveTypes.MoveKnockback)
					knockback.UpVelocity = value
				end)
			end,
		}),
		NumericField.Mount(scope, {
			Label = "Horizontal Velocity",
			Unit = Copy.Field("Knockback.HorizontalVelocity").Unit,
			Hint = Copy.Field("Knockback.HorizontalVelocity").Hint,
			Value = knockHorizontal,
			Min = 0,
			Max = 150,
			Steps = { 5, 20 },
			Decimals = 0,
			Visible = hasKnockback,
			LayoutOrder = 5,
			OnChanged = function(value: number)
				applyToSubTable(context, "Knockback", function(knockback: MoveTypes.MoveKnockback)
					knockback.HorizontalVelocity = value
				end)
			end,
		}),
		NumericField.Mount(scope, {
			Label = "Ragdoll",
			Unit = Copy.Field("Knockback.RagdollSeconds").Unit,
			Hint = Copy.Field("Knockback.RagdollSeconds").Hint,
			Value = knockRagdoll,
			Min = 0,
			Max = 5,
			Steps = { 0.1, 0.5 },
			Visible = hasKnockback,
			LayoutOrder = 6,
			OnChanged = function(value: number)
				applyToSubTable(context, "Knockback", function(knockback: MoveTypes.MoveKnockback)
					knockback.RagdollSeconds = value
				end)
			end,
		}),
		Toggle(scope, {
			Label = "Starts Aerial Combo",
			Value = knockStartsAirCombo,
			LayoutOrder = 7,
			Visible = hasKnockback,
			OnChanged = function(enabled: boolean)
				applyToSubTable(context, "Knockback", function(knockback: MoveTypes.MoveKnockback)
					knockback.StartsAirCombo = enabled
				end)
			end,
		}),
	}
end

-- Grab ----------------------------------------------------------------------------------------

-- AttachOffset deliberately has NO field here -- see MoveGrabConfig.AttachOffset's own header
-- (MoveTypes.lua). Enabling the toggle seeds a placeholder identity CFrame that the very next
-- UpdateDraft round trip overwrites with GrabConstants.Defaults.AttachOffset (MoveRegistryManager.
-- Validate ignores whatever this file sends for that one field, always) -- the same brief "optimistic
-- value until the server's own clamp lands" window every other authored number here already tolerates.
--
-- The defaults below mirror GrabConstants.Defaults' own numbers without requiring that module, the
-- same precedent Knockback's toggle above already sets (20/10/0.6/false, none of them sourced from
-- DamageConstants either).
function EffectsEditorModule.BuildGrab(scope: Scope, context: DraftContext): { Instance }
	local hasGrab = DraftBinding.Field(context, scope, function(draft): boolean
		return draft.Grab ~= nil
	end, false)
	local holdSeconds = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Grab then draft.Grab.HoldSeconds else 3
	end, 3)
	local throwUp = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Grab then draft.Grab.ThrowUpVelocity else 20
	end, 20)
	local throwHorizontal = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Grab then draft.Grab.ThrowHorizontalVelocity else 55
	end, 55)
	local impactDamage = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Grab then draft.Grab.ThrowImpactDamage else 15
	end, 15)
	local selfDamage = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Grab then draft.Grab.ThrowSelfDamage else 10
	end, 10)

	-- Every field below is the same shape (a Visible-gated NumericField writing one number onto
	-- draft.Grab), so they are described as data and built in one pass rather than copy-pasted six
	-- times with only the key changing -- which is exactly how the Knockback block above accumulated
	-- its own near-identical repetitions.
	local numericFields: {
		{
			Label: string,
			CopyKey: string,
			Value: Fusion.UsedAs<number>,
			Min: number,
			Max: number,
			Steps: { number },
			Decimals: number?,
			Set: (MoveTypes.MoveGrabConfig, number) -> (),
		}
	} =
		{
			{
				Label = "Hold Duration",
				CopyKey = "Grab.HoldSeconds",
				Value = holdSeconds,
				Min = 0.5,
				Max = 15,
				Steps = { 0.25, 1 },
				Set = function(grab, value)
					grab.HoldSeconds = value
				end,
			},
			{
				Label = "Throw Up Velocity",
				CopyKey = "Grab.ThrowUpVelocity",
				Value = throwUp,
				Min = 0,
				Max = 150,
				Steps = { 5, 20 },
				Decimals = 0,
				Set = function(grab, value)
					grab.ThrowUpVelocity = value
				end,
			},
			{
				Label = "Throw Horizontal Velocity",
				CopyKey = "Grab.ThrowHorizontalVelocity",
				Value = throwHorizontal,
				Min = 0,
				Max = 150,
				Steps = { 5, 20 },
				Decimals = 0,
				Set = function(grab, value)
					grab.ThrowHorizontalVelocity = value
				end,
			},
			{
				Label = "Throw Impact Damage",
				CopyKey = "Grab.ThrowImpactDamage",
				Value = impactDamage,
				Min = 0,
				Max = 200,
				Steps = { 1, 10 },
				Decimals = 0,
				Set = function(grab, value)
					grab.ThrowImpactDamage = value
				end,
			},
			{
				Label = "Throw Self Damage",
				CopyKey = "Grab.ThrowSelfDamage",
				Value = selfDamage,
				Min = 0,
				Max = 200,
				Steps = { 1, 10 },
				Decimals = 0,
				Set = function(grab, value)
					grab.ThrowSelfDamage = value
				end,
			},
		}

	local children: { Instance } = {
		Toggle(scope, {
			Label = "Enable Grab",
			Value = hasGrab,
			LayoutOrder = 3,
			OnChanged = function(enabled: boolean)
				DraftBinding.Apply(context, function(draft)
					draft.Grab = if enabled
						then {
							AttachOffset = CFrame.new(),
							HoldSeconds = 3,
							ThrowUpVelocity = 20,
							ThrowHorizontalVelocity = 55,
							ThrowImpactDamage = 15,
							ThrowSelfDamage = 10,
						}
						else nil
				end)
			end,
		}),
	}

	for index, spec in ipairs(numericFields) do
		local set = spec.Set
		table.insert(
			children,
			NumericField.Mount(scope, {
				Label = spec.Label,
				Unit = Copy.Field(spec.CopyKey).Unit,
				Hint = Copy.Field(spec.CopyKey).Hint,
				Value = spec.Value,
				Min = spec.Min,
				Max = spec.Max,
				Steps = spec.Steps,
				Decimals = spec.Decimals,
				Visible = hasGrab,
				-- +3 keeps every field below the enable toggle, which owns LayoutOrder 3.
				LayoutOrder = index + 3,
				OnChanged = function(value: number)
					applyToSubTable(context, "Grab", function(grab: MoveTypes.MoveGrabConfig)
						set(grab, value)
					end)
				end,
			})
		)
	end

	return children
end

-- Projectile ----------------------------------------------------------------------------------

function EffectsEditorModule.BuildProjectile(scope: Scope, context: DraftContext): { Instance }
	local hasProjectile = DraftBinding.Field(context, scope, function(draft): boolean
		return draft.Projectile ~= nil
	end, false)
	local speed = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Projectile then draft.Projectile.Speed else 40
	end, 40)
	local maxRange = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Projectile then draft.Projectile.MaxRange else 60
	end, 60)

	return {
		Label(scope, {
			Text = "MaxTargets (Damage section) doubles as pierce count while this is on (1 = stops on first hit).",
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			AutoHeight = true,
			LineHeight = Tokens.Leading.Prose,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = 3,
		}),
		Toggle(scope, {
			Label = "Make Projectile",
			Value = hasProjectile,
			LayoutOrder = 4,
			OnChanged = function(enabled: boolean)
				DraftBinding.Apply(context, function(draft)
					if enabled then
						draft.Projectile = { Speed = 40, MaxRange = 60 }
						-- The one cross-section write in this whole file: a normal (non-piercing)
						-- projectile should stop on its first hit -- see this section's own explanatory
						-- Label above. MaxTargets is a top-level field, so it needs no clone.
						draft.MaxTargets = 1
					else
						draft.Projectile = nil
					end
				end)
			end,
		}),
		DraftBinding.Row(scope, 5, 2, {
			NumericField.Mount(scope, {
				Label = "Speed",
				Unit = Copy.Field("Projectile.Speed").Unit,
				Hint = Copy.Field("Projectile.Speed").Hint,
				Value = speed,
				Min = 5,
				Max = 2000,
				Steps = { 5, 20 },
				Decimals = 0,
				Visible = hasProjectile,
				OnChanged = function(value: number)
					applyToSubTable(context, "Projectile", function(projectile: MoveTypes.MoveProjectileConfig)
						projectile.Speed = value
					end)
				end,
			}),
			NumericField.Mount(scope, {
				Label = "Max Range",
				Unit = Copy.Field("Projectile.MaxRange").Unit,
				Hint = Copy.Field("Projectile.MaxRange").Hint,
				Value = maxRange,
				Min = 5,
				Max = 2000,
				Steps = { 5, 20 },
				Decimals = 0,
				Visible = hasProjectile,
				OnChanged = function(value: number)
					applyToSubTable(context, "Projectile", function(projectile: MoveTypes.MoveProjectileConfig)
						projectile.MaxRange = value
					end)
				end,
			}),
		}),
	}
end

return EffectsEditorModule
