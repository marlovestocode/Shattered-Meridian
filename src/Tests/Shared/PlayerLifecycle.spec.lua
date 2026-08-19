--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)

-- COVERAGE BOUNDARY, stated up front so nobody mistakes this file for full coverage of the module.
-- This harness is a headless server place with no live client and no players: Players.LocalPlayer is
-- nil, Players:GetPlayers() is empty, and neither PlayerAdded nor CharacterAdded can be fired
-- synthetically (they are engine-owned signals, not BindableEvents). So the two things this module
-- actually does for a real session -- binding a character after its Humanoid replicates, and rebinding
-- across a respawn -- are NOT reachable from here, the same accepted gap NetworkBridge.spec.lua
-- documents for its own client branch. They need a Studio or live-server playtest.
--
-- What IS reachable, and what this file therefore pins down, is everything about the module that is
-- decided BEFORE a player exists: that binding on an empty server is a no-op rather than an error,
-- that the returned Trove is a real teardown handle, that tearing down twice is safe, and that a
-- handler set with no character callbacks does not wire character plumbing it will never use. The
-- per-life Trove semantics those handlers depend on are covered directly and thoroughly in
-- Tests/Shared/Trove.spec.lua, which is where that logic actually lives.

return function()
	describe("PlayerLifecycle.BindAllPlayers -- before anyone has joined", function()
		it("binds an empty server without calling any handler", function()
			expect(#Players:GetPlayers()).to.equal(0)

			local calls = 0
			local binding = PlayerLifecycle.BindAllPlayers({
				Scope = "PlayerLifecycleSpec",
				OnPlayer = function()
					calls += 1
				end,
				OnPlayerRemoving = function()
					calls += 1
				end,
				OnCharacter = function()
					calls += 1
				end,
			})

			expect(calls).to.equal(0)
			binding:Clean()
		end)

		it("returns a Trove holding the Players connections plus its own teardown", function()
			-- Two Players signals and the "release every live per-player scope" closure -- the shape
			-- that makes Clean() a complete teardown rather than a partial one.
			local binding = PlayerLifecycle.BindAllPlayers({ Scope = "PlayerLifecycleSpec" })
			expect(binding:Count()).to.equal(3)
			binding:Clean()
			expect(binding:Count()).to.equal(0)
		end)

		it("survives being torn down twice", function()
			local binding = PlayerLifecycle.BindAllPlayers({ Scope = "PlayerLifecycleSpec" })
			expect(function()
				binding:Clean()
				binding:Clean()
			end).never.to.throw()
		end)

		it("accepts a handler set with no callbacks at all", function()
			-- A System that only wants the sweep-and-connect shape without any per-player work is a
			-- legitimate caller; every field but Scope is optional and none may be assumed present.
			expect(function()
				PlayerLifecycle.BindAllPlayers({ Scope = "PlayerLifecycleSpec" }):Clean()
			end).never.to.throw()
		end)
	end)

	describe("PlayerLifecycle.BindLocalCharacter -- server-side guard", function()
		it("is a client-only entry point and says so by failing loudly here", function()
			-- Players.LocalPlayer is nil on a server, so this indexes nil. Asserting the failure keeps
			-- the client/server split of this module honest: a System that reaches for the local-player
			-- binder finds out at its first spec run, not in a playtest.
			expect(function()
				PlayerLifecycle.BindLocalCharacter({
					Scope = "PlayerLifecycleSpec",
					OnCharacter = function() end,
				})
			end).to.throw()
		end)
	end)
end
