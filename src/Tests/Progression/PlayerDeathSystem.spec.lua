--!strict
-- Covers Server/Systems/PlayerDeathSystem.lua -- confirming a death exactly once per life, and deciding
-- who (if anyone) killed. This is the fact the whole fight-to-grow loop hangs off: before it, every
-- death published killer = nil and no kill could progress anybody.
--
-- IDENTITY IS A STAND-IN, DAMAGE IS NOT. Instance.new("Player") errors in this harness, so players are
-- `{ Name, UserId } :: any` tables driven through the module's resolved-identity seam (BeginLife/
-- RecordDamage/ConfirmDeath/ReleasePlayer) -- the same split Tests/Combat/Engagement/
-- EngagementSystem.spec.lua documents at length. Where a case is about WHICH outcomes are blows, the
-- damage figure is the real DamageResolver's answer for that outcome kind, never a hand-written zero.
-- Characters are real Models, because life identity is Model identity.
--
-- Init() and Attach() are never called: the Players adapter would resolve nil for every stand-in.
-- Time is passed explicitly; nothing sleeps except the one case that observes the published signal.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local EngagementConstants = require(ReplicatedStorage.Shared.Engagement.EngagementConstants)
local DamageResolver = require(ServerScriptService.Server.Combat.Damage.DamageResolver)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local PlayerDeathSystem = require(ServerScriptService.Server.Systems.PlayerDeathSystem)

local WINDOW = DamageConstants.KillCredit.WindowSeconds
local PROFILE = { Damage = 20, PostureDamage = 10 } :: any

local nextUserId = 7000

local function fakePlayer(name: string): any
	nextUserId += 1
	return { Name = name, UserId = nextUserId }
end

