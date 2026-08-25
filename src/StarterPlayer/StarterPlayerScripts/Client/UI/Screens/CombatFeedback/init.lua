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

local Layers = require(script.Parent.Parent.Shell.Layers)
local Surface = require(script.Parent.Parent.Shell.Surface)
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

-- Returns its handle AND its banner tile. The tile is unparented -- UI/init.lua hands it to
-- Shell/Regions.lua's TopCentre at order 5, above the announcement banner at 10. See the note at the
-- StatusBanner call below for why the banner left this surface and the damage numbers did not.
function CombatFeedback.Mount(
	scope: Scope,
	playerGui: PlayerGui,
	scale: Fusion.UsedAs<number>
): (CombatFeedbackHandle, Frame)
	local outcome: Fusion.Value<StatusBannerModule.StatusBannerDisplay?> =
		scope:Value(nil :: StatusBannerModule.StatusBannerDisplay?)
	local damageNumbers: Fusion.Value<{ [string]: DamageNumberSpawnProps }> = scope:Value({})

	-- Tiled, so it carries no AnchorPoint and no Position of its own -- see StatusBanner's own Tiled
	-- note. It used to sit at Tokens.Space.XXL from the true top of the screen and now starts at
	-- TopCentre's edge inset instead, which is the one visible change in this migration.
	local bannerTile = StatusBanner(scope, { Display = outcome, Tiled = true })

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

	-- THE OUTCOME BANNER IS A REGION TILE NOW; THE DAMAGE NUMBERS ARE NOT. Phase 6 of
	-- docs/architecture/2026-08-25-hud-shell-plan.md, and the split between the two is the whole of
	-- the reasoning:
	--
	--   * The banner is CHROME at a fixed spot on the top edge -- exactly what a region is for, and
	--     exactly what was making Shell/Regions.lua carry a hardcoded 168px dodge of it
	--     (COMBAT_BANNER_BAND_BOTTOM, now deleted) so the announcement banner could clear something it
	--     had no other way to know about. As a TopCentre tile at order 5 it queues with the
	--     announcement and the notification channel for free, and the dodge stops existing.
	--   * The damage numbers are WORLD-ANCHORED, positioned per hit in screen space, and stay on this
	--     surface. Putting them in a region would be meaningless -- there is nothing to stack them
	--     against and their whole placement contract is "wherever the hit landed".
	--
	-- Layers.Overlay: over the dock and the ambient tiles, under any panel the player opened on
	-- purpose. A damage number that a modal cannot cover would be worse than one that can.
	--
	-- SCALED, and it is one of only three surfaces that are. The rule (Shell/Surface.lua's header) is
	-- that a surface scales if it draws chrome alongside the dock, and this one always does -- the two
	-- centred banners and every damage number are on screen at the same time as the hotbar. The
	-- IgnoreGuiInset this used to set by hand is the surface's now, and the reason that matters is
	-- that this file was one of only three that DID set it; the announcement banner below its two
	-- banners did not, which is why it rendered 36px lower than the number in its own source said.
	Surface.New(scope, {
		Name = "CombatFeedback",
		Layer = Layers.Overlay,
		Parent = playerGui,
		Scaled = true,
		Scale = scale,

		Children = {
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
	})

	return {
		Outcome = outcome,
		SpawnDamageNumber = spawnDamageNumber,
		AddDamageHit = addDamageHit,
		SuppressDamageNumbers = suppressDamageNumbers,
	},
		bannerTile
end

return CombatFeedback
