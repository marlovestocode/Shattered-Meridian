--!strict
--[[
	CombatFeedback.lua

	Owns: the mount point for docs/ui-ux-philosophy.md's Combat Feedback surfaces -- lock-on
	reticle, damage numbers, and the posture-break/enemy-exposed banner. All three are real, styled
	surfaces, now genuinely driven end to end: CombatSystem (server) defines and fires the wire
	shapes (Types.CombatFeedbackPayload, a targetUserId for lock-on), and
	Client/Combat/CombatClient.lua is the integration module that translates those into calls
	against this file's returned handle (AddDamageHit / SpawnDamageNumber / PostureBreak:set /
	LockOnTarget:set). Also mounts the shift-lock crosshair (Components/ShiftLockCrosshair.lua) --
	the one surface here NOT driven by CombatClient: Client/Camera/ShiftLockCamera.lua sets the
	handle's ShiftLockEngaged directly, since engage/disengage is a camera-mode transition that
	never touches the combat remotes CombatClient translates. It lives in this ScreenGui anyway
	because it's screen-space combat presentation exactly like the lock-on reticle beside it.

	AddDamageHit implements damage-number stacking: consecutive hits landing within
	STACK_WINDOW_SECONDS of each other accumulate into a single running total rather than each
	spawning its own independent floating number (posture damage no longer gets a separate number
	at all -- CombatClient.lua only ever reports health damage here now). Deliberately a single
	"current stack", not a per-target ledger -- Types.CombatFeedbackPayload has no stable target
	identity for a training dummy (only a position at the moment of the hit; see that type's
	TargetPosition header), and this melee system only ever has the player fighting one thing in
	front of them at a time, so a global stack isn't a meaningful loss of fidelity over a per-target
	one.

	Deliberately NOT modeled in ClientState.lua: ClientState's contract is "reflect a
	NetworkBridge-delivered, server-validated value" written exclusively from Bootstrap() (see that
	file's header), which presupposes a value that's meaningful to just snapshot-and-render. A
	lock-on target's on-screen position specifically isn't that: CombatSystem's wire payload carries
	a userId, and turning that into a UDim2 screen position is a client-side camera projection
	(`camera:WorldToViewportPoint`, recomputed every render frame in CombatClient.lua) -- "client
	owns feel", not server-validated truth ClientState would reflect. What isn't speculative is that
	this screen needs somewhere to hold "what's currently being shown" -- the same reasoning
	Menus.lua already applies to its own `IsOpen`, which lives as scope-local screen state rather
	than a ClientState field. These three pieces of state follow that exact precedent, exposed
	through the returned handle CombatClient.lua drives.

	Does not own: computing a lock-on target's screen position (CombatClient.lua), damage/posture
	calculation (CombatSystem), or deciding *when* any of these should show (also CombatSystem's
	call, relayed by CombatClient.lua) -- this module only renders whatever display state its
	handle is given.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)

local LockOnReticle = require(script.Parent.Parent.Components.LockOnReticle)
local DamageNumberLabel = require(script.Parent.Parent.Components.DamageNumberLabel)
local StatusBannerModule = require(script.Parent.Parent.Components.PostureBreakBanner)
local ShiftLockCrosshair = require(script.Parent.Parent.Components.ShiftLockCrosshair)
local ParryReadyGlint = require(script.Parent.Parent.Components.ParryReadyGlint)

local PostureBreakBanner = StatusBannerModule.PostureBreakBanner
local StatusBanner = StatusBannerModule.StatusBanner
-- Vertical gap (Tokens.Space units) between the PostureBreak banner and the Disarmed banner below
-- it, if both happen to be visible at once -- PostureBreakBanner's own Size is 64 tall.
local DISARMED_BANNER_Y_OFFSET = 72

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

export type DamageNumberSpawnProps = {
	Text: string,
	Kind: DamageNumberLabel.DamageKind?,
	Position: UDim2?,
}

-- A single landed hit's contribution to the current damage stack -- see AddDamageHit below.
export type DamageHitProps = {
	Amount: number,
	Kind: DamageNumberLabel.DamageKind,
	Position: UDim2?,
}

export type CombatFeedbackHandle = {
	LockOnTarget: Fusion.Value<LockOnReticle.LockOnTargetDisplay?>,
	PostureBreak: Fusion.Value<StatusBannerModule.PostureBreakDisplay?>,
	-- Disarmed status banner (CombatSystem.lua's Disarm mechanic) -- same StatusBanner component
	-- PostureBreak drives, just a second independent display slot so the two can't clobber each
	-- other's timers (see CombatClient.lua's guarded-clear handling for both).
	Disarmed: Fusion.Value<StatusBannerModule.StatusBannerDisplay?>,
	-- Driven by ShiftLockCamera.lua, not CombatClient.lua -- see the file header.
	ShiftLockEngaged: Fusion.Value<boolean>,
	SpawnDamageNumber: (props: DamageNumberSpawnProps) -> (),
	AddDamageHit: (props: DamageHitProps) -> (),
	-- Called on a parry to keep its "PARRIED" text from sharing the screen with a
	-- damage number from an adjacent hit -- clears the current damage stack and suppresses new
	-- damage numbers for `seconds`. See suppressDamageNumbers.
	SuppressDamageNumbers: (seconds: number) -> (),
	-- One-shot local parry-ready glint (ParryReadyGlint.lua) -- CombatClient calls this the frame a
	-- Block press is predicted to arm a parry window. Local-only acknowledgment; never the
	-- replicating character flash. See ParryReadyGlint's header.
	FlashParryReady: () -> (),
}

