--!strict
--[[
	MeridianSystem.lua

	Owns: Meridian XP calculation and balance -- the core progression currency (project-vision.md,
	progression-systems.md: "Tier gates are earned through Meridian XP from PvP wins"). See
	software-architecture.md's "MeridianSystem and AchievementSystem" section for the full
	boundary.

	Does not own: tier-up validation and effects (TierSystem, which reads the balance this System
	owns to decide whether a threshold has been crossed), canonical persistence (PlayerDataSystem
	-- this System updates balances through PlayerDataSystem's API, never a DataStore write of its
	own), or deciding whether an event is progression-eligible (ProgressionSystem, which is what
	routes Meridian-XP-eligible reward components here in the first place -- see AwardKillXP).

	HOW A KILL REACHES THIS SYSTEM. PlayerDeathSystem confirms and attributes the death ->
	GameplayEvents.PlayerKilled -> RewardSystem composes a manifest -> ProgressionSystem gates and routes
	its MeridianXP component to AwardKillXP below. This System does NOT subscribe to PlayerKilled itself
	any more: the interim direct subscription it carried while RewardSystem/ProgressionSystem were empty
	was removed in the same change that made them real (2026-09-28), so one confirmed PvP death yields
	exactly one kill award, never one per path. AwardMeridianXP stays the grant primitive every caller
	shares -- BountySystem's claim payout calls it directly, a documented open migration
	(docs/architecture/2026-09-28-progression-spine-audit.md).

	Boots before TierSystem -- the resource has to exist before the system gating on it can
	meaningfully check it, mirroring PlayerDataSystem's "data layer first" boot position.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Logger = require(ReplicatedStorage.Shared.Logger)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)

local logger = Logger.scope("MeridianSystem")

local MeridianSystem = {}

local meridianXpUpdatedRemote: RemoteEvent? = nil

-- `gained`/`reason` only for a grant (see Types.MeridianXPUpdatePayload) -- a sync leaves them nil so
-- the client shows no gain cue for a number it merely learned.
local function sendMeridianUpdate(player: Player, amount: number, gained: number?, reason: string?): ()
	if not meridianXpUpdatedRemote then
		return
	end
	local payload: Types.MeridianXPUpdatePayload = { MeridianXP = amount, Gained = gained, Reason = reason }
	meridianXpUpdatedRemote:FireClient(player, payload)
end

-- Current Meridian XP balance, read straight from the canonical profile -- never cached here, so
-- this always reflects the true persisted value.
function MeridianSystem.GetMeridianXP(player: Player): number
	local profile = PlayerDataSystem.GetProfile(player)
	return if profile then profile.meridianXp else 0
end

-- Awards `amount` Meridian XP (positive only -- this is a grant primitive, not a generic setter;
-- there is deliberately no "SubtractMeridianXP" companion, since nothing in progression-systems.md
-- describes Meridian XP as ever being spent or lost). Persists through PlayerDataSystem.Transform
-- (never a direct DataStore write of its own, per this file's own header) and replicates the new
-- total immediately. Returns false if the profile isn't loaded or the amount is invalid, so a
-- caller can tell a genuine no-op apart from a successful zero-effect call.
function MeridianSystem.AwardMeridianXP(player: Player, amount: number, reason: string?): boolean
	if typeof(amount) ~= "number" or amount <= 0 then
		return false
	end

	local newTotal: number? = nil
	local transformed = PlayerDataSystem.Transform(player, function(profile)
		profile.meridianXp += amount
		newTotal = profile.meridianXp
	end)

	if not transformed or newTotal == nil then
		logger:warn("AwardMeridianXP failed: profile not loaded", { player = player.Name, amount = amount })
		return false
	end

	logger:info("Meridian XP awarded", {
		player = player.Name,
		amount = amount,
		reason = reason,
		newTotal = newTotal,
	})
	sendMeridianUpdate(player, newTotal :: number, amount, reason)
	-- Published AFTER the Transform has committed and the client has its new total, so TierSystem's
	-- promotion check reads a profile that already holds `newTotal` (GameplayEvents.
	-- FireMeridianXPAwarded's own header). Never fired on the failure paths above -- a grant that
	-- didn't happen must not trigger a promotion check.
	GameplayEvents.FireMeridianXPAwarded(player, amount, newTotal :: number, reason)
	return true
end

-- The Meridian XP component of a confirmed PvP kill: this System's one answer to "how much is a kill
-- worth", routed here by ProgressionSystem. The amount is decided HERE and nowhere upstream -- a flat
-- Constants.Meridian.BaseXPPerKill, deliberately unscaled by either tier (that constant's own header
-- says why), times `weight`: ProgressionSystem's legitimacy fraction for this kill (1 for an honest
-- one, less for a repeat of the same victim -- see its repeat-victim rule). Rounded to the nearest
-- whole point and never below 1 for any weight that reached here, so a counted kill always shows as
-- earning something. `victim` is carried for the day tier-gap scaling lands; it is unread today.
-- Returns whether the award landed (false for an unloaded profile, already logged by AwardMeridianXP).
function MeridianSystem.AwardKillXP(killer: Player, _victim: Player, weight: number?): boolean
	local fraction = if typeof(weight) == "number" and weight == weight then math.clamp(weight, 0, 1) else 1
	if fraction <= 0 then
		return false
	end
	local amount = math.max(1, math.floor(Constants.Meridian.BaseXPPerKill * fraction + 0.5))
	return MeridianSystem.AwardMeridianXP(killer, amount, "PvPKill")
end

local function onProfileLoaded(player: Player): ()
	-- Send the client its real starting total the moment the profile is available, rather than
	-- leaving the HUD at whatever render-only default it booted with until the player's next kill.
	sendMeridianUpdate(player, MeridianSystem.GetMeridianXP(player))
end

function MeridianSystem.Init(): ()
	meridianXpUpdatedRemote = NetworkBridge.CreateRemoteEvent(Constants.Meridian.RemoteNames.XPUpdated)

	PlayerDataSystem.OnProfileLoaded.Event:Connect(onProfileLoaded)

	logger:info("MeridianSystem.Init() complete")
end

return MeridianSystem :: Types.SystemModule & typeof(MeridianSystem)
