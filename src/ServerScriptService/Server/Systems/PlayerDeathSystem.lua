--!strict
--[[
	PlayerDeathSystem.lua

	Owns: confirming that a player has died -- ANY death, PvP, environmental (fall, void) or otherwise --
	and publishing it exactly once per life as GameplayEvents.FirePlayerKilled(victim, killer, deathId);
	and deciding who, if anyone, that killer was. It is the SOLE publisher of PlayerKilled and the sole
	owner of kill credit. Nothing else in the tree may attribute a death.

	WHY ATTRIBUTION LIVES HERE AND NOT IN THE DAMAGE LAYER. DamageSystem knows who hit whom; this module
	knows when a life ended. Kill credit is the join of the two, and it belongs to the side that owns the
	one-shot moment -- the death -- because that is where "exactly once" has to be enforced. So this
	module subscribes to DamageSystem.OnApplied, the extension point that layer's own header documents
	for precisely this follow-up, and DamageSystem stays ignorant of deaths, players and rewards. The
	dependency is one-way (this -> DamageSystem, through that one callback) and DamageSystem never
	requires this module.

	OnApplied fires BEFORE the health write (DamageSystem.applyOutcome's own comment), and
	Humanoid:TakeDamage raises Humanoid.Died -- so the lethal blow's credit is always recorded before the
	death it causes is confirmed, whatever the signal behaviour.

	WHAT EARNS CREDIT. Health actually removed from a live player by a DIFFERENT, still-present player.
	Concretely, RecordDamage refuses:
	  * zero damage -- a guarded Blocked, a Parried, a Trade all price to 0 in DamageResolver and move no
	    health, so they are not blows. (A Blocked landing on a STAGGERED guard does remove health, and
	    does earn credit: the rule is health removed, not outcome kind.)
	  * self-damage, a non-player attacker (a dummy, a future bot), or an attacker who has already left;
	  * a hit on a character that is not the victim's CURRENT life, or on a life already confirmed dead.
	The adapter additionally refuses a hit on an already-dead Humanoid, mirroring DamageSystem's own
	LiveHumanoidOf guard: a blow that lands on a corpse applies no damage there, so it must not steal
	credit from the one that killed.

	The latest valid blow wins ("last hit"), and it expires after DamageConstants.KillCredit.WindowSeconds
	-- see that constant's header for why a window exists at all and why it is short.

	PER-LIFE, NOT PER-PLAYER. A life is one character. BeginLife replaces the whole record, so a credit
	earned against a previous body can never cross a respawn, and ConfirmDeath checks the dying Model is
	the life on record, so a stale Died from an old body is ignored. Everything is dropped on
	PlayerRemoving -- the leaver's own record AND any credit they hold against someone else, because
	publishing a departed Player as a killer would hand every PlayerKilled subscriber
	(RivalrySystem's standings, BountySystem's streaks) a reference their own PlayerRemoving scrub has
	already run for: an unbounded leak, not just a wasted reward.

	EXACTLY ONCE PER LIFE. DeathConfirmed guards a second Humanoid.Died for the same life (possible for
	edge-case rig setups), which would otherwise double-schedule a respawn and double-count a kill for
	every subscriber. deathId is the fact's identity: a server-lifetime monotonic counter, so a consumer
	that must never act twice on one death (RewardSystem) can tell a replay from a second kill.

	THE IDENTITY SEAM. Every Players lookup is in onDamageApplied and Init's PlayerLifecycle binding; the
	behaviour lives in BeginLife/RecordDamage/ConfirmDeath/ReleasePlayer, which take already-resolved
	identities. That is what makes this module testable at all -- Instance.new("Player") errors in the
	headless harness (Tests/Progression/PlayerDeathSystem.spec.lua), exactly the shape
	EngagementSystem.RecordExchange established.

	Health authority stays Roblox's own Humanoid.Health/TakeDamage/Died -- nothing here shadows it.

	ALSO OWNS the Death_Notice remote (DeathConstants.Network.RemoteNames.Notice): the same confirmed
	fact, told to every client, so the victim's death overlay and everyone's kill feed can render it.
	It is this module's to send for the same reason Combat_Feedback is DamageSystem's -- the owner of
	a fact owns its replication -- and it is sent from ConfirmDeath, the one place the fact exists, never
	from a second subscriber that could see it in a different order. Presentation only: nothing a
	client does with it can change anything.

	Does not own: what happens after a death (RespawnSystem gives a new body; RewardSystem decides what a
	confirmed PvP kill is eligible for; RivalrySystem/BountySystem keep their own standings), damage
	pricing (DamageSystem), or any reward. Boots after DamageSystem (whose OnApplied it subscribes to)
	and before AttackRequestSystem (the first thing that lets a player land a blow) -- Main.server.lua.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DeathConstants = require(ReplicatedStorage.Shared.Death.DeathConstants)
local DeathTypes = require(ReplicatedStorage.Shared.Death.DeathTypes)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)

local PlayerDeathSystem = {}

local logger = Logger.scope("PlayerDeathSystem")

-- One life's record. Credit is two flat fields rather than a nested table so a damaging hit updates in
-- place instead of allocating -- this runs once per landed blow in every fight.
type LifeState = {
	Character: Model,
	DeathConfirmed: boolean,
	CreditAttacker: Player?,
	CreditAt: number,
}

local lifeStates: { [Player]: LifeState } = {}

-- The last deathId handed out. Server-lifetime and never reset -- not even by Reset below -- so ids are
-- unique and increasing for as long as any consumer (RewardSystem's replay guard) could hold one.
local lastDeathId = 0

local noticeRemote: RemoteEvent? = nil
local appliedDisconnect: (() -> ())? = nil
local lifecycle: Trove.TroveInstance? = nil
local started = false

-- The credit on `state` if it is still fresh and its holder is still here, else nil.
local function resolveKiller(state: LifeState, now: number): Player?
	local attacker = state.CreditAttacker
	if attacker == nil or lifeStates[attacker] == nil then
		return nil
	end
	if now - state.CreditAt > DamageConstants.KillCredit.WindowSeconds then
		return nil
	end
	return attacker
end

-- The Death_Notice payload for one confirmed death. Pure, so a spec can hold its shape to account
-- without a remote.
function PlayerDeathSystem.BuildNotice(victim: Player, killer: Player?): DeathTypes.DeathNotice
	return {
		VictimUserId = victim.UserId,
		VictimName = victim.Name,
		KillerUserId = if killer then killer.UserId else nil,
		KillerName = if killer then killer.Name else nil,
	}
end

-- Opens a new life for `player` on `character`, discarding everything about the previous one --
-- including any credit held against it. Bound to every character by Init.
function PlayerDeathSystem.BeginLife(player: Player, character: Model): ()
	lifeStates[player] = {
		Character = character,
		DeathConfirmed = false,
		CreditAttacker = nil,
		CreditAt = 0,
	}
end

-- Drops `player` entirely: their own record, and any credit they hold against anyone else. Bound to
-- PlayerRemoving by Init. See this file's header on why the second half is a leak fix, not tidiness.
function PlayerDeathSystem.ReleasePlayer(player: Player): ()
	lifeStates[player] = nil
	for _, state in lifeStates do
		if state.CreditAttacker == player then
			state.CreditAttacker = nil
			state.CreditAt = 0
		end
	end
end

-- Records `attacker` as the pending killer of `victim`'s current life, if this blow qualifies. Returns
-- whether it did. See this file's header for every refusal and why.
function PlayerDeathSystem.RecordDamage(
	victim: Player,
	character: Model,
	attacker: Player?,
	damage: number,
	now: number
): boolean
	if attacker == nil or attacker == victim then
		return false
	end
	-- `not (x > 0)` rather than `x <= 0` so NaN is refused too.
	if typeof(damage) ~= "number" or not (damage > 0) then
		return false
	end
	local state = lifeStates[victim]
	if state == nil or state.DeathConfirmed or state.Character ~= character then
		return false
	end
	if lifeStates[attacker] == nil then
		-- Not a tracked player: never bound a life here, or already released.
		return false
	end
	state.CreditAttacker = attacker
	state.CreditAt = now
	return true
end

-- Confirms the death of `player`'s life on `character` and publishes it. Returns whether a death was
-- published (false for a duplicate, a stale body, or an untracked player), the killer it carried, and
-- its deathId. The killer is nil for any death without fresh, same-life credit -- the environmental
-- case every PlayerKilled subscriber already handles.
--
-- State is made consistent BEFORE the fire, so a subscriber that reads back into this module (none
-- does today) sees a confirmed, credit-free life, never the pre-death one.
function PlayerDeathSystem.ConfirmDeath(player: Player, character: Model, now: number): (boolean, Player?, number?)
	local state = lifeStates[player]
	if state == nil or state.Character ~= character or state.DeathConfirmed then
		return false, nil, nil
	end

	local killer = resolveKiller(state, now)
	state.DeathConfirmed = true
	state.CreditAttacker = nil
	state.CreditAt = 0
	lastDeathId += 1
	local deathId = lastDeathId

	logger:debug("Player died", {
		player = player.Name,
		killer = if killer then killer.Name else nil,
		deathId = deathId,
	})
	GameplayEvents.FirePlayerKilled(player, killer, deathId)
	-- After the server-internal fact, and nil-guarded: a spec never creates the remote.
	local remote = noticeRemote
	if remote then
		remote:FireAllClients(PlayerDeathSystem.BuildNotice(player, killer))
	end
	return true, killer, deathId
end

-- The adapter, and nothing more than one: resolve both Models to Players and hand the blow over. The
-- damage check comes first so the common non-lethal, non-player traffic costs one comparison.
local function onDamageApplied(outcome: DefenseTypes.DefenseOutcome, result: DamageTypes.DamageResult): ()
	if not (result.Damage > 0) then
		return
	end
	-- Mirrors DamageSystem.applyOutcome's own guard: it only applies damage to a LIVE Humanoid, so a
	-- blow on a corpse removed nothing and must not overwrite the credit of the blow that killed.
	if CharacterUtil.LiveHumanoidOf(outcome.Defender) == nil then
		return
	end
	local victim = Players:GetPlayerFromCharacter(outcome.Defender)
	if victim == nil then
		return
	end
	PlayerDeathSystem.RecordDamage(
		victim,
		outcome.Defender,
		Players:GetPlayerFromCharacter(outcome.Attacker),
		result.Damage,
		os.clock()
	)
end

-- Subscribes to the damage layer's applied-hit signal, and nothing else. Split out of Init for the same
-- reason EngagementSystem.Attach is. Idempotent.
function PlayerDeathSystem.Attach(): ()
	if appliedDisconnect then
		return
	end
	appliedDisconnect = DamageSystem.OnApplied(onDamageApplied)
end

function PlayerDeathSystem.Init(): ()
	if started then
		return
	end
	-- A comment in Main.server.lua cannot fail a boot. Subscribing before the damage layer exists would
	-- leave every death unattributed with no error anywhere.
	assert(DamageSystem.OnApplied ~= nil, "PlayerDeathSystem.Init() requires DamageSystem to be available")
	started = true

	noticeRemote = NetworkBridge.CreateRemoteEvent(DeathConstants.Network.RemoteNames.Notice)
	PlayerDeathSystem.Attach()

	-- `life` is Shared/PlayerLifecycle.lua's per-life Trove: the Died connection goes in it, so the
	-- previous body's listener is released on respawn and on leave by the structure, not by hand.
	lifecycle = PlayerLifecycle.BindAllPlayers({
		Scope = "PlayerDeathSystem",
		OnPlayerRemoving = PlayerDeathSystem.ReleasePlayer,
		OnCharacter = function(player: Player, character: Model, humanoid: Humanoid, life: Trove.TroveInstance)
			PlayerDeathSystem.BeginLife(player, character)
			life:Connect(humanoid.Died, function()
				PlayerDeathSystem.ConfirmDeath(player, character, os.clock())
			end)
		end,
	})

	logger:info("PlayerDeathSystem.Init() complete", {
		killCreditWindowSeconds = DamageConstants.KillCredit.WindowSeconds,
	})
end

-- Drops every life, every credit and the subscription. Spec-only, the same role
-- EngagementSystem.Reset/DamageSystem.Reset play for their own modules.
function PlayerDeathSystem.Reset(): ()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	if lifecycle then
		lifecycle:Clean()
		lifecycle = nil
	end
	table.clear(lifeStates)
	started = false
end

return PlayerDeathSystem :: Types.SystemModule & typeof(PlayerDeathSystem)
