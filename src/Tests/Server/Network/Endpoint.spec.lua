--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BootManifest = require(ServerScriptService.Server.Config.BootManifest)
local Endpoint = require(ServerScriptService.Server.Network.Endpoint)
local Logger = require(ReplicatedStorage.Shared.Logger)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Rig = require(ServerScriptService.Tests.TestHelpers.Rig)
local Schema = require(ReplicatedStorage.Shared.Schema)

local logger = Logger.scope("EndpointSpec")

local OWNER = "EndpointSpecOwner"

local nextName = 0
local function uniqueName(): string
	nextName += 1
	return `EndpointSpecRemote{nextName}`
end

return function()
	local scope: Endpoint.Scope

	beforeEach(function()
		scope = Endpoint.Scope(OWNER, logger)
	end)

	afterEach(function()
		BootManifest.ResetDeclaredForTesting()
	end)

	describe("Endpoint.Scope", function()
		it("needs an owner", function()
			expect(function()
				Endpoint.Scope("", logger)
			end).to.throw()
		end)

		it("refuses an endpoint with no rate limiter", function()
			expect(function()
				scope.Event({ Name = uniqueName(), Handler = function() end } :: any)
			end).to.throw()
			expect(function()
				scope.Function({ Name = uniqueName(), ErrorResult = false, Handler = function() end } :: any)
			end).to.throw()
		end)
	end)

	describe("Endpoint Event", function()
		it("creates the remote and declares it to BootManifest under the owner", function()
			local name = uniqueName()
			local bound = scope.Event({ Name = name, Limiter = RateLimiter.New(10), Handler = function() end })
			expect(bound.Remote:IsA("RemoteEvent")).to.equal(true)
			expect(bound.Remote.Name).to.equal(name)
			expect(BootManifest.RemoteOwners()[name]).to.equal(OWNER)
		end)

		it("hands the handler the decoded arguments, clamping where the shape clamps", function()
			local received: { any } = {}
			local bound = scope.Event({
				Name = uniqueName(),
				Limiter = RateLimiter.New(10),
				Args = { Schema.Boolean, Schema.Number(0, 5) },
				Handler = function(_player, flag, amount)
					received = { flag, amount }
				end,
			})
			bound.Handle(Rig.FakePlayer("A"), true, 99, "ignored extra")
			expect(received[1]).to.equal(true)
			expect(received[2]).to.equal(5)
		end)

		it("drops a call whose arguments fail to decode, without calling the handler", function()
			local calls = 0
			local bound = scope.Event({
				Name = uniqueName(),
				Limiter = RateLimiter.New(10),
				Args = { Schema.Boolean },
				Handler = function()
					calls += 1
				end,
			})
			bound.Handle(Rig.FakePlayer("A"), "yes")
			bound.Handle(Rig.FakePlayer("A"), nil)
			bound.Handle(Rig.FakePlayer("A"), 0 / 0)
			expect(calls).to.equal(0)
		end)

		it("drops a rate-limited call", function()
			local calls = 0
			local bound = scope.Event({
				Name = uniqueName(),
				Limiter = RateLimiter.New(2),
				Handler = function()
					calls += 1
				end,
			})
			local player = Rig.FakePlayer("Burst")
			for _ = 1, 6 do
				bound.Handle(player)
			end
			expect(calls).to.equal(2)
		end)

		it("does not throw when the handler does", function()
			local bound = scope.Event({
				Name = uniqueName(),
				Limiter = RateLimiter.New(10),
				Handler = function()
					error("boom")
				end,
			})
			expect(function()
				bound.Handle(Rig.FakePlayer("A"))
			end).never.to.throw()
		end)

		it("refuses a non-admin on an Admin endpoint", function()
			local calls = 0
			local bound = scope.Event({
				Name = uniqueName(),
				Limiter = RateLimiter.New(10),
				Admin = true,
				Handler = function()
					calls += 1
				end,
			})
			bound.Handle(Rig.FakePlayer("Nobody", nil, -1))
			expect(calls).to.equal(0)
		end)
	end)

	describe("Endpoint Function", function()
		it("answers the handler's result", function()
			local bound = scope.Function({
				Name = uniqueName(),
				Limiter = RateLimiter.New(10),
				ErrorResult = "error",
				Args = { Schema.Number(0, 10) },
				Handler = function(_player, n)
					return n * 2
				end,
			})
			expect(bound.Remote:IsA("RemoteFunction")).to.equal(true)
			expect(bound.Handle(Rig.FakePlayer("A"), 4)).to.equal(8)
			expect(bound.Handle(Rig.FakePlayer("A"), 400)).to.equal(20)
		end)

		it("may answer nil", function()
			local bound = scope.Function({
				Name = uniqueName(),
				Limiter = RateLimiter.New(10),
				ErrorResult = "error",
				Handler = function()
					return nil
				end,
			})
			expect(bound.Handle(Rig.FakePlayer("A"))).to.equal(nil)
		end)

		it("answers ErrorResult when the handler throws", function()
			local bound = scope.Function({
				Name = uniqueName(),
				Limiter = RateLimiter.New(10),
				ErrorResult = "error",
				Handler = function()
					error("boom")
				end,
			})
			expect(bound.Handle(Rig.FakePlayer("A"))).to.equal("error")
		end)

		it("answers Invalid when the arguments fail, else ErrorResult", function()
			local withInvalid = scope.Function({
				Name = uniqueName(),
				Limiter = RateLimiter.New(10),
				ErrorResult = "error",
				Invalid = "invalid",
				Args = { Schema.Boolean },
				Handler = function()
					return "ok"
				end,
			})
			expect(withInvalid.Handle(Rig.FakePlayer("A"), 5)).to.equal("invalid")
			local without = scope.Function({
				Name = uniqueName(),
				Limiter = RateLimiter.New(10),
				ErrorResult = "error",
				Args = { Schema.Boolean },
				Handler = function()
					return "ok"
				end,
			})
			expect(without.Handle(Rig.FakePlayer("A"), 5)).to.equal("error")
		end)

		it("lets Invalid be a function of the argument that failed", function()
			local bound = scope.Function({
				Name = uniqueName(),
				Limiter = RateLimiter.New(10),
				ErrorResult = "error",
				Invalid = function(_player: Player, index: number)
					return `bad{index}`
				end,
				Args = { Schema.Number(0, 1), Schema.Optional(Schema.RawString) },
				Handler = function()
					return "ok"
				end,
			})
			expect(bound.Handle(Rig.FakePlayer("A"), "x")).to.equal("bad1")
			expect(bound.Handle(Rig.FakePlayer("A"), 1, 5)).to.equal("bad2")
			expect(bound.Handle(Rig.FakePlayer("A"), 1)).to.equal("ok")
			expect(bound.Handle(Rig.FakePlayer("A"), 1, "id")).to.equal("ok")
		end)

		it("answers OnLimited (which may be nil) or ErrorResult when rate limited", function()
			local custom = scope.Function({
				Name = uniqueName(),
				Limiter = RateLimiter.New(1),
				ErrorResult = "error",
				OnLimited = function()
					return nil
				end,
				Handler = function()
					return "ok"
				end,
			})
			local player = Rig.FakePlayer("Burst")
			expect(custom.Handle(player)).to.equal("ok")
			expect(custom.Handle(player)).to.equal(nil)

			local plain = scope.Function({
				Name = uniqueName(),
				Limiter = RateLimiter.New(1),
				ErrorResult = "error",
				Handler = function()
					return "ok"
				end,
			})
			local other = Rig.FakePlayer("Burst2")
			expect(plain.Handle(other)).to.equal("ok")
			expect(plain.Handle(other)).to.equal("error")
		end)

		it("answers Denied for a non-admin on an Admin endpoint, without calling the handler", function()
			local calls = 0
			local bound = scope.Function({
				Name = uniqueName(),
				Limiter = RateLimiter.New(10),
				Admin = true,
				ErrorResult = { Success = false, Reason = "InternalError" },
				Denied = function(reason: string)
					return { Success = false, Reason = reason }
				end,
				Handler = function()
					calls += 1
					return { Success = true }
				end,
			})
			local result = bound.Handle(Rig.FakePlayer("Nobody", nil, -1))
			expect(result.Reason).to.equal("NotAuthorized")
			expect(calls).to.equal(0)
		end)
	end)

	describe("Endpoint Push", function()
		it("creates a server-to-client remote and declares it", function()
			local name = uniqueName()
			local remote = scope.Push(name)
			expect(remote:IsA("RemoteEvent")).to.equal(true)
			expect(BootManifest.RemoteOwners()[name]).to.equal(OWNER)
			local unreliableName = uniqueName()
			local unreliable = scope.Push(unreliableName, { Unreliable = true })
			expect(unreliable:IsA("UnreliableRemoteEvent")).to.equal(true)
			expect(BootManifest.RemoteOwners()[unreliableName]).to.equal(OWNER)
		end)
	end)

	describe("BootManifest.DeclareRemote", function()
		it("is idempotent for one owner and an error for a second", function()
			local name = uniqueName()
			BootManifest.DeclareRemote("OwnerA", name)
			BootManifest.DeclareRemote("OwnerA", name)
			expect(function()
				BootManifest.DeclareRemote("OwnerB", name)
			end).to.throw()
		end)
	end)
end
