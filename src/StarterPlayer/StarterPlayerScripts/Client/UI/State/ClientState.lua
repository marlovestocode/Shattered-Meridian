--!strict
--[[
	ClientState.lua

	Owns: the client-side reflection of server-validated state that UI surfaces render from --
	Fusion Value objects only, never computed here. Per software-architecture.md's "server owns
	truth, client owns feel" principle and ui-ux-philosophy.md's HUD sync rule ("no optimistic HUD
	state that can visibly desync from actual outcomes"), every field below is written to
	exclusively by a NetworkBridge remote handler inside Bootstrap(), never by a component, a
	Screen, or any other client-side computation.

	Does not own: computing any of these values -- CombatSystem/TierSystem/etc. compute them
	server-side; this module only stores what the server has already told the client. Does not
	own purely cosmetic, non-gameplay local state either (a button's hover flicker, a menu's
	open/closed flag) -- that belongs as scope-local Values inside the component or Screen that
	owns the visual, not here.

	Health/MaxHealth and Posture/MaxPosture are wired again, but NOT to the Combat_VitalsUpdated remote
	they used to read -- that remote's creator (CombatSystem.lua) was removed in the combat teardown
	and the rebuilt combat stack deliberately created no replacement. They now reflect the two places
	that genuinely own those numbers today: the local Humanoid for health, and Defense_StateChanged's
	guard pool for posture (guard IS the posture pool in the rebuilt stack -- DamageConstants.Guard's
	own header records that decision). See Bootstrap()'s own comment for why reading a replicated
	Humanoid property here is reflection rather than the optimistic HUD state this file forbids.
	InCombat is wired again, to Server/Combat/Engagement/EngagementSystem.lua's Engagement_Changed
	remote, alongside the Engagement value carrying the rest of that payload. Qi/MaxQi are
	wired to QiSystem.lua's Progression_QiUpdated
	remote, MeridianXP to MeridianSystem.lua's Progression_MeridianXPUpdated remote, and
	Tier/TierName/TierFloorXP/TierNextXP/TierPromotion to TierSystem.lua's Progression_TierUpdated
	remote -- all of those Systems replicate a real starting value the moment a profile loads (see
	each System's own OnProfileLoaded handler), so the render-only defaults below are only ever
	visible for the brief window before that first update arrives, the same "full bar looks correct
	before real data arrives" contract Health/Posture already established. QiDeviationSystem/
	ArtSystem/etc. remain empty Init()s, so this file has nothing else to wire yet.

	Second accepted pattern -- the Screen-returned handle: not every piece of server-reflected state
	belongs here. When a value has exactly one consumer and that consumer is a single Screen, routing
	it through this shared module would just add an indirection hop with no multi-consumer benefit to
	show for it -- so that state is instead kept as a Fusion.Value on the handle table the Screen's
	own Mount() returns, right next to (and following the same shape as) purely-cosmetic local state
	like a menu's open/closed flag. This file stays reserved for HUD-wide, multi-consumer vitals --
	the kind rendered by several independent components (VitalBar, DamageNumberLabel, etc.) that would
	otherwise each need their own remote listener. Existing examples of the Screen-returned-handle
	pattern, so a future Screen author has one place to look instead of re-deriving the choice from
	scratch: Screens/DevTools/DevMenu/init.lua, Screens/CombatFeedback/init.lua, and Screens/Menus/init.lua's
	own IsOpen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local EngagementConstants = require(ReplicatedStorage.Shared.Engagement.EngagementConstants)
local TierConstants = require(ReplicatedStorage.Shared.TierConstants)
local BountyConstants = require(ReplicatedStorage.Shared.BountyConstants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local SlowWatch = require(ReplicatedStorage.Shared.SlowWatch)
local Trove = require(ReplicatedStorage.Shared.Trove)

local logger = Logger.scope("ClientState")

type Scope = Fusion.Scope<typeof(Fusion)>

-- A tier-up that just happened, as opposed to the tier the player merely holds. Its own shape (not
-- a bare "did I just rank up" boolean) because a single large grant can cross two thresholds at
-- once, and a promotion moment that can't say what it came FROM can't render "IV -> VI" honestly.
-- Set to a fresh table on every real promotion and left non-nil afterward: consumers observe the
-- CHANGE (Fusion never treats two distinct tables as similar, so an observer fires every time),
-- rather than polling it as a flag they'd then have to clear.
export type TierPromotion = {
	From: number,
	To: number,
}

-- One Meridian XP grant, as it arrived. A FRESH TABLE PER GRANT for the same reason TierPromotion
-- above is one: two identical +25s in a row are two kills, and an observer must fire for both.
export type MeridianXPGain = {
	Amount: number,
	Reason: string?,
}

export type ClientState = {
	-- Render-only defaults (a full bar looks correct before real data arrives) -- not balance
	-- numbers. Wired in Bootstrap(): Health/MaxHealth from the local Humanoid, Posture/MaxPosture
	-- from Defense_StateChanged's guard pool. See this file's header for why neither goes through a
	-- vitals remote anymore.
	Health: Fusion.Value<number>,
	MaxHealth: Fusion.Value<number>,
	Posture: Fusion.Value<number>,
	MaxPosture: Fusion.Value<number>,
	-- Wired in Bootstrap() to QiSystem's Progression_QiUpdated remote (Server/Systems/QiSystem.lua).
	-- (Stamina was removed entirely -- Health and Posture are the game's only two combat vitals;
	-- Qi is progression/ability resource, not a combat vital.)
	Qi: Fusion.Value<number>,
	MaxQi: Fusion.Value<number>,
	-- Both wired in Bootstrap() to EngagementSystem's Engagement_Changed remote (Server/Combat/
	-- Engagement/EngagementSystem.lua). InCombat is kept as its own boolean rather than read off
	-- Engagement.InCombat because it long predates the payload and HUD/EngagementLine.lua already
	-- renders from it -- the two are written together, in the same handler, and cannot drift.
	InCombat: Fusion.Value<boolean>,
	-- nil before the first engagement of the session. The full payload -- opponent, damage traded, and
	-- the SecondsRemaining a consumer decays locally (see Types.EngagementPayload on why a duration
	-- crosses the wire rather than a deadline).
	Engagement: Fusion.Value<Types.EngagementPayload?>,
	-- Wired in Bootstrap() to MeridianSystem's Progression_MeridianXPUpdated remote
	-- (Server/Systems/MeridianSystem.lua) -- the core progression currency, not capped like the
	-- vitals above (see Types.MeridianXPUpdatePayload's own header).
	MeridianXP: Fusion.Value<number>,
	-- The most recent GRANT carried on that same remote (Types.MeridianXPUpdatePayload.Gained), nil
	-- until the first one this session. A login sync never sets it. Observed by HUD/init.lua, which
	-- turns it into the TierBadge's brief "+N" readout.
	MeridianXPGain: Fusion.Value<MeridianXPGain?>,
	-- Wired in Bootstrap() to TierSystem's Progression_TierUpdated remote (Server/Systems/
	-- TierSystem.lua). Tier/TierName are the server's authoritative tier identity; TierFloorXP and
	-- TierNextXP are the XP window it spans, so a consumer can compute its own progress fill against
	-- MeridianXP above and have it move on every kill rather than only on a promotion -- see
	-- Types.TierUpdatePayload's own header for why that split is deliberate and not a breach of this
	-- file's "never computed here" rule. TierNextXP is nil at the top of the ladder (there is no next
	-- threshold), which every consumer must handle rather than assuming a number.
	Tier: Fusion.Value<number>,
	TierName: Fusion.Value<string>,
	TierFloorXP: Fusion.Value<number>,
	TierNextXP: Fusion.Value<number?>,
	-- nil until the player is promoted in THIS session -- see the TierPromotion type above.
	TierPromotion: Fusion.Value<TierPromotion?>,
	-- Wired in Bootstrap() to BountySystem's Bounty_MarkedChanged remote (Server/Systems/
	-- BountySystem.lua) -- whether THIS player currently carries a Notoriety bounty, and what it pays
	-- whoever collects it. HUD-wide rather than a Screen-local handle (the rule this file's header
	-- lays out) because it has two independent consumers: the always-visible marked badge on the
	-- hotbar, and the bounty board menu, which highlights the row that is the player themselves.
	-- BountyReward/BountyStreak are nil exactly when BountyMarked is false.
	BountyMarked: Fusion.Value<boolean>,
	BountyReward: Fusion.Value<number?>,
	BountyStreak: Fusion.Value<number?>,
	-- Wired in Bootstrap() to EmoteSystem's Emote_UnlockedUpdated remote (Server/Systems/
	-- EmoteSystem.lua). A SET (not the wire payload's array shape -- see Types.
	-- EmoteUnlockedUpdatePayload's own header) so a future wheel UI can query "is this unlocked" in
	-- O(1) per slot instead of scanning an array every render.
	UnlockedEmoteIds: Fusion.Value<{ [Types.EmoteId]: true }>,
	-- Wired in Bootstrap() to EmoteSystem's Emote_LoadoutUpdated remote -- an ORDERED array mirroring
	-- Types.PlayerProfile.emoteLoadout exactly (this IS that field, replicated).
	EmoteLoadout: Fusion.Value<{ Types.EmoteId }>,
}

local ClientState = {}

function ClientState.new(scope: Scope): ClientState
	return {
		Health = scope:Value(100),
		MaxHealth = scope:Value(100),
		Posture = scope:Value(100),
		MaxPosture = scope:Value(100),
		Qi = scope:Value(100),
		MaxQi = scope:Value(100),
		InCombat = scope:Value(false),
		Engagement = scope:Value(nil :: Types.EngagementPayload?),
		MeridianXP = scope:Value(0),
		MeridianXPGain = scope:Value(nil :: MeridianXPGain?),
		-- Tier 1 / its real name / a 0 floor are the genuine bottom of the ladder
		-- (Constants.PlayerData.DefaultTier), not an invented placeholder -- a brand-new profile
		-- really does hold exactly this, so the pre-first-update render is correct rather than merely
		-- plausible. TierNextXP starts nil and is filled by the first update; a badge rendering a
		-- nil next-threshold shows an unsegmented bar for the brief window before it arrives, the
		-- same shape it uses at max tier.
		Tier = scope:Value(1),
		TierName = scope:Value(TierConstants.Tiers[1].Name),
		TierFloorXP = scope:Value(0),
		TierNextXP = scope:Value(nil :: number?),
		TierPromotion = scope:Value(nil :: TierPromotion?),
		-- Not marked is the correct pre-first-update state, not merely a safe one: BountySystem places
		-- a bounty only after a live kill streak, so nobody is ever marked at the moment they join.
		BountyMarked = scope:Value(false),
		BountyReward = scope:Value(nil :: number?),
		BountyStreak = scope:Value(nil :: number?),
		UnlockedEmoteIds = scope:Value({} :: { [Types.EmoteId]: true }),
		EmoteLoadout = scope:Value({} :: { Types.EmoteId }),
	}
end

function ClientState.Bootstrap(state: ClientState): ()
	-- Combat_VitalsUpdated is still not wired here, and never will be: CombatSystem.lua, its one
	-- creator, was removed in the combat teardown and the rebuilt stack deliberately created no
	-- replacement. DamageConstants.Network's own header states why -- the damage layer publishes ONE
	-- event (Combat_Feedback) and adding a vitals push would be a second way to describe the same fact.
	--
	-- Combat_InCombatChanged is gone for the same reason, but the FACT it carried is not: Engagement_
	-- Changed (Server/Combat/Engagement/EngagementSystem.lua) replaced it, carrying the boolean edge
	-- plus the opponent and damage the old one-field payload could not. Wired at the bottom of this
	-- function.
	--
	-- Health and Posture DO update again, from the two places that already own them, with no new
	-- remote on either side:
	--
	--   Health  <- the local Humanoid. Humanoid.Health is the single authority for health in the
	--             rebuilt stack (DamageSystem calls Humanoid:TakeDamage and keeps no parallel pool --
	--             see its own header, and StarterCharacterScripts/Health.server.lua's standing rule),
	--             and it replicates on its own. Reading it here is reflecting server-owned state,
	--             which is exactly this file's contract -- it is not the "optimistic HUD state" that
	--             contract exists to forbid, because nothing here computes or predicts it.
	--
	--   Posture <- Defense_StateChanged's Guard/GuardMax. GUARD IS THE POSTURE POOL in the rebuilt
	--             stack; there is deliberately no second meter (DamageConstants.Guard's own header
	--             records the decision and why). So the HUD's Posture tile renders the guard pool,
	--             which drains both from blocking (DefenseSystem) and from being hit without a guard
	--             up (DamageSystem.DrainGuard) -- the two halves that make it behave like posture.
	--
	-- Bound through Shared/PlayerLifecycle.lua, which closes a race this used to lose silently. It
	-- read the Humanoid with a raw FindFirstChildOfClass and returned if it was not there yet -- and
	-- CharacterAdded fires before every descendant has replicated, so losing that race meant the HUD's
	-- health tile sat at its ClientState.new() default for the ENTIRE life with nothing retrying and
	-- nothing logged. The binder waits the Humanoid out and only calls this once it exists.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "ClientState",
		OnCharacter = function(_character: Model, humanoid: Humanoid, life: Trove.TroveInstance)
			local function push(): ()
				state.Health:set(humanoid.Health)
				state.MaxHealth:set(humanoid.MaxHealth)
			end
			-- Tracked in the per-life Trove rather than left to die with the Humanoid. Both are
			-- correct here (the Humanoid IS the object being replaced), but relying on that means every
			-- reader has to know it -- and a life whose Humanoid outlives its usefulness for any reason
			-- would keep pushing a dead body's health into the live HUD.
			life:Connect(humanoid:GetPropertyChangedSignal("Health"), push)
			life:Connect(humanoid:GetPropertyChangedSignal("MaxHealth"), push)
			push()
		end,
	})

	logger:debug("Waiting for Defense_StateChanged remote")
	local defenseStateChanged = NetworkBridge.GetRemoteEvent(DefenseConstants.Network.RemoteNames.StateChanged)
	logger:debug("Defense_StateChanged remote found")

	defenseStateChanged.OnClientEvent:Connect(function(payload: unknown)
		if typeof(payload) ~= "table" then
			logger:warn("Malformed Defense_StateChanged payload ignored")
			return
		end
		local guard = (payload :: { [string]: unknown }).Guard
		local guardMax = (payload :: { [string]: unknown }).GuardMax
		if typeof(guard) ~= "number" or typeof(guardMax) ~= "number" then
			logger:warn("Malformed Defense_StateChanged payload ignored")
			return
		end
		state.Posture:set(guard :: number)
		state.MaxPosture:set(guardMax :: number)
	end)

	logger:debug("Waiting for Progression_QiUpdated remote")
	local qiUpdated = NetworkBridge.GetRemoteEvent(Constants.Qi.RemoteNames.QiUpdated)
	logger:debug("Progression_QiUpdated remote found")

	-- Watched (Shared/SlowWatch.lua): pushed on every Qi spend, so at a realm's upkeep rate a steady stream.
	qiUpdated.OnClientEvent:Connect(
		SlowWatch.Handler(logger, "ClientState.onQiUpdated", function(payload: Types.QiUpdatePayload)
			if typeof(payload) ~= "table" or typeof(payload.Qi) ~= "number" or typeof(payload.MaxQi) ~= "number" then
				logger:warn("Malformed Progression_QiUpdated payload ignored", { payload = tostring(payload) })
				return
			end

			logger:debug("Qi payload received", { qi = payload.Qi, maxQi = payload.MaxQi })
			state.Qi:set(payload.Qi)
			state.MaxQi:set(payload.MaxQi)
		end)
	)

	logger:debug("Waiting for Progression_MeridianXPUpdated remote")
	local meridianXpUpdated = NetworkBridge.GetRemoteEvent(Constants.Meridian.RemoteNames.XPUpdated)
	logger:debug("Progression_MeridianXPUpdated remote found")

	meridianXpUpdated.OnClientEvent:Connect(function(payload: Types.MeridianXPUpdatePayload)
		if typeof(payload) ~= "table" or typeof(payload.MeridianXP) ~= "number" then
			logger:warn("Malformed Progression_MeridianXPUpdated payload ignored", { payload = tostring(payload) })
			return
		end

		logger:debug("Meridian XP payload received", { meridianXp = payload.MeridianXP })
		state.MeridianXP:set(payload.MeridianXP)
		local gained = payload.Gained
		if typeof(gained) == "number" and gained > 0 then
			state.MeridianXPGain:set({
				Amount = gained,
				Reason = if typeof(payload.Reason) == "string" then payload.Reason else nil,
			})
		end
	end)

	logger:debug("Waiting for Progression_TierUpdated remote")
	local tierUpdated = NetworkBridge.GetRemoteEvent(TierConstants.RemoteNames.TierUpdated)
	logger:debug("Progression_TierUpdated remote found")

	tierUpdated.OnClientEvent:Connect(function(payload: Types.TierUpdatePayload)
		if
			typeof(payload) ~= "table"
			or typeof(payload.Tier) ~= "number"
			or typeof(payload.TierName) ~= "string"
			or typeof(payload.TierFloorXP) ~= "number"
		then
			logger:warn("Malformed Progression_TierUpdated payload ignored", { payload = tostring(payload) })
			return
		end
		-- TierNextXP and PreviousTier are both legitimately absent (top of the ladder; a non-promotion
		-- sync), so they're validated as "nil or the right type" rather than required outright -- a
		-- string in either field is still malformed and still rejected.
		if payload.TierNextXP ~= nil and typeof(payload.TierNextXP) ~= "number" then
			logger:warn("Malformed Progression_TierUpdated payload ignored", { payload = tostring(payload) })
			return
		end
		if payload.PreviousTier ~= nil and typeof(payload.PreviousTier) ~= "number" then
			logger:warn("Malformed Progression_TierUpdated payload ignored", { payload = tostring(payload) })
			return
		end

		logger:debug("Tier payload received", {
			tier = payload.Tier,
			tierName = payload.TierName,
			previousTier = payload.PreviousTier,
		})

		state.Tier:set(payload.Tier)
		state.TierName:set(payload.TierName)
		state.TierFloorXP:set(payload.TierFloorXP)
		state.TierNextXP:set(payload.TierNextXP)
		-- Set LAST, after the tier values a promotion consumer will read once this fires -- an
		-- observer on TierPromotion must never see the new promotion alongside the old tier. Only
		-- ever set for a real promotion; a plain sync leaves whatever was there untouched rather than
		-- clearing it, so a login sync arriving after a promotion can't erase that it happened.
		if payload.PreviousTier ~= nil then
			state.TierPromotion:set({ From = payload.PreviousTier, To = payload.Tier })
		end
	end)

	logger:debug("Waiting for Bounty_MarkedChanged remote")
	local markedChanged = NetworkBridge.GetRemoteEvent(BountyConstants.RemoteNames.MarkedChanged)
	logger:debug("Bounty_MarkedChanged remote found")

	markedChanged.OnClientEvent:Connect(function(payload: Types.BountyMarkedPayload)
		if typeof(payload) ~= "table" or typeof(payload.Marked) ~= "boolean" then
			logger:warn("Malformed Bounty_MarkedChanged payload ignored", { payload = tostring(payload) })
			return
		end

		logger:debug("Bounty marked payload received", { marked = payload.Marked, reward = payload.Reward })
		state.BountyMarked:set(payload.Marked)
		-- Cleared together with the flag rather than left stale: a badge that reads the reward while
		-- Marked is false would render the last bounty's value, and "you were worth 205" is a
		-- confusing thing to show a player who is no longer marked.
		if payload.Marked then
			state.BountyReward:set(if typeof(payload.Reward) == "number" then payload.Reward else nil)
			state.BountyStreak:set(if typeof(payload.Streak) == "number" then payload.Streak else nil)
		else
			state.BountyReward:set(nil)
			state.BountyStreak:set(nil)
		end
	end)

	logger:debug("Waiting for Emote_UnlockedUpdated remote")
	local unlockedUpdated = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.UnlockedUpdated)
	logger:debug("Emote_UnlockedUpdated remote found")

	unlockedUpdated.OnClientEvent:Connect(function(payload: Types.EmoteUnlockedUpdatePayload)
		if typeof(payload) ~= "table" or typeof(payload.EmoteIds) ~= "table" then
			logger:warn("Malformed Emote_UnlockedUpdated payload ignored", { payload = tostring(payload) })
			return
		end

		local unlockedSet: { [Types.EmoteId]: true } = {}
		for _, id in payload.EmoteIds do
			if typeof(id) == "string" then
				unlockedSet[id] = true
			end
		end

		logger:debug("Unlocked emotes payload received", { count = #payload.EmoteIds })
		state.UnlockedEmoteIds:set(unlockedSet)
	end)

	logger:debug("Waiting for Emote_LoadoutUpdated remote")
	local loadoutUpdated = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.LoadoutUpdated)
	logger:debug("Emote_LoadoutUpdated remote found")

	loadoutUpdated.OnClientEvent:Connect(function(payload: Types.EmoteLoadoutUpdatePayload)
		if typeof(payload) ~= "table" or typeof(payload.Loadout) ~= "table" then
			logger:warn("Malformed Emote_LoadoutUpdated payload ignored", { payload = tostring(payload) })
			return
		end

		local loadout: { Types.EmoteId } = {}
		for _, id in payload.Loadout do
			if typeof(id) == "string" then
				table.insert(loadout, id)
			end
		end

		logger:debug("Emote loadout payload received", { count = #loadout })
		state.EmoteLoadout:set(loadout)
	end)

	logger:debug("Waiting for Engagement_Changed remote")
	local engagementChanged = NetworkBridge.GetRemoteEvent(EngagementConstants.Network.RemoteNames.Changed)
	logger:debug("Engagement_Changed remote found")

	-- Validated field by field rather than trusted wholesale, the same shape every other handler in
	-- this function uses. InCombat is the only field that must be present for the payload to mean
	-- anything -- the opponent fields are legitimately nil on the leaving edge, and the numbers are
	-- defaulted rather than rejected so a partial payload degrades to a readable panel instead of a
	-- dropped update.
	engagementChanged.OnClientEvent:Connect(function(payload: unknown)
		if typeof(payload) ~= "table" then
			logger:warn("Malformed Engagement_Changed payload ignored")
			return
		end
		local fields = payload :: { [string]: unknown }
		if typeof(fields.InCombat) ~= "boolean" then
			logger:warn("Malformed Engagement_Changed payload ignored")
			return
		end

		local engagement: Types.EngagementPayload = {
			InCombat = fields.InCombat :: boolean,
			SecondsRemaining = if typeof(fields.SecondsRemaining) == "number" then fields.SecondsRemaining else 0,
			OpponentName = if typeof(fields.OpponentName) == "string" then fields.OpponentName else nil,
			OpponentUserId = if typeof(fields.OpponentUserId) == "number" then fields.OpponentUserId else nil,
			DamageDealt = if typeof(fields.DamageDealt) == "number" then fields.DamageDealt else 0,
			DamageTaken = if typeof(fields.DamageTaken) == "number" then fields.DamageTaken else 0,
			LastOutcomeKind = if typeof(fields.LastOutcomeKind) == "string" then fields.LastOutcomeKind else nil,
		}

		logger:debug("Engagement payload received", {
			inCombat = engagement.InCombat,
			opponent = engagement.OpponentName,
		})
		state.Engagement:set(engagement)
		state.InCombat:set(engagement.InCombat)
	end)
end

return ClientState
