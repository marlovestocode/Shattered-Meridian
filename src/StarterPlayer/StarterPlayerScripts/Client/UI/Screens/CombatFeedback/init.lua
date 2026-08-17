--!strict
--[[
	CombatFeedback.lua

	Owns: the screen-space surfaces that answer "what just happened in that exchange" --
	docs/ui-ux-philosophy.md's Damage Numbers and Posture Break Feedback sections. Two surfaces: a
	stack of floating damage numbers, and one high-visibility outcome banner.

	A REBUILD, NOT A RESTORATION. A screen of this name existed before the combat teardown and was
	deleted with it. This is deliberately the smaller half of that file: the lock-on reticle and the
	parry-ready glint it also mounted are gone because their components (LockOnReticle.lua,
	ParryReadyGlint.lua) were themselves deleted, and the shift-lock crosshair it used to host has
	since moved to UI/init.lua (see that file's header on why it never belonged here). What comes back
	is exactly what the rebuilt combat stack can actually feed: DamageSystem's Combat_Feedback event
	carries a damage amount, an outcome kind and a contact position, and those are what these two
	surfaces draw.

	DAMAGE NUMBER STACKING is kept from the original, and for the original's reason: consecutive hits
	inside Constants.FX.DamageNumbers.StackWindowSeconds accumulate into ONE running total rather than
	each spawning its own label, so a three-hit string reads as "24" climbing rather than three numbers
	fighting for the same patch of screen. Deliberately a single current stack, not a per-target
	ledger -- Types are per-contact and this is a melee game where a player is fighting what is in
	front of them, so a global stack loses nothing worth the bookkeeping.

	A DEFENSIVE OUTCOME SUPPRESSES DAMAGE NUMBERS briefly, also kept: "PARRIED" and a chip-damage
	number from the next hit of the same exchange arriving together reads as doubled, contradictory
	feedback. The banner owns that moment.

	Deliberately NOT modeled in ClientState.lua, for the reason that file's own header gives: this is
	transient presentation state with exactly one consumer (Client/Combat/CombatFeedbackClient.lua),
	not a server-validated value to reflect. It follows the Screen-returned-handle pattern that file
	documents as the second accepted shape, the same one Menus/init.lua's IsOpen uses.

	Does not own: deciding when anything shows (CombatFeedbackClient translates the server's
	Combat_Feedback event into these calls), projecting a world contact position into a screen
	position (also CombatFeedbackClient -- that is a camera projection, "client owns feel", recomputed
	per hit), or the camera shake that accompanies an impact (Client/FX/CameraShake.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)

local DamageNumberLabel = require(script.Parent.Parent.Components.DamageNumberLabel)
local StatusBannerModule = require(script.Parent.Parent.Components.PostureBreakBanner)

local StatusBanner = StatusBannerModule.StatusBanner

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

local CombatFeedback = {}

export type DamageNumberSpawnProps = {
	Text: string,
	Kind: DamageNumberLabel.DamageKind?,
	Position: UDim2?,
}

-- One landed hit's contribution to the current stack -- see AddDamageHit below.
export type DamageHitProps = {
	Amount: number,
	Kind: DamageNumberLabel.DamageKind,
	Position: UDim2?,
}

export type CombatFeedbackHandle = {
	-- nil = nothing to show. Set to a display state on a defensive outcome, cleared on its own timer
	-- by whoever set it.
	Outcome: Fusion.Value<StatusBannerModule.StatusBannerDisplay?>,
	-- A one-off label that is never stacked -- for text, not for a running total.
	SpawnDamageNumber: (props: DamageNumberSpawnProps) -> (),
	-- A landed hit that accumulates into the current stack. See this file's header.
	AddDamageHit: (props: DamageHitProps) -> (),
	-- Clears the in-progress stack AND blocks new numbers for `seconds`. Handles both orders --
	-- number-then-outcome and outcome-then-number -- which a one-time clear alone would miss.
	SuppressDamageNumbers: (seconds: number) -> (),
}

local DAMAGE_NUMBER_LIFETIME = Constants.FX.DamageNumbers.LifetimeSeconds
local STACK_WINDOW_SECONDS = Constants.FX.DamageNumbers.StackWindowSeconds

function CombatFeedback.Mount(scope: Scope, playerGui: PlayerGui): CombatFeedbackHandle
	local outcome: Fusion.Value<StatusBannerModule.StatusBannerDisplay?> =
		scope:Value(nil :: StatusBannerModule.StatusBannerDisplay?)
	local damageNumbers: Fusion.Value<{ [string]: DamageNumberSpawnProps }> = scope:Value({})

	local nextId = 0

	local function spawnDamageNumber(props: DamageNumberSpawnProps): ()
		nextId += 1
		local id = tostring(nextId)

		local updated = table.clone(Fusion.peek(damageNumbers))
		updated[id] = props
		damageNumbers:set(updated)

		task.delay(DAMAGE_NUMBER_LIFETIME, function()
			local latest = table.clone(Fusion.peek(damageNumbers))
			latest[id] = nil
			damageNumbers:set(latest)
		end)
	end

	-- The one in-progress stack, if any. addDamageHit either extends it (same id, bumped total and
	-- expiry) or starts a fresh one, depending on whether the window is still open.
	local currentStackId: string? = nil
	local currentStackTotal = 0
	local currentStackExpiresAt = 0
	local suppressDamageUntil = 0

	local function scheduleStackExpiry(id: string): ()
		task.delay(STACK_WINDOW_SECONDS, function()
			-- Only the most recent hit's scheduled check should remove the stack: an earlier hit's
			-- check firing after a later hit extended the stack is a no-op, and that later hit's own
			-- check does the removal once the window genuinely closes.
			if currentStackId ~= id or os.clock() < currentStackExpiresAt then
				return
			end
			currentStackId = nil
			local latest = table.clone(Fusion.peek(damageNumbers))
			latest[id] = nil
			damageNumbers:set(latest)
		end)
	end

	local function addDamageHit(props: DamageHitProps): ()
		local now = os.clock()
		if now < suppressDamageUntil then
			return
		end

		local id: string
		if currentStackId ~= nil and now < currentStackExpiresAt then
			id = currentStackId :: string
			currentStackTotal += props.Amount
		else
			nextId += 1
			id = tostring(nextId)
			currentStackId = id
			currentStackTotal = props.Amount
		end
		currentStackExpiresAt = now + STACK_WINDOW_SECONDS

		local updated = table.clone(Fusion.peek(damageNumbers))
		updated[id] = {
			Text = tostring(math.floor(currentStackTotal + 0.5)),
			Kind = props.Kind,
			Position = props.Position,
		}
		damageNumbers:set(updated)

		scheduleStackExpiry(id)
	end

	local function suppressDamageNumbers(seconds: number): ()
		suppressDamageUntil = os.clock() + seconds
		local activeId = currentStackId
		if activeId ~= nil then
			currentStackId = nil
			local latest = table.clone(Fusion.peek(damageNumbers))
			latest[activeId] = nil
			damageNumbers:set(latest)
		end
	end

	scope:New "ScreenGui" {
		Name = "CombatFeedback",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = {
			StatusBanner(scope, { Display = outcome }),
			scope:New "Frame" {
				Name = "DamageNumbers",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,

				-- ForPairs, not ForValues: entries are mutated in place at a stable id (AddDamageHit
				-- bumps the same key's Text as a stack grows), and ForValues dedupes by value identity
				-- rather than by key -- it has no way to recognise "same id, updated value" as a
				-- continuation instead of one entry vanishing and an unrelated one appearing.
				[Children] = scope:ForPairs(damageNumbers, function(_use, innerScope, id, entry)
					return id,
						DamageNumberLabel(innerScope, {
							Text = entry.Text,
							Kind = entry.Kind,
							Position = entry.Position,
						})
				end),
			},
		},
	}

	return {
		Outcome = outcome,
		SpawnDamageNumber = spawnDamageNumber,
		AddDamageHit = addDamageHit,
		SuppressDamageNumbers = suppressDamageNumbers,
	}
end

return CombatFeedback
