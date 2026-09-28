--!strict
-- Covers the death notice end to end, minus the wire: PlayerDeathSystem.BuildNotice (what the server
-- says), DeathTypes.Parse (what a client accepts), and DeathNoticeClient.Decide/Apply (what each client
-- does with it). The remote hop itself is one FireAllClients and one OnClientEvent connect, neither of
-- which this headless place can raise; everything either side of it is here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local DeathTypes = require(ReplicatedStorage.Shared.Death.DeathTypes)
local PlayerDeathSystem = require(ServerScriptService.Server.Systems.PlayerDeathSystem)
local DeathNoticeClient = require(StarterPlayer.StarterPlayerScripts.Client.Combat.DeathNoticeClient)

local ME = 101
local THEM = 202
local BYSTANDER = 303

local function recorder()
	local calls = { shown = {} :: { any }, cleared = 0, pushed = {} :: { any } }
	local surface = {
		ShowDeath = function(killerName: string?)
			table.insert(calls.shown, { killerName = killerName })
		end,
		ClearDeath = function()
			calls.cleared += 1
		end,
		PushKill = function(killerName: string, victimName: string, involvement: string)
			table.insert(calls.pushed, { killer = killerName, victim = victimName, involvement = involvement })
		end,
	}
	return calls, surface :: any
end

return function()
	describe("PlayerDeathSystem.BuildNotice", function()
		it("names both players of an attributed death", function()
			local victim = { Name = "Victim", UserId = ME } :: any
			local killer = { Name = "Killer", UserId = THEM } :: any
			local notice = PlayerDeathSystem.BuildNotice(victim, killer)
			expect(notice.VictimUserId).to.equal(ME)
			expect(notice.VictimName).to.equal("Victim")
			expect(notice.KillerUserId).to.equal(THEM)
			expect(notice.KillerName).to.equal("Killer")
		end)

		it("carries no killer at all for an unattributed death", function()
			local notice = PlayerDeathSystem.BuildNotice({ Name = "Victim", UserId = ME } :: any, nil)
			expect(notice.KillerUserId).to.equal(nil)
			expect(notice.KillerName).to.equal(nil)
		end)

		it("builds exactly what a client will accept", function()
			local notice = PlayerDeathSystem.BuildNotice(
				{ Name = "Victim", UserId = ME } :: any,
				{ Name = "Killer", UserId = THEM } :: any
			)
			expect(DeathTypes.Parse(notice)).to.be.ok()
		end)
	end)

	describe("DeathTypes.Parse", function()
		it("rejects anything that is not a well-formed notice", function()
			expect(DeathTypes.Parse(nil)).to.equal(nil)
			expect(DeathTypes.Parse("dead")).to.equal(nil)
			expect(DeathTypes.Parse({ VictimName = "V" })).to.equal(nil)
			expect(DeathTypes.Parse({ VictimUserId = ME, VictimName = 5 })).to.equal(nil)
			-- Half a killer is not a killer.
			expect(DeathTypes.Parse({ VictimUserId = ME, VictimName = "V", KillerUserId = THEM })).to.equal(nil)
			expect(DeathTypes.Parse({ VictimUserId = ME, VictimName = "V", KillerName = "K" })).to.equal(nil)
			expect(DeathTypes.Parse({ VictimUserId = ME, VictimName = "V", KillerUserId = "x", KillerName = "K" })).to.equal(
				nil
			)
		end)
	end)

	describe("DeathNoticeClient -- the victim's client", function()
		it("shows the overlay naming the killer, and puts the kill in the feed as the victim's", function()
			local calls, surface = recorder()
			DeathNoticeClient.Apply(
				{ VictimUserId = ME, VictimName = "Me", KillerUserId = THEM, KillerName = "Them" },
				ME,
				surface
			)
			expect(#calls.shown).to.equal(1)
			expect(calls.shown[1].killerName).to.equal("Them")
			expect(#calls.pushed).to.equal(1)
			expect(calls.pushed[1].involvement).to.equal("Victim")
		end)

		it("shows an overlay with no killer for an environmental death, and nothing in the feed", function()
			local calls, surface = recorder()
			DeathNoticeClient.Apply({ VictimUserId = ME, VictimName = "Me" }, ME, surface)
			expect(#calls.shown).to.equal(1)
			expect(calls.shown[1].killerName).to.equal(nil)
			expect(#calls.pushed).to.equal(0)
		end)
	end)

	describe("DeathNoticeClient -- everyone else", function()
		it("gives the killer a feed row as the killer, and no overlay", function()
			local calls, surface = recorder()
			DeathNoticeClient.Apply(
				{ VictimUserId = ME, VictimName = "Me", KillerUserId = THEM, KillerName = "Them" },
				THEM,
				surface
			)
			expect(#calls.shown).to.equal(0)
			expect(calls.pushed[1].involvement).to.equal("Killer")
		end)

		it("gives a bystander a neutral row, and ignores other players' environmental deaths", function()
			local calls, surface = recorder()
			DeathNoticeClient.Apply(
				{ VictimUserId = ME, VictimName = "Me", KillerUserId = THEM, KillerName = "Them" },
				BYSTANDER,
				surface
			)
			DeathNoticeClient.Apply({ VictimUserId = ME, VictimName = "Me" }, BYSTANDER, surface)
			expect(#calls.shown).to.equal(0)
			expect(#calls.pushed).to.equal(1)
			expect(calls.pushed[1].involvement).to.equal("None")
			expect(calls.pushed[1].killer).to.equal("Them")
			expect(calls.pushed[1].victim).to.equal("Me")
		end)

		it("does nothing at all with a malformed notice", function()
			local calls, surface = recorder()
			DeathNoticeClient.Apply({ VictimUserId = ME }, ME, surface)
			expect(#calls.shown).to.equal(0)
			expect(#calls.pushed).to.equal(0)
		end)
	end)
end
