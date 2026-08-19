--!strict
--[[
	AdminActionSystem.lua

	Owns: the admin-only per-player override flags that used to live directly on CombatSystem's own
	CombatState -- Godmode, Frozen, SpeedMultiplier, Invisible, plus the Flying/Collide flight toggle
	-- and the Humanoid Attribute mirrors every one of those flags is read back through
	(Constants.Attributes.Godmode/Frozen/SpeedMultiplier/Invisible/Flying/FlyCollide). None of these
	are combat resolution: they're a developer reaching in and overriding a player's own state from
	outside normal gameplay, which is a genuinely different responsibility from CombatSystem.lua's
	"resolve an accepted attack" job -- see software-architecture.md's ownership-boundary guidance
	and the Chief Architect's decomposition audit this module was extracted to satisfy.

	This System owns AdminOverrideState the same way CombatSystem.lua owns CombatState: one record
	per connected Player (createOverrideState/Players.PlayerAdded), persisted for the player's whole
	session (survives respawn -- Godmode/Frozen/SpeedMultiplier/Invisible are all deliberately NOT
	per-life transients, same "admin-granted state" precedent the original CombatState fields
	documented), and re-applied onto every fresh Humanoid via this System's own Players.CharacterAdded
	hook (reapplyRespawnOverrides) -- independent of CombatSystem's own CharacterAdded handler, so
	there is no dependency in either direction between the two Systems. A player's Humanoid Attributes
	are the only respawn-persistence CombatSystem/Movement.lua ever need to see -- Movement.
	ComputeDesiredWalkSpeed already reads Frozen/SpeedMultiplier directly off the Humanoid instead of
	reaching into CombatState (see that function's header), and CombatSystem's own hit-resolution
	godmode check now reads the Godmode Attribute the exact same way, so this module never needs
	CombatSystem to require it back, and CombatSystem never needs this module's internals -- one-way,
	no cycle.

	Flying/FlightCollide resolve their target's live Humanoid directly off Player.Character rather
	than through any other System's private state table (a Humanoid is always reachable straight off
	a Player, no cache needed) -- see Shared/CharacterUtil.lua's LiveRig.

	Does not own: authorization or rate-limiting (DevMenuSystem.lua's job, identical to every other
	admin action -- this module trusts its caller is already an authorized, rate-limited request, the
	same trust CombatSystem.SpawnTrainingDummy/SpawnTrainingBot place in DevMenuSystem). Does not own
	Health -- Humanoid.Health is CombatSystem.lua's own exclusive mutation authority (per that file's
	header), not an "override flag" in the sense every field here is, so CombatSystem.SetPlayerHealth
	stays exactly where it is; DevMenuSystem.lua's handleSetTargetHealth is unchanged and keeps
	calling it directly. See this repo's decomposition audit notes for the full reasoning on why
	Health didn't move here alongside Godmode/Flying/FlightCollide.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)

local logger = Logger.scope("AdminActionSystem")

local AdminActionSystem = {}

-- One record per connected Player, created in onPlayerAdded and cleared in onPlayerRemoving --
-- mirrors CombatSystem.lua's own combatStates table shape/lifecycle exactly, just for a much
-- smaller, admin-only slice of state. Never returned directly to a caller.
export type AdminOverrideState = {
	Godmode: boolean,
	-- Admin-only movement lock -- Movement.ComputeDesiredWalkSpeed reads the mirrored "Frozen"
	-- Attribute directly (pinned to top priority, above even Flying), not this field; this field
	-- exists purely so reapplyRespawnOverrides knows whether to re-seed that Attribute (and re-zero
	-- JumpPower) onto a fresh Humanoid after a respawn.
	Frozen: boolean,
	-- Humanoid.JumpPower captured the moment Frozen flips true (or is re-seeded true on respawn),
	-- so unfreezing restores whatever was actually in effect rather than assuming a hardcoded
	-- default. nil until Frozen has been true at least once for this session.
	SavedJumpPower: number?,
	-- Admin-only WalkSpeed scale, mirrored onto a "SpeedMultiplier" Attribute Movement.
	-- ComputeDesiredWalkSpeed reads as a scale on `base`. Defaults to 1 (no change).
	SpeedMultiplier: number,
	-- Admin-only invisibility -- mirrored onto an "Invisible" Attribute purely for DevMenuClient.lua's
	-- live UI; the actual visual effect is re-applied directly to a fresh character's parts by
	-- reapplyRespawnOverrides below.
	Invisible: boolean,
	-- Saved Humanoid.AutoRotate value from before SetFlying quieted the controller for Collide
	-- mode's physics constraints (see applyFlying's own header) -- nil until flight has been toggled
	-- at least once this session; restored verbatim on flight-off rather than assuming true.
	SavedFlightAutoRotate: boolean?,
}

