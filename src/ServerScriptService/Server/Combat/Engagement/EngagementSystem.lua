--!strict
--[[
	EngagementSystem.lua

	Owns: the combat tag -- who is currently fighting whom, for how much longer, and what they have
	traded. One table, keyed by Player, refreshed by real exchanges and reclaimed on expiry.

	    HitboxEngine     where the volume is, who is inside it
	    DefenseSystem    what kind of hit that was
	    DamageSystem     how much it hurts, what it does to you
	    GrabSystem       what happens instead of ordinary knockback, when a move says so
	    EngagementSystem who is in a fight right now, and with whom                      <- this module

	A SIBLING OF THE ATTACK LAYER, NOT A FIFTH LAYER STACKED ON TOP -- the same shape GrabSystem's own
	header argues for at length, for the same reasons. It subscribes to DamageSystem.OnApplied (that
	function's own documented extension point) and is read by everyone else through Attributes, never
	by being required. No existing combat layer gained a dependency to make this possible.

	THIS IS A REBUILD OF SOMETHING THAT WAS DELETED, INTO SOCKETS THAT WERE LEFT BEHIND. The combat
	teardown removed CombatSystem.lua, which owned the tag; every CONSUMER of it survived, wired to
	nothing. All of them are live again, five without any change to themselves:

	  Constants.Attributes.InCombat      read every frame by Client/Parkour's ParkourController
	                                     (resolveCombatOwned) -- written by nobody until this module
	  EmoteDefinition.CombatAllowed      authored on all 11 emotes, validated by EmoteRegistry, and
	                                     never once read (EmoteSystem's header admits the loss)
	  HUD/EngagementLine.lua             renders "AWAITING ENGAGEMENT" forever without this edge
	  ClientState.InCombat               documented as having "no source at all in the rebuilt stack"
	  CombatState.inCombatUntil          the field this module's own state descends from
	  CombatConstants.InCombatDuration-  a live tunable with zero readers, re-homed to
	  Seconds                            EngagementConstants.TagDurationSeconds

	WHAT REFRESHES A TAG, AND WHAT DELIBERATELY DOES NOT. Every resolved contact between two taggable
	combatants refreshes BOTH sides -- including Blocked/Parried/Trade, which deal no health damage at
	all. Being answered is still being in a fight; the pool a block drains is the same pool a hit
	drains (DamageConstants.Guard), and a defender who never got tagged could parry all day and stay
	free of every consequence below.

	What does NOT refresh a tag: throwing a swing that hits nothing, or opening Block with nobody
	attacking. Both are direct playtest feedback preserved verbatim from the deleted system's own notes
	-- "throw a punch" alone is not "actively fighting somebody," and an earlier pass got this wrong.

	REFRESH MEANS ASSIGN FORWARD, NOT math.max. A coarse signal like this one should reset its full
	duration on every fresh trigger rather than extend whatever longer deadline happened to be running
	-- the surviving design note is explicit, and it is the opposite of how the specific per-action
	lockouts (attackEndsAt, stunExpiry) compose.

	A DEBUG DUMMY DOES TAG YOU, as of 2026-08-25, and this reversed on the first playtest. Dummies
	briefly carried EngagementConstants.DummyTag and were exempt, on the reasoning that a practice
	target is not an adversary. Two things were wrong with that: a dummy is the only sparring partner a
	solo tester has, so the exemption made this entire layer unreachable without a second client, and it
	contradicted DebugDummySystem's own "A DUMMY IS A REAL COMBATANT, NOT A MOCK" opening. Nothing
	applies the tag today -- see EngagementConstants.DummyTag for the case it is still kept for, which
	is a scenery target ORDINARY players swing at rather than admin-spawned dev tooling.

	THE OPPONENT PREDICATE IS NEGATIVE, AND THAT REVERSAL IS THE ARGUMENT FOR IT. A combatant is
	taggable UNLESS it carries EngagementConstants.DummyTag, rather than being taggable only when
	Players:GetPlayerFromCharacter(model) ~= nil. Under the positive form, making the dummy tag would
	have meant editing this module's own predicate; under this one it was a single deletion in the
	module that owns the rig, with nothing to change here. The same holds the day a bot or an NPC boss
	lands: something that fights back SHOULD tag you, and it will, for free.

	THREE CONSEQUENCES, ONE OF WHICH IS LOUD:
	  * Constants.Attributes.InCombat is written on each true/false edge, through a Shared/
	    ChangeNotifier (the module built for exactly this, and named in that Attribute's own comment).
	    ParkourConstants.CombatGate.BlockedStates refuses Slide, Leap and WallRun while it
	    is true -- five movement states that have NEVER been gated in the current build, because
	    nothing has set this Attribute since the teardown. Tuning TagDurationSeconds therefore reaches
	    a great deal further than the HUD line it visibly drives.
	  * Emotes: EmoteSystem refuses a CombatAllowed = false emote while the Attribute is set. It reads
	    the ATTRIBUTE, not this module -- a Systems/ module has no business requiring a Combat/ one,
	    and the seam already existed.
	  * Combat logout: a tagged player disconnecting is warned about (which reaches the F5 Live
	    Console capture ring) and fires GameplayEvents.CombatLogged. NOTHING IS PENALISED AND NOTHING
	    IS PERSISTED -- this module reports the fact and lets a consumer decide, which is the contract
	    GameplayEvents.lua's own header sets out. There is no subscriber today.

	THE Players SERVICE IS TOUCHED IN EXACTLY ONE PLACE. onDamageApplied resolves both characters to
	Players and hands the pair to RecordExchange, which holds all of the behaviour and does no lookup
	at all; ReleasePlayer is likewise the whole of the PlayerRemoving path, with Init doing nothing but
	binding the signal to it. That is partly hygiene -- the pair used to be re-derived a second time
	inside tag(), once from each end, to spell one name -- and partly the only way this module could be
	tested at all: Instance.new("Player") ERRORS in this project's headless harness (Tests/Combat/
	Attack/AttackRequestSystem.spec.lua's header records the same limit), so behaviour reachable only
	through a Players lookup is behaviour that ships on a playtest and nothing else. Tests/Combat/
	Engagement/EngagementSystem.spec.lua drives real rigs through the real four layers, captures the
	real DefenseOutcome, and replays it through RecordExchange with stand-in identities.

	KEYED BY THE LIVE Player INSTANCE, never tostring(player), and scrubbed BOTH WAYS on
	PlayerRemoving. Dropping the leaver's own row is the obvious half; the half that gets forgotten is
	that every OTHER engagement may still hold them as an opponent, and a stale Player reference in a
	long-lived table is precisely the unbounded-reference leak RivalrySystem's header calls out by
	name (and that the deleted CombatSystem needed a clearRecentOpponentReferencesTo to fix). Instance
	keying is what makes that scrub O(live engagements) instead of a string-index rebuild.

	NO Shared/AmortizedReclaim HERE, and it is worth saying why, because this module looks exactly
	like its use case. That helper's Step signature is `{ [Model]: V }` -- it sweeps Model-keyed maps
	by testing Parent == nil. This table is Player-keyed and expires on a CLOCK, not on despawn, so
	there is no Instance to test and the helper cannot type-check against it. The sweep here is a
	plain walk of a table bounded by player count.

	Does not own: what a hit costs (DamageResolver), what kind of hit it was (DefenseSystem), whether
	an action is legal (each gate's own owner -- this module only publishes the Attribute they read),
	the parkour gate itself (ParkourConstants.CombatGate), or any presentation (HUD/EngagementLine.lua
	and HUD/EngagementDetail.lua).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local ChangeNotifier = require(ReplicatedStorage.Shared.ChangeNotifier)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local EngagementConstants = require(ReplicatedStorage.Shared.Engagement.EngagementConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local DamageSystem = require(script.Parent.Parent.Damage.DamageSystem)

type DefenseOutcome = DefenseTypes.DefenseOutcome
type DamageResult = DamageTypes.DamageResult

local logger = Logger.scope("EngagementSystem")

local EngagementSystem = {}

-- State ---------------------------------------------------------------------------------------------

-- One live engagement per tagged player. An entry EXISTS only while the tag is live: expiry deletes
-- the row rather than leaving a false-flagged husk, so `engagements[player] ~= nil` and "is in
-- combat" are the same question and cannot drift apart.
export type Engagement = {
	player: Player,
	-- os.clock(). The tag itself; everything else on this row is description.
	inCombatUntil: number,
	-- When the CURRENT engagement began -- not refreshed by later exchanges, unlike inCombatUntil.
	-- What makes damageDealt/damageTaken mean "this fight" rather than "this session".
	startedAt: number,
	opponentName: string,
	-- nil when the opponent is not a Player (a future bot or NPC boss). Kept alongside opponentName
	-- rather than derived from it at read time -- a name is not a stable identity.
	opponentUserId: number?,
	lastOutcomeKind: DefenseTypes.OutcomeKind,
	damageDealt: number,
	damageTaken: number,
	-- Stamped at each exchange, capped at EngagementConstants.MaxTrackedOpponents. Nothing reads this
	-- yet -- see that constant's own header on the proximity refresh it is kept bounded for.
	recentOpponents: { [Player]: number },
}

local engagements: { [Player]: Engagement } = {}

-- One side of an exchange, with its character and its identity ALREADY RESOLVED. Player is nil for a
-- combatant that is not one (a dummy, or a future bot or NPC boss).
--
-- THE POINT OF THIS TYPE IS THAT RESOLVING IT IS SOMEBODY ELSE'S JOB. Every Players:GetPlayerFrom-
-- Character call in this module lives in onDamageApplied, the ten-line adapter at the bottom of the
-- file, and RecordExchange -- which holds all of the actual behaviour -- is handed the answers. Two
-- things fall out of that, and the second is why it is shaped this way:
--   * The pair is looked up ONCE per exchange rather than twice. The previous shape re-derived each
--     side's Player inside tag(), once from each end, to spell one name.
--   * The behaviour becomes reachable from a spec. Players cannot be fabricated in this project's
--     headless harness -- Instance.new("Player") errors outright, which Tests/Combat/Attack/
--     AttackRequestSystem.spec.lua's own header already records as an accepted limit -- so a module
--     that could only be entered through a Players lookup would have been untestable in every path
--     that matters, and would have shipped on a playtest alone.
export type Combatant = {
	Model: Model,
	Player: Player?,
}

-- The one thing that must be remembered ACROSS a row's own lifetime: what InCombat value each player
-- was last told. A row is deleted on expiry, so it cannot hold this itself -- the false edge has to
-- be publishable at the exact moment the row stops existing.
local inCombatNotifier = ChangeNotifier.New() :: ChangeNotifier.ChangeNotifierInstance<boolean>

local changedRemote: RemoteEvent? = nil

-- Remote coalescing (EngagementConstants.Network.MinPushIntervalSeconds): when each player was last
-- sent a payload, who it named, and whether a newer one is waiting for the interval to pass.
local lastPushAt: { [Player]: number } = {}
local lastPushedInCombat: { [Player]: boolean } = {}
local lastPushedOpponent: { [Player]: string? } = {}
local pushPending: { [Player]: boolean } = {}
local appliedDisconnect: (() -> ())? = nil
local heartbeatTrove = Trove.New()
local lifecycleTrove = Trove.New()
local started = false

local function debugLog(flag: boolean, message: string, data: { [string]: any }?): ()
	if EngagementConstants.Debug.Enabled and flag then
		logger:debug(message, data)
	end
end

-- Opponent resolution -------------------------------------------------------------------------------

-- Whether a contact involving `model` should tag anybody. See this file's header and
-- EngagementConstants.DummyTag on why this asks what the model is NOT rather than what it is.
local function isTaggable(model: Model): boolean
	return not CollectionService:HasTag(model, EngagementConstants.DummyTag)
end

-- Publishing ------------------------------------------------------------------------------------------

local function buildPayload(player: Player, now: number): Types.EngagementPayload
	local engagement = engagements[player]
	if not engagement then
		return {
			InCombat = false,
			SecondsRemaining = 0,
			DamageDealt = 0,
			DamageTaken = 0,
		}
	end
	return {
		InCombat = true,
		-- Clamped at zero rather than allowed negative: this crosses to a client that decays it
		-- locally, and a negative start would read as an already-expired panel that still says it is
		-- live. Step deletes the row on the very next tick anyway.
		SecondsRemaining = math.max(engagement.inCombatUntil - now, 0),
		OpponentName = engagement.opponentName,
		OpponentUserId = engagement.opponentUserId,
		DamageDealt = engagement.damageDealt,
		DamageTaken = engagement.damageTaken,
		LastOutcomeKind = engagement.lastOutcomeKind,
	}
end

-- Writes the Attribute on the true/false edge only, and pushes the payload to the owning client.
--
-- THE ATTRIBUTE GOES THROUGH ChangeNotifier; THE REMOTE DOES NOT. They answer different questions.
-- The Attribute is a LEVEL that parkour polls every frame -- rewriting it with the same value fires a
-- pointless AttributeChanged for every reader -- so only the edge matters. The payload is a SNAPSHOT
-- whose damage totals and opponent change WITHOUT the boolean changing, so gating it on the edge
-- would freeze the panel at whatever the first hit of the fight said. This split is why the
-- Attribute's own comment in Constants.lua calls the remote and the Attribute complementary rather
-- than redundant: "the HUD badge wants the edge, parkour wants the level."
local function publish(player: Player, now: number): ()
	local inCombat = engagements[player] ~= nil

	if ChangeNotifier.Update(inCombatNotifier, player, inCombat) then
		-- THE nil-Character GUARD IS LOAD-BEARING, not defensive habit. CharacterUtil.HumanoidOf takes
		-- a Model, not a Model?, and indexes it immediately -- so handing it a nil Character throws.
		-- Player.Character IS legitimately nil for a real stretch of a normal session: between death
		-- and respawn, and before the first character loads. That window overlaps this call almost
		-- exactly, because the most common way to stop being in combat is to be killed, and the
		-- expiry edge lands five seconds later with the body already gone. Unguarded, that threw out
		-- of Step and took the rest of the Heartbeat's engagement sweep with it.
		--
		-- Nothing is lost by skipping the write: the Attribute lives on a Humanoid that no longer
		-- exists, and the fresh character arrives without it, which is the same false this was trying
		-- to write. The notifier has already recorded the edge, so the next real transition still
		-- publishes correctly.
		local character = player.Character
		local humanoid = if character then CharacterUtil.HumanoidOf(character) else nil
		if humanoid then
			humanoid:SetAttribute(Constants.Attributes.InCombat, inCombat)
		end
	end

	local remote = changedRemote
	if not remote then
		return
	end
	-- An edge or a new opponent goes out now; anything else waits out the interval and is flushed by
	-- Step. See EngagementConstants.Network.MinPushIntervalSeconds.
	local engagement = engagements[player]
	local opponent = if engagement then engagement.opponentName else nil
	local urgent = lastPushAt[player] == nil
		or inCombat ~= lastPushedInCombat[player]
		or opponent ~= lastPushedOpponent[player]
	if urgent or now - lastPushAt[player] >= EngagementConstants.Network.MinPushIntervalSeconds then
		lastPushAt[player] = now
		lastPushedInCombat[player] = inCombat
		lastPushedOpponent[player] = opponent
		pushPending[player] = nil
		remote:FireClient(player, buildPayload(player, now))
	else
		pushPending[player] = true
	end
end

-- Tagging --------------------------------------------------------------------------------------------

-- Caps recentOpponents by evicting the least recently seen entry. A fixed, tiny bound, so a linear
-- scan for the oldest costs less than any structure that would keep it sorted.
local function stampRecentOpponent(engagement: Engagement, opponent: Player, now: number): ()
	if engagement.recentOpponents[opponent] == nil then
		local count = 0
		local oldestPlayer: Player? = nil
		local oldestSeenAt = math.huge
		for trackedPlayer, seenAt in engagement.recentOpponents do
			count += 1
			if seenAt < oldestSeenAt then
				oldestSeenAt = seenAt
				oldestPlayer = trackedPlayer
			end
		end
		if count >= EngagementConstants.MaxTrackedOpponents and oldestPlayer then
			engagement.recentOpponents[oldestPlayer] = nil
		end
	end
	engagement.recentOpponents[opponent] = now
end

-- Refreshes (or opens) `player`'s engagement against `opponent`. `dealt`/`taken` are this one
-- contact's contribution from THIS player's point of view -- the caller decides which side of the
-- exchange they were on, so this function never has to know.
local function tag(
	player: Player,
	opponent: Combatant,
	kind: DefenseTypes.OutcomeKind,
	dealt: number,
	taken: number,
	now: number
): ()
	local opponentPlayer = opponent.Player
	local engagement = engagements[player]

	if not engagement then
		engagement = {
			player = player,
			inCombatUntil = 0,
			startedAt = now,
			opponentName = opponent.Model.Name,
			opponentUserId = nil,
			lastOutcomeKind = kind,
			-- ZERO, not carried over from whatever row was here before -- there was none. This is the
			-- reset that makes damageDealt/damageTaken read as "this fight" rather than "this session":
			-- a lapsed tag DELETES its row (see the `engagements` declaration), so the next exchange
			-- lands here and starts both totals again.
			damageDealt = 0,
			damageTaken = 0,
			recentOpponents = {},
		}
		engagements[player] = engagement
	end
	local row = engagement :: Engagement

	-- Assigned forward, never math.max'd -- see this file's header.
	row.inCombatUntil = now + EngagementConstants.TagDurationSeconds
	row.opponentName = if opponentPlayer then opponentPlayer.Name else opponent.Model.Name
	row.opponentUserId = if opponentPlayer then opponentPlayer.UserId else nil
	row.lastOutcomeKind = kind
	row.damageDealt += dealt
	row.damageTaken += taken

	if opponentPlayer then
		stampRecentOpponent(row, opponentPlayer, now)
	end

	debugLog(EngagementConstants.Debug.LogTagged, "Engagement tagged", {
		player = player.Name,
		opponent = row.opponentName,
		kind = kind,
		dealt = row.damageDealt,
		taken = row.damageTaken,
	})
end

-- Drops `player`'s row and publishes the resulting false edge. Shared by expiry and by an explicit
-- clear, so the two paths cannot drift.
local function clear(player: Player, now: number, reason: string): ()
	if engagements[player] == nil then
		return
	end
	engagements[player] = nil
	debugLog(EngagementConstants.Debug.LogExpired, "Engagement cleared", { player = player.Name, reason = reason })
	publish(player, now)
end

-- Public read surface ----------------------------------------------------------------------------------

function EngagementSystem.IsInCombat(player: Player): boolean
	return engagements[player] ~= nil
end

-- A read-only projection, never the live row -- the same contract the deleted CombatSystem.
-- GetCombatState kept, and the reason nothing outside this module can corrupt a tag by holding a
-- reference to it. Returns nil when the player is not tagged; nil and "not in combat" are the same
-- fact here by construction (see the `engagements` declaration).
function EngagementSystem.GetEngagement(player: Player, now: number?): Types.EngagementPayload?
	if engagements[player] == nil then
		return nil
	end
	return buildPayload(player, now or os.clock())
end

-- One live engagement, with the owning player's identity alongside their combat data.
export type EngagementRow = {
	UserId: number,
	Name: string,
	-- Seconds since this engagement opened. The sort key GetAll orders on, and deliberately NOT part
	-- of Types.EngagementPayload -- a client has no use for it, and widening a network payload to
	-- carry a server-side sort key is how payloads rot.
	AgeSeconds: number,
	Engagement: Types.EngagementPayload,
}

-- Every live engagement, most recently opened first. Built for a server-wide admin table --
-- DevMenuSystem.buildRosterEntry still returns `Snapshot = nil` with a comment blaming the removed
-- combat system -- so it is shaped for that consumer now and becomes a formatting change later
-- rather than a re-derivation. NOTHING CALLS THIS YET, which by this codebase's own reachability rule
-- makes it the one function here that is not proven wired; it is a deliberate, documented stub of a
-- read surface, not an oversight.
function EngagementSystem.GetAll(now: number?): { EngagementRow }
	local resolvedNow = now or os.clock()
	local rows: { EngagementRow } = {}
	for player, engagement in engagements do
		table.insert(rows, {
			UserId = player.UserId,
			Name = player.Name,
			AgeSeconds = resolvedNow - engagement.startedAt,
			Engagement = buildPayload(player, resolvedNow),
		})
	end
	table.sort(rows, function(left: EngagementRow, right: EngagementRow): boolean
		return left.AgeSeconds < right.AgeSeconds
	end)
	return rows
end

function EngagementSystem.TaggedCount(): number
	local count = 0
	for _ in engagements do
		count += 1
	end
	return count
end

-- The loop --------------------------------------------------------------------------------------------

-- One frame. `now` is the caller's clock, matching HitboxEngine.Step/DefenseSystem.Step/
-- DamageSystem.Step/GrabSystem.Step's own contract -- a spec drives this on a synthetic clock, so
-- this function must never read os.clock() itself.
--
-- Expired rows are collected before being dropped rather than dropped inside the walk: `clear`
-- publishes, publishing runs consumer code that can reach this table, and mutating a table mid-
-- iteration is undefined in Luau.
function EngagementSystem.Step(_deltaTime: number, now: number): ()
	-- Coalesced pushes whose interval has passed. Collected first for the same mutation-during-walk
	-- reason as the expiry sweep below.
	local due: { Player }? = nil
	for player in pushPending do
		local pushedAt = lastPushAt[player]
		if pushedAt == nil or now - pushedAt >= EngagementConstants.Network.MinPushIntervalSeconds then
			due = due or {}
			table.insert(due :: { Player }, player)
		end
	end
	if due then
		for _, player in due :: { Player } do
			pushPending[player] = nil
			if engagements[player] ~= nil then
				publish(player, now)
			end
		end
	end

	local expired: { Player }? = nil
	for player, engagement in engagements do
		if now >= engagement.inCombatUntil then
			expired = expired or {}
			table.insert(expired :: { Player }, player)
		end
	end
	if not expired then
		return
	end
	for _, player in expired :: { Player } do
		clear(player, now, "Expired")
	end
end

-- Lifecycle -------------------------------------------------------------------------------------------

-- ONE RESOLVED EXCHANGE, REFRESHING BOTH SIDES OF IT. The whole of this module's tagging behaviour
-- lives here; onDamageApplied below is the adapter that resolves a DefenseOutcome into the two
-- Combatants this wants (see that type's header on why the split, and why it is not merely a spec
-- accommodation).
--
-- `damage` is the health damage the DEFENDER took, which is the only damage a single contact carries
-- -- it becomes the attacker's damageDealt and the defender's damageTaken. It is legitimately ZERO
-- for Blocked/Parried/Trade, and those still tag: being answered is still being in a fight, and a
-- defender who never got tagged could parry all day and stay free of every consequence the tag
-- carries.
--
-- Three things are refused, in order:
--   * A SELF-HIT. A move can resolve against its own thrower (DamageSystem's own applyOutcome has the
--     identical Defender ~= Attacker check before it sends the defender's feedback copy). Tagging
--     yourself for hitting yourself would be a fight with one participant, and would let a player
--     hold their own tag open indefinitely with no opponent at all.
--   * A CONTACT INVOLVING A DUMMY, either side -- see isTaggable and EngagementConstants.DummyTag.
--   * AN EXCHANGE WITH NO PLAYER IN IT. Two bots hitting each other is a real fight and a perfectly
--     legal outcome; it simply has nothing this module can key a row by, since the table is keyed by
--     Player. Nothing is lost by dropping it, because nothing would ever read the row.
function EngagementSystem.RecordExchange(
	attacker: Combatant,
	defender: Combatant,
	kind: DefenseTypes.OutcomeKind,
	damage: number,
	now: number
): ()
	if attacker.Model == defender.Model then
		return
	end
	if not isTaggable(attacker.Model) or not isTaggable(defender.Model) then
		return
	end
	if not attacker.Player and not defender.Player then
		return
	end

	local attackerPlayer = attacker.Player
	if attackerPlayer then
		tag(attackerPlayer, defender, kind, damage, 0, now)
		publish(attackerPlayer, now)
	end
	local defenderPlayer = defender.Player
	if defenderPlayer then
		tag(defenderPlayer, attacker, kind, 0, damage, now)
		publish(defenderPlayer, now)
	end
end

-- The adapter, and deliberately nothing more than one: resolve both characters to Players, hand the
-- pair over. Every Players lookup in this module is on these two lines.
--
-- os.clock() RATHER THAN outcome.SampleTime, which is the one judgement call here. SampleTime is the
-- engine's own substep clock for the contact and is what every other consumer in this stack ORDERS
-- against -- but it can sit slightly behind the frame's own clock, and a tag DEADLINE derived from it
-- would expire fractionally early. The damage layer hands outcomes over from inside its own Step, so
-- os.clock() here is the same frame, and what this module is measuring is a duration rather than an
-- ordering.
local function onDamageApplied(outcome: DefenseOutcome, result: DamageResult): ()
	EngagementSystem.RecordExchange(
		{ Model = outcome.Attacker, Player = Players:GetPlayerFromCharacter(outcome.Attacker) },
		{ Model = outcome.Defender, Player = Players:GetPlayerFromCharacter(outcome.Defender) },
		outcome.Kind,
		result.Damage,
		os.clock()
	)
end

-- Seeds a joining player's "last reported" slot at false, so their FIRST tag registers as a real
-- observed edge. Bound to Players.PlayerAdded by Init, and the exact counterpart of ReleasePlayer.
--
-- THIS IS NOT OPTIONAL BOOKKEEPING, WHICH IS EASY TO ASSUME FROM ITS SIZE. ChangeNotifier.Update
-- returns false for a player it has never seen -- deliberately, since establishing a baseline is not
-- a change (that module's own header). Without this seed the first Update of a session compares
-- against nil, reports "no change", and the InCombat Attribute is never written on the rising edge of
-- a player's very first fight -- so parkour's combat gate would not bite until their SECOND one. It
-- was a spec on the Attribute edges that caught this; nothing about the shape of the code suggests
-- it, which is why it is a named function rather than a closure inside Init.
function EngagementSystem.TrackPlayer(player: Player): ()
	ChangeNotifier.Update(inCombatNotifier, player, false)
end

-- Drops a departing player from this module entirely, reporting the combat logout if they had a live
-- tag. Bound to Players.PlayerRemoving by Init, and public for the same reason RecordExchange is: it
-- is the half of this module with the most to get wrong and the least chance of a playtest catching
-- it, and a spec cannot reach it through a Players signal it has no way to raise.
--
-- THE SCRUB IS TWO-WAY, AND THE SECOND HALF IS THE ONE THAT GETS FORGOTTEN. Dropping the leaver's own
-- row is obvious. What is easy to miss is that every OTHER engagement may still hold them -- in
-- recentOpponents, keyed by the departed Player instance itself -- and a stale Player reference in a
-- long-lived table is precisely the unbounded-reference leak RivalrySystem's header calls out by
-- name (and that the deleted CombatSystem needed a clearRecentOpponentReferencesTo to fix).
--
-- opponentName IS DELIBERATELY LEFT INTACT on the surviving side. Their panel should keep naming who
-- they were fighting for the rest of the tag rather than blanking the moment that player quits, and a
-- string holds nothing alive. Only opponentUserId is cleared, which is what keeps the identity check
-- honest once the Name is no longer resolvable to anyone.
function EngagementSystem.ReleasePlayer(player: Player): ()
	local engagement = engagements[player]
	if engagement then
		-- The combat-logout report. A fact, not a punishment -- see this file's header: nothing
		-- subscribes to CombatLogged today and nothing is persisted.
		logger:warn("Player disconnected while in combat", {
			player = player.Name,
			userId = player.UserId,
			opponent = engagement.opponentName,
			opponentUserId = engagement.opponentUserId,
			secondsRemaining = math.max(engagement.inCombatUntil - os.clock(), 0),
			damageDealt = engagement.damageDealt,
			damageTaken = engagement.damageTaken,
		})
		debugLog(EngagementConstants.Debug.LogCombatLogout, "Combat logout", { player = player.Name })
		GameplayEvents.FireCombatLogged(player, engagement.opponentName, engagement.opponentUserId)
	end

	-- Their own row, and the notifier slot keyed by them. No publish: they are gone, and FireClient at
	-- a departed player is at best wasted and at worst an error.
	engagements[player] = nil
	ChangeNotifier.Clear(inCombatNotifier, player)
	lastPushAt[player] = nil
	lastPushedInCombat[player] = nil
	lastPushedOpponent[player] = nil
	pushPending[player] = nil

	for _, other in engagements do
		other.recentOpponents[player] = nil
		if other.opponentUserId == player.UserId then
			other.opponentUserId = nil
		end
	end
end

-- Subscribes to the damage layer's outcome signal, and nothing else. Split out of Init for the same
-- reason DamageSystem.Attach/DefenseSystem.Attach/GrabSystem.Attach are: a spec has to drive this
-- system on a synthetic clock, and it cannot do that if the only way to receive applied hits is to
-- also start a real Heartbeat racing its own Step calls. Idempotent.
function EngagementSystem.Attach(): ()
	if appliedDisconnect then
		return
	end
	appliedDisconnect = DamageSystem.OnApplied(onDamageApplied)
end

function EngagementSystem.Init(): ()
	if started then
		return
	end
	-- Same "a comment in Main.server.lua cannot fail a boot" posture as every Init in this stack. This
	-- module's Step only reclaims ITS OWN rows, so an out-of-order boot costs at most one extra frame
	-- of a stale tag rather than a wrong outcome -- asserted anyway.
	assert(DamageSystem.OnApplied ~= nil, "EngagementSystem.Init() requires DamageSystem to be available")
	started = true

	changedRemote = NetworkBridge.CreateRemoteEvent(EngagementConstants.Network.RemoteNames.Changed)

	EngagementSystem.Attach()

	heartbeatTrove:Connect(RunService.Heartbeat, function(deltaTime: number)
		EngagementSystem.Step(deltaTime, os.clock())
	end)

	-- Through Shared/PlayerLifecycle rather than raw Players wiring? No, and deliberately -- one of
	-- that module's own five documented exemptions. Its value is resolving a Humanoid per life and
	-- handing over a per-life Trove; this module wants neither. It never touches a character except
	-- inside publish (which resolves the Humanoid itself, at the moment of an edge, and correctly does
	-- nothing when there is not one yet), and it holds no per-life state to tear down. What it needs
	-- is two player-scoped moments, and PlayerRemoving is the one carrying real weight.
	lifecycleTrove:Connect(Players.PlayerAdded, EngagementSystem.TrackPlayer)

	lifecycleTrove:Connect(Players.PlayerRemoving, EngagementSystem.ReleasePlayer)

	logger:info("EngagementSystem.Init() complete")
end

function EngagementSystem.Shutdown(): ()
	heartbeatTrove:Clean()
	lifecycleTrove:Clean()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	started = false
end

-- Drops every engagement and every subscription. Spec-only, so one case cannot serve another its
-- state -- the same role DamageSystem.Reset/DefenseSystem.Reset/GrabSystem.Reset play. A hard wipe
-- rather than a graceful per-player clear: Reset must never depend on the Instances it is discarding
-- still being valid, and a spec Destroys its own rigs in afterEach regardless.
function EngagementSystem.Reset(): ()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	-- THE NOTIFIER HAS TO GO WITH THE ROWS, and it is the one piece of state here that a table.clear
	-- would not have reached. It deliberately outlives any single row (see its declaration -- the
	-- false edge must be publishable at the moment a row stops existing), which means wiping the rows
	-- alone would leave it still reporting `true` for players who were tagged when Reset ran. The next
	-- tag for such a player would then compare equal, Update would return false, and the Attribute
	-- write would be silently skipped -- one spec case quietly breaking the next one through state
	-- neither of them mentions.
	for player in engagements do
		ChangeNotifier.Clear(inCombatNotifier, player)
	end
	table.clear(engagements)
	changedRemote = nil
end

return EngagementSystem :: Types.SystemModule & typeof(EngagementSystem)