local function body(name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	return model
end

return function()
	local victim: any
	local attacker: any
	local victimBody: Model
	local attackerBody: Model

	beforeEach(function()
		PlayerDeathSystem.Reset()
		victim = fakePlayer("Victim")
		attacker = fakePlayer("Attacker")
		victimBody = body("VictimBody")
		attackerBody = body("AttackerBody")
		PlayerDeathSystem.BeginLife(victim, victimBody)
		PlayerDeathSystem.BeginLife(attacker, attackerBody)
	end)

	afterEach(function()
		PlayerDeathSystem.Reset()
	end)

	describe("DamageConstants.KillCredit", function()
		it("is a positive window no longer than the combat tag", function()
			expect(WINDOW > 0).to.equal(true)
			expect(WINDOW <= EngagementConstants.TagDurationSeconds).to.equal(true)
		end)
	end)

	describe("attributed deaths", function()
		it("credits the player whose blow killed on the same life", function()
			local blow = DamageResolver.Resolve("Clean", "Neutral", PROFILE, 1)
			expect(blow.Damage > 0).to.equal(true)
			expect(PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, blow.Damage, 100)).to.equal(true)

			local published, killer, deathId = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			expect(published).to.equal(true)
			expect(killer).to.equal(attacker)
			expect(deathId).to.be.a("number")
		end)

		it("credits a knock-off death inside the window, right up to its edge", function()
			PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, 5, 100)
			local _, killer = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100 + WINDOW)
			expect(killer).to.equal(attacker)
		end)

		it("credits the LAST player to land a blow", function()
			local second = fakePlayer("Second")
			PlayerDeathSystem.BeginLife(second, body("SecondBody"))
			PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, 30, 100)
			PlayerDeathSystem.RecordDamage(victim, victimBody, second, 5, 101)
			local _, killer = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 101)
			expect(killer).to.equal(second)
		end)

		it("keeps a player's credit when a non-player lands the final blow", function()
			PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, 30, 100)
			expect(PlayerDeathSystem.RecordDamage(victim, victimBody, nil, 50, 101)).to.equal(false)
			local _, killer = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 101)
			expect(killer).to.equal(attacker)
		end)

		it("counts a Blocked hit that removed health -- the rule is health removed, not outcome kind", function()
			local chip = DamageResolver.Resolve("Blocked", "Staggered", PROFILE, 1)
			expect(chip.Damage > 0).to.equal(true)
			expect(PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, chip.Damage, 100)).to.equal(true)
		end)
	end)

	describe("unattributed deaths", function()
		it("publishes no killer for an environmental death", function()
			local published, killer = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			expect(published).to.equal(true)
			expect(killer).to.equal(nil)
		end)

		it("never creates credit from an outcome that removed no health", function()
			local guarded = DamageResolver.Resolve("Blocked", "Blocking", PROFILE, 1)
			local parried = DamageResolver.Resolve("Parried", "ParryWindow", PROFILE, 1)
			local traded = DamageResolver.Resolve("Trade", "Neutral", PROFILE, 1)
			for _, result in { guarded, parried, traded } do
				expect(result.Damage).to.equal(0)
				expect(PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, result.Damage, 100)).to.equal(false)
			end
			expect(PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, -5, 100)).to.equal(false)
			expect(PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, 0 / 0, 100)).to.equal(false)

			local _, killer = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			expect(killer).to.equal(nil)
		end)

		it("lets stale credit attribute nothing", function()
			PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, 20, 100)
			local _, killer = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100 + WINDOW + 0.01)
			expect(killer).to.equal(nil)
		end)

		it("rejects self-credit", function()
			expect(PlayerDeathSystem.RecordDamage(victim, victimBody, victim, 20, 100)).to.equal(false)
			local _, killer = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			expect(killer).to.equal(nil)
		end)

		it("rejects an attacker who was never tracked", function()
			local stranger = fakePlayer("Stranger")
			expect(PlayerDeathSystem.RecordDamage(victim, victimBody, stranger, 20, 100)).to.equal(false)
		end)
	end)

	describe("life identity", function()
		it("never carries credit across a respawn", function()
			PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, 20, 100)
			local nextBody = body("VictimBody2")
			PlayerDeathSystem.BeginLife(victim, nextBody)

			local _, killer = PlayerDeathSystem.ConfirmDeath(victim, nextBody, 101)
			expect(killer).to.equal(nil)
		end)

		it("refuses a blow recorded against a previous body", function()
			local nextBody = body("VictimBody2")
			PlayerDeathSystem.BeginLife(victim, nextBody)
			expect(PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, 20, 100)).to.equal(false)
			local _, killer = PlayerDeathSystem.ConfirmDeath(victim, nextBody, 100)
			expect(killer).to.equal(nil)
		end)

		it("ignores a late Died from a previous body", function()
			local nextBody = body("VictimBody2")
			PlayerDeathSystem.BeginLife(victim, nextBody)
			local published = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			expect(published).to.equal(false)
		end)

		it("refuses credit for a blow on a life already confirmed dead", function()
			PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			expect(PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, 20, 100)).to.equal(false)
		end)
	end)

	describe("PlayerRemoving", function()
		it("drops the leaver's own life", function()
			PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, 20, 100)
			PlayerDeathSystem.ReleasePlayer(victim)
			local published = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			expect(published).to.equal(false)
		end)

		it("drops credit a leaver held against someone else, so no departed Player is ever published", function()
			PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, 20, 100)
			PlayerDeathSystem.ReleasePlayer(attacker)
			local published, killer = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			expect(published).to.equal(true)
			expect(killer).to.equal(nil)
		end)
	end)

	describe("exactly once per life", function()
		it("publishes a second Died for the same life as nothing", function()
			PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, 20, 100)
			local first, firstKiller = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			local second, secondKiller, secondId = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			expect(first).to.equal(true)
			expect(firstKiller).to.equal(attacker)
			expect(second).to.equal(false)
			expect(secondKiller).to.equal(nil)
			expect(secondId).to.equal(nil)
		end)

		it("hands every published death a new, increasing id -- including across a Reset", function()
			local _, _, firstId = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			PlayerDeathSystem.BeginLife(victim, body("VictimBody2"))
			PlayerDeathSystem.Reset()
			PlayerDeathSystem.BeginLife(victim, victimBody)
			local _, _, secondId = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 101)
			expect((secondId :: number) > (firstId :: number)).to.equal(true)
		end)

		it("puts exactly one fact on GameplayEvents per life, carrying the attribution", function()
			-- The one case that observes the real BindableEvent. It deep-copies table arguments, so the
			-- stand-ins arrive as copies -- compared by Name, which survives the copy.
			local received: { { victim: string, killer: string?, deathId: number } } = {}
			local connection = GameplayEvents.OnPlayerKilled(function(v: any, k: any, deathId: number)
				if v.Name == "Victim" then
					table.insert(received, { victim = v.Name, killer = if k then k.Name else nil, deathId = deathId })
				end
			end)

			PlayerDeathSystem.RecordDamage(victim, victimBody, attacker, 20, 100)
			local _, _, deathId = PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			PlayerDeathSystem.ConfirmDeath(victim, victimBody, 100)
			task.wait()

			local environmentalBody = body("VictimBody2")
			PlayerDeathSystem.BeginLife(victim, environmentalBody)
			PlayerDeathSystem.ConfirmDeath(victim, environmentalBody, 200)
			task.wait()
			connection:Disconnect()

			expect(#received).to.equal(2)
			expect(received[1].killer).to.equal("Attacker")
			expect(received[1].deathId).to.equal(deathId)
			expect(received[2].killer).to.equal(nil)
		end)
	end)
end
