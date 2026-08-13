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
	routes Meridian-XP-eligible reward components here in the first place).

	INTERIM DISPATCH NOTE: software-architecture.md's documented flow is CombatSystem -> RewardSystem
	-> ProgressionSystem -> MeridianSystem -- both RewardSystem and ProgressionSystem are still empty
	Init()s. Init() below subscribes directly to GameplayEvents.OnPlayerKilled for a first-pass award
	on every confirmed PvP kill, the same interim shortcut RivalrySystem/BountySystem already took
	for the same reason (docs/architecture/2026-08-audit.md). This is a known, documented gap, not a
	permanent design decision: once RewardSystem/ProgressionSystem exist, THEY should own deciding
	fight-to-grow eligibility and call AwardMeridianXP below -- this System's direct subscription
	should be removed at that point, not left as a second, competing award path.

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

local function sendMeridianUpdate(player: Player, amount: number): ()
	if not meridianXpUpdatedRemote then
		return
	end
	local payload: Types.MeridianXPUpdatePayload = { MeridianXP = amount }
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
	sendMeridianUpdate(player, newTotal :: number)
	-- Published AFTER the Transform has committed and the client has its new total, so TierSystem's
	-- promotion check reads a profile that already holds `newTotal` (GameplayEvents.
	-- FireMeridianXPAwarded's own header). Never fired on the failure paths above -- a grant that
	-- didn't happen must not trigger a promotion check.
	GameplayEvents.FireMeridianXPAwarded(player, amount, newTotal :: number, reason)
	return true
end

local function onProfileLoaded(player: Player): ()
	-- Send the client its real starting total the moment the profile is available, rather than
	-- leaving the HUD at whatever render-only default it booted with until the player's next kill.
	sendMeridianUpdate(player, MeridianSystem.GetMeridianXP(player))
end

function MeridianSystem.Init(): ()
	meridianXpUpdatedRemote = NetworkBridge.CreateRemoteEvent(Constants.Meridian.RemoteNames.XPUpdated)

	PlayerDataSystem.OnProfileLoaded.Event:Connect(onProfileLoaded)

	GameplayEvents.OnPlayerKilled(function(_victim: Player, killer: Player?)
		if killer ~= nil then
			MeridianSystem.AwardMeridianXP(killer, Constants.Meridian.BaseXPPerKill, "PvPKill")
		end
	end)

	logger:info("MeridianSystem.Init() complete")
end

return MeridianSystem :: Types.SystemModule