local overrideStates: { [Player]: AdminOverrideState } = {}

function AdminActionSystem.CreateOverrideState(): AdminOverrideState
	return {
		Godmode = false,
		Frozen = false,
		SavedJumpPower = nil,
		SpeedMultiplier = 1,
		Invisible = false,
		SavedFlightAutoRotate = nil,
	}
end

-- Applies Transparency to every BasePart/Decal of `character` -- shared by ReapplyRespawnOverrides
-- (re-applies on a fresh respawn) and ApplyInvisible/SetInvisible below (the first real,
-- reachable SetInvisible action -- this function was dead code until that pair was wired up; see the
-- decomposition audit notes this module's header references for the history).
--
-- Skips HumanoidRootPart deliberately: it's invisible by design on every rig (Transparency = 1 from
-- the moment the character loads, R6 or R15), independent of this toggle entirely. Without this
-- exclusion, clearing Invisible (transparency = 0) force-sets it VISIBLE along with everything else,
-- and nothing ever puts it back to 1 afterward -- there's no "restore original per-part transparency"
-- step here, just a blind sweep to 0/1, so the root part is left permanently showing as a solid block
-- at the character's torso for the rest of the session. Found via the Awakening rework's own
-- Invisible(true) -> Invisible(false) cycle (Client/Intro/IntroClient.lua's AwakeningComplete signal
-- is the first real caller to exercise a full round trip on a live player and look closely at the
-- result) but the bug lives here, not in that feature -- every other SetInvisible caller (DevMenu's
-- manual toggle) hits the exact same thing.
local function setCharacterTransparency(character: Model, transparency: number): ()
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if descendant.Name ~= "HumanoidRootPart" then
				(descendant :: BasePart).Transparency = transparency
			end
		elseif descendant:IsA("Decal") then
			(descendant :: Decal).Transparency = transparency
		end
	end
end

-- Closed whitelist of the only multipliers SetSpeedMultiplier/ApplySpeedMultiplier below will ever
-- accept -- built once from Constants.Debug.DevMenu.SpeedMultiplierPresets the same
-- table-from-array idiom DevMenuSystem.lua's own HITBOX_CATEGORIES-style checks use, so a caller can
-- never push an arbitrary (or negative, or absurdly large) WalkSpeed scale through this System even
-- if DevMenuSystem's own validation were ever bypassed or loosened -- defense in depth, not the only
-- gate (DevMenuSystem.handleSetTargetSpeedMultiplier re-checks the same closed set itself before
-- ever calling down to here).
local SPEED_MULTIPLIER_PRESETS: { [number]: boolean } = {}
for _, preset in ipairs(Constants.Debug.DevMenu.SpeedMultiplierPresets) do
	SPEED_MULTIPLIER_PRESETS[preset] = true
end

