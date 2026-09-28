--!strict
-- Covers the fight-to-grow spine end to end:
--
--   PlayerDeathSystem.ConfirmDeath -> (PlayerKilled) -> RewardSystem -> ProgressionSystem
--     -> MeridianSystem.AwardKillXP -> PlayerDataSystem.Transform -> MeridianXPAwarded -> TierSystem
--
-- WHAT IS REAL HERE. Every module in that chain runs its production code, including the profile write:
-- PlayerDataSystem.InstallProfileForSpec gives a stand-in Player a genuinely loaded profile, so the
-- award goes through the real Transform and TierSystem.Evaluate reads it back through the real
-- GetProfile. What is NOT exercised is PlayerKilled's BindableEvent hop into RewardSystem for the
-- award itself: a BindableEvent deep-copies table arguments, so a stand-in Player would arrive as a
-- copy with no profile behind it (Instance.new("Player") errors in this harness -- see
-- PlayerDeathSystem.spec.lua). The chain is therefore driven by handing RewardSystem.HandlePlayerKilled
-- the exact (victim, killer, deathId) PlayerDeathSystem.ConfirmDeath returned -- the same three values
-- it fires -- and the one case that does use the real signal proves the subscription reaches
-- RewardSystem at all.
--
-- No Init() is called anywhere: remotes stay nil (every send in this chain is nil-guarded for exactly
-- that), and no production subscription is left behind for another spec to trip over.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local BountySystem = require(ServerScriptService.Server.Systems.BountySystem)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local PlayerDataSystem = require(ServerScriptService.Server.Systems.PlayerDataSystem) :: any
local PlayerDeathSystem = require(ServerScriptService.Server.Systems.PlayerDeathSystem)
local ProgressionSystem = require(ServerScriptService.Server.Systems.ProgressionSystem)
local RewardSystem = require(ServerScriptService.Server.Systems.RewardSystem)
local RivalrySystem = require(ServerScriptService.Server.Systems.RivalrySystem) :: any
local TierSystem = require(ServerScriptService.Server.Systems.TierSystem) :: any

local KILL_XP = Constants.Meridian.BaseXPPerKill

local nextUserId = 9100

local function fakePlayer(name: string): any
	nextUserId += 1
	return { Name = name, UserId = nextUserId }
end

-- Counts MeridianXPAwarded facts for one recipient name while `body` runs. The signal deep-copies the
-- stand-in, so it is matched by Name.
local function countAwards(recipientName: string, body: () -> ()): { { amount: number, reason: string? } }
	local seen: { { amount: number, reason: string? } } = {}
	local connection = GameplayEvents.OnMeridianXPAwarded(
		function(player: any, amount: number, _newTotal: number, reason: string?)
			if player.Name == recipientName then
				table.insert(seen, { amount = amount, reason = reason })
			end
		end
	)
	body()
	task.wait()
	connection:Disconnect()
	return seen
end