local DAMAGE_NUMBER_LIFETIME = Constants.FX.DamageNumbers.LifetimeSeconds
local STACK_WINDOW_SECONDS = Constants.FX.DamageNumbers.StackWindowSeconds
local PARRY_GLINT_HOLD_SECONDS = Constants.FX.ParryReadyGlint.HoldSeconds

local CombatFeedback = {}

function CombatFeedback.Mount(scope: Scope, playerGui: PlayerGui): CombatFeedbackHandle
	local lockOnTarget: Fusion.Value<LockOnReticle.LockOnTargetDisplay?> =
		scope:Value(nil :: LockOnReticle.LockOnTargetDisplay?)
	local postureBreak: Fusion.Value<StatusBannerModule.PostureBreakDisplay?> =
		scope:Value(nil :: StatusBannerModule.PostureBreakDisplay?)
	local disarmed: Fusion.Value<StatusBannerModule.StatusBannerDisplay?> =
		scope:Value(nil :: StatusBannerModule.StatusBannerDisplay?)
	local shiftLockEngaged: Fusion.Value<boolean> = scope:Value(false)
	local damageNumbers: Fusion.Value<{ [string]: DamageNumberSpawnProps }> = scope:Value({})
	local parryGlintIntensity: Fusion.Value<number> = scope:Value(0)

	-- Generation-guards the delayed intensity-reset the same way the banner clears above do: rapid
	-- re-flashes each schedule their own reset, but only the most recent one is allowed to zero the
	-- glint, so an earlier flash's timer can't cut a fresher flash short.
	local parryGlintGeneration = 0
	local function flashParryReady(): ()
		parryGlintGeneration += 1
		local generation = parryGlintGeneration
		parryGlintIntensity:set(1)
		task.delay(PARRY_GLINT_HOLD_SECONDS, function()
			if parryGlintGeneration == generation then
				parryGlintIntensity:set(0)
			end
		end)
	end

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

	-- See file header. currentStackId/currentStackTotal/currentStackExpiresAt track the one
	-- in-progress stack (if any); addDamageHit either extends it (same id, bumped Text/Position/
	-- expiry) or starts a fresh one (new id) depending on whether the window's still open.
	local currentStackId: string? = nil
	local currentStackTotal = 0
	local currentStackExpiresAt = 0

	-- A DEFENSIVE result (parry) suppresses damage numbers until this time -- see
	-- suppressDamageNumbers below for why: a parry is a clean "no damage" moment, and letting
	-- the chip-damage number from an adjacent hit in the same combo coexist with "PARRIED"
	-- read as doubled feedback ("PARRIED and a number at once").
	local suppressDamageUntil = 0

	local function scheduleStackExpiry(id: string): ()
		task.delay(STACK_WINDOW_SECONDS, function()
			-- Only the most recent hit's scheduled check should actually remove the stack -- an
			-- earlier hit's check firing after the stack was extended by a later hit is a no-op;
			-- that later hit's own check will fire and do the removal once the window truly closes.
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
		-- Suppressed by a just-resolved parry (see suppressDamageNumbers) -- the defensive
		-- text owns the moment; a coinciding chip-damage number would read as doubled feedback.
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
		updated[id] =
			{ Text = tostring(math.floor(currentStackTotal + 0.5)), Kind = props.Kind, Position = props.Position }
		damageNumbers:set(updated)

		scheduleStackExpiry(id)
	end

	-- Called when a parry resolves: clears the in-progress damage stack (so a number already
	-- on screen from an earlier hit in this combo doesn't sit next to the fresh "PARRIED")
	-- AND blocks new damage numbers for `seconds` (so a chip-damage number from the very next hit in
	-- the exchange doesn't pop up beside it either). Handles both orders -- number-then-defense and
	-- defense-then-number -- which a one-time clear alone would miss. The one-off SpawnDamageNumber
	-- labels (the "PARRIED" text itself) are deliberately NOT touched: those ARE the
	-- defensive feedback we want to show cleanly.
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
			LockOnReticle(scope, { Target = lockOnTarget }),
			PostureBreakBanner(scope, { Target = postureBreak }),
			StatusBanner(scope, { Display = disarmed, YOffset = DISARMED_BANNER_Y_OFFSET }),
			ShiftLockCrosshair(scope, { Engaged = shiftLockEngaged }),
			ParryReadyGlint(scope, { Intensity = parryGlintIntensity }),
			scope:New "Frame" {
				Name = "DamageNumbers",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,

				-- ForPairs, not ForValues: entries are mutated in place at a stable id (AddDamageHit
				-- bumps the same key's Text as a stack grows), and ForValues dedupes by value
				-- identity, not by key -- it has no way to recognize "same id, updated value" as a
				-- continuation rather than an old entry disappearing and an unrelated new one
				-- appearing.
				[Children] = scope:ForPairs(damageNumbers, function(use, innerScope, id, entry)
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
		LockOnTarget = lockOnTarget,
		PostureBreak = postureBreak,
		Disarmed = disarmed,
		ShiftLockEngaged = shiftLockEngaged,
		SpawnDamageNumber = spawnDamageNumber,
		AddDamageHit = addDamageHit,
		SuppressDamageNumbers = suppressDamageNumbers,
		FlashParryReady = flashParryReady,
	}
end

return CombatFeedback