-- Toggles godmode (see AdminOverrideState.Godmode's own header) -- zeroes damage/posture on every
-- future hit against this player until toggled off again (CombatSystem.lua's hit-resolution reads
-- the mirrored Attribute directly, the same pattern Movement.lua already established for Frozen/
-- SpeedMultiplier/Flying). Pure with respect to Roblox state beyond the Humanoid Attribute write, so
-- it's exercised directly in AdminActionSystem.spec.lua against a bare Instance.new("Humanoid") --
-- no live Player required, mirroring Movement.spec.lua/HitResolution.spec.lua's own fixture pattern.
function AdminActionSystem.ApplyGodmode(state: AdminOverrideState, humanoid: Humanoid, enabled: boolean): ()
	state.Godmode = enabled
	humanoid:SetAttribute(Constants.Attributes.Godmode, enabled)
end

-- Toggles flight: PlatformStand suspends the Humanoid's own ground movement/gravity response, and
-- the "Flying" Attribute is what Client/DevMenu/FlightController.lua watches to know whether IT
-- should start/stop driving free 3D movement locally. Also quiets/restores the Humanoid's own
-- airborne/recovery controller (AutoRotate, GettingUp state, a nudge into the Physics state) --
-- needed for Collide mode's LinearVelocity/AlignOrientation constraints (Client/DevMenu/
-- FlightPhysics.lua): a live Humanoid's own controller otherwise keeps fighting a physics-driven pin
-- every frame. Harmless for Noclip, whose direct CFrame write already overrides position regardless
-- of controller state. Same Instance-only testability as ApplyGodmode above.
function AdminActionSystem.ApplyFlying(state: AdminOverrideState, humanoid: Humanoid, enabled: boolean): ()
	humanoid.PlatformStand = enabled
	humanoid:SetAttribute(Constants.Attributes.Flying, enabled)

	if enabled then
		state.SavedFlightAutoRotate = humanoid.AutoRotate
		humanoid.AutoRotate = false
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		end)
	else
		humanoid.AutoRotate = if state.SavedFlightAutoRotate ~= nil then state.SavedFlightAutoRotate else true
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end
end

-- Toggles Collide mode for the Constants.Debug.DevMenu "Collide" toggle -- server owns nothing but
-- the Attribute, every constraint/physics decision is client-side (Client/DevMenu/FlightPhysics.lua),
-- same trust tier as Flying itself. Independent of whether Flying is currently true or false --
-- FlightController.lua watches BOTH Attributes live.
function AdminActionSystem.ApplyFlightCollide(humanoid: Humanoid, enabled: boolean): ()
	humanoid:SetAttribute(Constants.Attributes.FlyCollide, enabled)
end