return function()
	local killer: any
	local victim: any
	local nextDeathId: number

	beforeEach(function()
		RewardSystem.Reset()
		ProgressionSystem.Reset()
		PlayerDeathSystem.Reset()
		BountySystem.ResetState()
		killer = fakePlayer("Killer")
		victim = fakePlayer("Victim")
		nextDeathId = 0
	end)

	afterEach(function()
		PlayerDataSystem.EvictProfileForSpec(killer)
		PlayerDataSystem.EvictProfileForSpec(victim)
		RewardSystem.Reset()
		ProgressionSystem.Reset()
		PlayerDeathSystem.Reset()
		BountySystem.ResetState()
	end)

	local function freshId(): number
		nextDeathId += 1
		return nextDeathId
	end

	-- Gives `player` a real loaded profile sitting exactly one kill below tier 2.
	local function loadProfileOneKillShortOfTier2(player: any): number
		local profile = PlayerDataSystem.CreateDefaultProfile(player.UserId)
		local start = math.max(0, TierSystem.GetThresholdForTier(2) - KILL_XP)
		profile.meridianXp = start
		PlayerDataSystem.InstallProfileForSpec(player, profile)
		return start
	end

	describe("RewardSystem.ComposeKillManifest -- eligibility", function()
		it("composes a Meridian XP manifest for an attributed kill", function()
			local id = freshId()
			local manifest = RewardSystem.ComposeKillManifest(victim, killer, id)
			expect(manifest).to.be.ok()
			local m = manifest :: any
			expect(m.Event.Source).to.equal("PvPKill")
			expect(m.Event.EventId).to.equal(id)
			expect(m.Event.Recipient).to.equal(killer)
			expect(m.Event.Victim).to.equal(victim)
			expect(#m.Components).to.equal(1)
			expect(m.Components[1]).to.equal("MeridianXP")
		end)

		it("hands out a manifest nothing downstream can add a reward to", function()
			local m = RewardSystem.ComposeKillManifest(victim, killer, freshId()) :: any
			expect(table.isfrozen(m)).to.equal(true)
			expect(table.isfrozen(m.Event)).to.equal(true)
			expect(table.isfrozen(m.Components)).to.equal(true)
			expect(function()
				table.insert(m.Components, "MeridianXP")
			end).to.throw()
		end)

		it("composes nothing for an environmental or unattributed death", function()
			local manifest, refusal = RewardSystem.ComposeKillManifest(victim, nil, freshId())
			expect(manifest).to.equal(nil)
			expect(refusal).to.equal("Unattributed")
		end)

		it("composes nothing for a self-kill", function()
			local manifest, refusal = RewardSystem.ComposeKillManifest(killer, killer, freshId())
			expect(manifest).to.equal(nil)
			expect(refusal).to.equal("SelfKill")
		end)

		it("refuses a replayed or out-of-order fact", function()
			local older = freshId()
			local id = freshId()
			expect(RewardSystem.ComposeKillManifest(victim, killer, id)).to.be.ok()
			local _, replay = RewardSystem.ComposeKillManifest(victim, killer, id)
			expect(replay).to.equal("Replayed")
			local _, late = RewardSystem.ComposeKillManifest(victim, killer, older)
			expect(late).to.equal("Replayed")
		end)

		it("never lets a replay claim a killer for a death that was unattributed", function()
			local id = freshId()
			RewardSystem.ComposeKillManifest(victim, nil, id)
			local manifest, refusal = RewardSystem.ComposeKillManifest(victim, killer, id)
			expect(manifest).to.equal(nil)
			expect(refusal).to.equal("Replayed")
		end)

		it("refuses a malformed event id", function()
			for _, bad in { 0, -1, 1.5, 0 / 0 } do
				local manifest, refusal = RewardSystem.ComposeKillManifest(victim, killer, bad)
				expect(manifest).to.equal(nil)
				expect(refusal).to.equal("InvalidEventId")
			end
		end)
	end)

	describe("ProgressionSystem.Apply -- the legitimacy gate", function()
		local function forged(source: string, recipient: any, target: any, components: { string }): any
			return table.freeze({
				Event = table.freeze({ Source = source, EventId = 1, Recipient = recipient, Victim = target }),
				Components = table.freeze(components),
			})
		end

		it("routes every kind RewardSystem can compose", function()
			expect(ProgressionSystem.CanRoute("MeridianXP")).to.equal(true)
		end)

		it("refuses any source the fight-to-grow pillar has not admitted", function()
			local outcome = ProgressionSystem.Apply(forged("Quest", killer, victim, { "MeridianXP" }))
			expect(outcome.Accepted).to.equal(false)
			expect(outcome.Refusal).to.equal("IllegitimateSource")
			expect(next(outcome.Granted)).to.equal(nil)
		end)

		it("refuses to reward a player for their own death", function()
			local outcome = ProgressionSystem.Apply(forged("PvPKill", killer, killer, { "MeridianXP" }))
			expect(outcome.Refusal).to.equal("SelfReward")
		end)

		it("refuses a manifest with nothing in it", function()
			local outcome = ProgressionSystem.Apply(forged("PvPKill", killer, victim, {}))
			expect(outcome.Refusal).to.equal("NoComponents")
		end)

		it("reports a component with no owner as not granted, without failing the rest", function()
			loadProfileOneKillShortOfTier2(killer)
			local outcome = ProgressionSystem.Apply(forged("PvPKill", killer, victim, { "Absorb", "MeridianXP" }))
			expect(outcome.Accepted).to.equal(true)
			expect((outcome.Granted :: any).Absorb).to.equal(false)
			expect(outcome.Granted.MeridianXP).to.equal(true)
		end)
	end)

	describe("one confirmed PvP kill, end to end", function()
		it("awards exactly one kill's Meridian XP, publishes it once, and promotes on the tier it reaches", function()
			local start = loadProfileOneKillShortOfTier2(killer)
			expect(TierSystem.ComputeTierForXP(start) < 2).to.equal(true)

			local killerBody = Instance.new("Model")
			local victimBody = Instance.new("Model")
			PlayerDeathSystem.BeginLife(killer, killerBody)
			PlayerDeathSystem.BeginLife(victim, victimBody)

			local outcome
			local awards = countAwards("Killer", function()
				PlayerDeathSystem.RecordDamage(victim, victimBody, killer, 40, 100)
				local published, attributed, deathId = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
				expect(published).to.equal(true)
				expect(attributed).to.equal(killer)
				outcome = RewardSystem.HandlePlayerKilled(victim, attributed, deathId :: number)
			end)

			expect(outcome).to.be.ok()
			expect((outcome :: any).Accepted).to.equal(true)
			expect((outcome :: any).Granted.MeridianXP).to.equal(true)
			expect(#awards).to.equal(1)
			expect(awards[1].amount).to.equal(KILL_XP)
			expect(awards[1].reason).to.equal("PvPKill")

			local profile = PlayerDataSystem.GetProfile(killer)
			expect(profile.meridianXp).to.equal(start + KILL_XP)

			-- TierSystem's own production trigger is its MeridianXPAwarded subscription; the award above
			-- was just shown to fire exactly once, so what remains is the evaluation it drives.
			expect(TierSystem.Evaluate(killer)).to.equal(true)
			expect(PlayerDataSystem.GetProfile(killer).tier).to.equal(TierSystem.ComputeTierForXP(start + KILL_XP))
			expect(PlayerDataSystem.GetProfile(killer).tier >= 2).to.equal(true)
		end)

		it("grants nothing more when the same fact is replayed", function()
			local start = loadProfileOneKillShortOfTier2(killer)
			local id = freshId()
			local awards = countAwards("Killer", function()
				RewardSystem.HandlePlayerKilled(victim, killer, id)
				expect(RewardSystem.HandlePlayerKilled(victim, killer, id)).to.equal(nil)
			end)
			expect(#awards).to.equal(1)
			expect(PlayerDataSystem.GetProfile(killer).meridianXp).to.equal(start + KILL_XP)
		end)

		it("grants nothing for a repeated Died signal on one life", function()
			local start = loadProfileOneKillShortOfTier2(killer)
			local victimBody = Instance.new("Model")
			PlayerDeathSystem.BeginLife(killer, Instance.new("Model"))
			PlayerDeathSystem.BeginLife(victim, victimBody)
			PlayerDeathSystem.RecordDamage(victim, victimBody, killer, 40, 100)

			local awards = countAwards("Killer", function()
				for _ = 1, 2 do
					local published, attributed, deathId = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
					if published then
						RewardSystem.HandlePlayerKilled(victim, attributed, deathId :: number)
					end
				end
			end)
			expect(#awards).to.equal(1)
			expect(PlayerDataSystem.GetProfile(killer).meridianXp).to.equal(start + KILL_XP)
		end)
	end)

	describe("deaths that must not progress anybody", function()
		it("awards nothing for an environmental death", function()
			local start = loadProfileOneKillShortOfTier2(killer)
			local victimBody = Instance.new("Model")
			PlayerDeathSystem.BeginLife(victim, victimBody)
			local awards = countAwards("Killer", function()
				local _, attributed, deathId = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
				expect(attributed).to.equal(nil)
				expect(RewardSystem.HandlePlayerKilled(victim, attributed, deathId :: number)).to.equal(nil)
			end)
			expect(#awards).to.equal(0)
			expect(PlayerDataSystem.GetProfile(killer).meridianXp).to.equal(start)
		end)

		it("refuses safely, with no false fact, when the killer's profile is not loaded", function()
			-- No InstallProfileForSpec: the killer has no loaded profile, as in the window between join
			-- and load. MeridianSystem logs the refusal; nothing is granted and nothing is published.
			local outcome
			local awards = countAwards("Killer", function()
				outcome = RewardSystem.HandlePlayerKilled(victim, killer, freshId())
			end)
			expect((outcome :: any).Accepted).to.equal(true)
			expect((outcome :: any).Granted.MeridianXP).to.equal(false)
			expect(#awards).to.equal(0)
		end)
	end)

	describe("the confirmed fact's other consumers", function()
		it("reaches RewardSystem through the real PlayerKilled subscription, once", function()
			RewardSystem.Attach()
			RewardSystem.Attach()
			local id = freshId()
			GameplayEvents.FirePlayerKilled(victim, nil, id)
			task.wait()
			-- Consumed by the subscription, so composing it again is a replay. Read BEFORE Reset, which
			-- clears the replay mark along with the subscription.
			local _, refusal = RewardSystem.ComposeKillManifest(victim, killer, id)
			RewardSystem.Reset()
			expect(refusal).to.equal("Replayed")
		end)

		it("leaves bounty streaks and rivalry standings to their own subscriptions", function()
			loadProfileOneKillShortOfTier2(killer)
			RewardSystem.HandlePlayerKilled(victim, killer, freshId())
			-- The spine touched neither.
			expect(BountySystem.GetKillStreak(killer)).to.equal(0)
			expect(RivalrySystem.GetRivalryStanding(killer, victim)).to.equal(0)

			-- And each still counts the same fact on its own terms.
			BountySystem.RegisterKill(killer, victim)
			RivalrySystem.RegisterPvPKill(killer, victim)
			expect(BountySystem.GetKillStreak(killer)).to.equal(1)
			expect(RivalrySystem.GetRivalryStanding(killer, victim) > 0).to.equal(true)
			RivalrySystem.ClearPlayerReferences(killer)
			RivalrySystem.ClearPlayerReferences(victim)
		end)
	end)
end