-- Toggles the admin movement lock (see AdminOverrideState.Frozen's own header) -- mirrors the
-- Attribute Movement.ComputeDesiredWalkSpeed reads directly, and saves/zeroes JumpPower the same way
-- ReapplyRespawnOverrides already does for a fresh respawn, so a player frozen mid-life can't still
-- jump out of the freeze. Unfreezing restores whatever JumpPower was actually captured -- falling
-- back to Constants.Debug.DevMenu.DefaultJumpPower only if this humanoid was somehow never actually
-- frozen this life (defensive; SavedJumpPower is nil in that case). Same Instance-only testability as
-- ApplyGodmode/ApplyFlying above.
function AdminActionSystem.ApplyFrozen(state: AdminOverrideState, humanoid: Humanoid, enabled: boolean): ()
	state.Frozen = enabled
	humanoid:SetAttribute(Constants.Attributes.Frozen, enabled)
	if enabled then
		state.SavedJumpPower = humanoid.JumpPower
		humanoid.JumpPower = 0
	else
		humanoid.JumpPower = if state.SavedJumpPower ~= nil
			then state.SavedJumpPower
			else Constants.Debug.DevMenu.DefaultJumpPower
	end
end

-- Toggles admin-only invisibility (see AdminOverrideState.Invisible's own header) -- mirrors the
-- Attribute purely for DevMenuClient.lua's live UI, and calls setCharacterTransparency (this
-- module's header explains why that helper was unreachable dead code until now) for the actual
-- visual effect. Same Instance-only testability as ApplyGodmode/ApplyFlying/ApplyFrozen above.
function AdminActionSystem.ApplyInvisible(
	state: AdminOverrideState,
	character: Model,
	humanoid: Humanoid,
	enabled: boolean
): ()
	state.Invisible = enabled
	humanoid:SetAttribute(Constants.Attributes.Invisible, enabled)
	setCharacterTransparency(character, if enabled then 1 else 0)
end

-- Sets the admin-only WalkSpeed scale (see AdminOverrideState.SpeedMultiplier's own header) --
-- rejects anything outside SPEED_MULTIPLIER_PRESETS above, returning false without touching state or
-- the humanoid at all (never a partial/silent-clamp acceptance of an out-of-whitelist value). Same
-- Instance-only testability as ApplyGodmode/ApplyFlying/ApplyFrozen/ApplyInvisible above.
function AdminActionSystem.ApplySpeedMultiplier(
	state: AdminOverrideState,
	humanoid: Humanoid,
	multiplier: number
): boolean
	if not SPEED_MULTIPLIER_PRESETS[multiplier] then
		return false
	end
	state.SpeedMultiplier = multiplier
	humanoid:SetAttribute(Constants.Attributes.SpeedMultiplier, multiplier)
	return true
end

-- Re-seeds every respawn-persistent override onto a FRESH Humanoid instance (a new character means a
-- new Humanoid, which starts with none of these Attributes set) -- called from this module's own
-- Players.CharacterAdded hook, independent of CombatSystem.lua's own CharacterAdded handler (no
-- ordering dependency between the two: every Attribute read anywhere defaults gracefully to "no
-- override" while unset, the same defensive read Movement.ComputeDesiredWalkSpeed already does for
-- every Attribute it consumes). Frozen re-seeds JumpPower = 0 (capturing whatever the fresh Humanoid's
-- own JumpPower was first, mirroring the original per-life capture); Invisible re-applies
-- Transparency directly, since a Transparency edit doesn't survive a character being replaced the way
-- an Attribute mirror does.
function AdminActionSystem.ReapplyRespawnOverrides(state: AdminOverrideState, character: Model, humanoid: Humanoid): ()
	humanoid:SetAttribute(Constants.Attributes.Godmode, state.Godmode)
	humanoid:SetAttribute(Constants.Attributes.Frozen, state.Frozen)
	humanoid:SetAttribute(Constants.Attributes.SpeedMultiplier, state.SpeedMultiplier)
	if state.Frozen then
		state.SavedJumpPower = humanoid.JumpPower
		humanoid.JumpPower = 0
	end

	humanoid:SetAttribute(Constants.Attributes.Invisible, state.Invisible)
	if state.Invisible then
		setCharacterTransparency(character, 1)
	end
end

-- Admin-only actions (DevMenuSystem.lua's own whitelist check happens entirely before any of these
-- are ever called -- this module trusts its caller is a server-internal System, never re-checks
-- authorization itself, the same trust boundary CombatSystem.SpawnTrainingDummy/SpawnTrainingBot
-- already establish for their own callers).

-- Godmode persists (and is returned true) even without a currently-live character -- an admin toggling
-- it on a player who happens to be between lives still takes effect the moment they respawn (see
-- ReapplyRespawnOverrides), matching the original CombatSystem.SetPlayerGodmode's behavior exactly.
function AdminActionSystem.SetGodmode(targetPlayer: Player, enabled: boolean): boolean
	local state = overrideStates[targetPlayer]
	if not state then
		return false
	end
	state.Godmode = enabled
	local _, humanoid = CharacterUtil.LiveRig(targetPlayer)
	if humanoid then
		humanoid:SetAttribute(Constants.Attributes.Godmode, enabled)
	end
	return true
end

-- Flying requires a currently-live Humanoid (matches the original CombatSystem.SetPlayerFlying,
-- which also returned false with no bound Humanoid) -- flight is a live-session toggle, not a
-- respawn-persistent one, so there is nothing meaningful to apply without a body to apply it to.
--
-- Also reasserts network ownership of the target's rootPart -- Roblox's automatic network-ownership
-- algorithm hands a character's parts to the SERVER the moment PlatformStand flips true (the same
-- reason RagdollController.lua explicitly calls SetNetworkOwner around its own PlatformStand+
-- Physics-state usage -- see that module's header: "a bare velocity/CFrame write from the server is
-- immediately overridden by the owner's own simulation," which is exactly backwards for THIS
-- feature). Ragdoll WANTS server ownership, because the server drives the joints. Flight is the
-- opposite: Client/DevMenu/FlightController.lua's CFrame writes (Noclip) or FlightPhysics.lua's
-- LinearVelocity/AlignOrientation constraints (Collide) are entirely CLIENT-driven, so the flying
-- player must keep (or reclaim) ownership of their own rootPart. Without this, PlatformStand=true
-- silently strands the character server-owned: the server's own unowned physics simulation of a
-- PlatformStand rigid body keeps falling/settling under gravity every replication tick and overrides
-- whatever the client just wrote, which is exactly "stuck in the ground, not actually flying" rather
-- than a server error or a rejected request -- nothing here ever throws or returns false, so this
-- failure mode was invisible to every existing precondition/wiring check.
--
-- Explicit ownership on enable (SetNetworkOwner(targetPlayer), pcall-guarded the same way
-- RagdollController.setNetworkOwner is -- SetNetworkOwner throws on an anchored or otherwise
-- ungrounded part, and the client's own Anchored write can race this one); automatic ownership on
-- disable (SetNetworkOwnershipAuto()) so a no-longer-flying character returns to Roblox's normal
-- distance-based ownership instead of staying hard-pinned to whichever player last flew it.
function AdminActionSystem.SetFlying(targetPlayer: Player, enabled: boolean): boolean
	local state = overrideStates[targetPlayer]
	if not state then
		return false
	end
	local character, humanoid = CharacterUtil.LiveRig(targetPlayer)
	if not humanoid then
		return false
	end
	AdminActionSystem.ApplyFlying(state, humanoid, enabled)

	local rootPartInstance = character and character:FindFirstChild("HumanoidRootPart")
	if rootPartInstance and rootPartInstance:IsA("BasePart") then
		local rootPart = rootPartInstance :: BasePart
		pcall(function()
			if enabled then
				rootPart:SetNetworkOwner(targetPlayer)
			else
				rootPart:SetNetworkOwnershipAuto()
			end
		end)
	end

	return true
end

-- Same "requires a currently-live Humanoid" contract as SetFlying above -- matches the original
-- CombatSystem.SetPlayerFlightCollide exactly.
function AdminActionSystem.SetFlightCollide(targetPlayer: Player, enabled: boolean): boolean
	local state = overrideStates[targetPlayer]
	if not state then
		return false
	end
	local _, humanoid = CharacterUtil.LiveRig(targetPlayer)
	if not humanoid then
		return false
	end
	AdminActionSystem.ApplyFlightCollide(humanoid, enabled)
	return true
end

-- Frozen persists (and is returned true) even without a currently-live character -- same
-- "admin-granted state outlives the current life" contract as SetGodmode above (ReapplyRespawnOverrides
-- re-seeds it, JumpPower included, the moment a fresh character actually spawns).
--
-- Second caller: CharacterCreationSystem.lua freezes a first-time player prone in the Waking
-- Threshold for the intro cinematic + character creator, then unfreezes them once chargen finalizes
-- successfully. This is a legitimate, non-privileged reuse of an already-public function, not a
-- privilege-boundary exception -- SetFrozen itself has never had a whitelist check (the whitelist
-- lives one layer up, in DevMenuSystem's own handler, which CharacterCreationSystem does not go
-- through); it's simply the same "freeze a player's movement" primitive applied to a different,
-- equally legitimate caller.
function AdminActionSystem.SetFrozen(targetPlayer: Player, enabled: boolean): boolean
	local state = overrideStates[targetPlayer]
	if not state then
		return false
	end
	local _, humanoid = CharacterUtil.LiveRig(targetPlayer)
	if humanoid then
		AdminActionSystem.ApplyFrozen(state, humanoid, enabled)
	else
		state.Frozen = enabled
	end
	return true
end

-- Same "persists without a live character" contract as SetFrozen above -- ReapplyRespawnOverrides
-- re-applies Transparency to a fresh character's parts the moment one spawns.
function AdminActionSystem.SetInvisible(targetPlayer: Player, enabled: boolean): boolean
	local state = overrideStates[targetPlayer]
	if not state then
		return false
	end
	local character, humanoid = CharacterUtil.LiveRig(targetPlayer)
	if character and humanoid then
		AdminActionSystem.ApplyInvisible(state, character, humanoid, enabled)
	else
		state.Invisible = enabled
	end
	return true
end

-- Same "persists without a live character" contract as SetFrozen/SetInvisible above. Returns false
-- for EITHER an unknown target OR a multiplier outside SPEED_MULTIPLIER_PRESETS -- the same
-- single-boolean "something about this request wasn't valid" shape SetFlying/SetFlightCollide already
-- use for their own two independent failure reasons.
function AdminActionSystem.SetSpeedMultiplier(targetPlayer: Player, multiplier: number): boolean
	if not SPEED_MULTIPLIER_PRESETS[multiplier] then
		return false
	end
	local state = overrideStates[targetPlayer]
	if not state then
		return false
	end
	local _, humanoid = CharacterUtil.LiveRig(targetPlayer)
	if humanoid then
		AdminActionSystem.ApplySpeedMultiplier(state, humanoid, multiplier)
	else
		state.SpeedMultiplier = multiplier
	end
	return true
end

-- Teleport (Teleport-To-Target/Bring/Teleport-To-Coordinates) -- stateless, no AdminOverrideState
-- field applies (unlike every action above, this isn't a persistent override; it's a one-shot
-- reposition). Preserves the target's current facing (CFrame.new(position, position + LookVector))
-- rather than snapping orientation to identity, so a teleported player doesn't visibly spin in place.
-- Returns false if the target has no live character/rootPart -- there is nothing meaningful to
-- teleport otherwise, same "requires a currently-live Humanoid/rootPart" contract as SetFlying above.
function AdminActionSystem.TeleportToPosition(targetPlayer: Player, position: Vector3): boolean
	local character = targetPlayer.Character
	if not character then
		return false
	end
	local rootPartInstance = character:FindFirstChild("HumanoidRootPart")
	if not rootPartInstance or not rootPartInstance:IsA("BasePart") then
		return false
	end
	local rootPart = rootPartInstance :: BasePart
	rootPart.CFrame = CFrame.new(position, position + rootPart.CFrame.LookVector)
	return true
end

function AdminActionSystem.Init(): ()
	-- See Shared/PlayerLifecycle.lua. The Humanoid wait that used to sit inside this System's own
	-- onCharacterAdded is the binder's now, which matters here specifically: a respawn override
	-- (godmode, flight, frozen, invisible) that misses its Humanoid is an admin action that silently
	-- stops applying from that life onward, with nothing to tell either the admin or the target.
	PlayerLifecycle.BindAllPlayers({
		Scope = "AdminActionSystem",
		OnPlayer = function(player: Player)
			overrideStates[player] = AdminActionSystem.CreateOverrideState()
		end,
		OnPlayerRemoving = function(player: Player)
			overrideStates[player] = nil
		end,
		OnCharacter = function(player: Player, character: Model, humanoid: Humanoid)
			local state = overrideStates[player]
			if not state then
				return
			end
			AdminActionSystem.ReapplyRespawnOverrides(state, character, humanoid)
		end,
	})

	logger:info("AdminActionSystem.Init() complete")
end

-- Not cast to Types.SystemModule -- same reasoning as CombatSystem.lua/TrainingBotSystem.lua's own
-- return: this module's public surface (SetGodmode/SetFlying/SetFlightCollide/ApplyGodmode/etc.) is
-- wider than the minimal Init-only lifecycle contract.
return AdminActionSystem
