--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local Fixtures = require(ServerScriptService.Tests.TestHelpers.Fixtures)

local function makeCandidate(overrides: { [string]: any }?): { [string]: any }
	local candidate = {
		MoveId = "registry-test-move",
		DisplayName = "Registry Test Move",
		Category = "Testing",
		Author = "TestAuthor",
		CreatedAt = 1000,
		UpdatedAt = 1000,
		Shape = "Box",
		Size = Vector3.new(4, 4, 4),
		OffsetX = 0,
		OffsetY = 0,
		OffsetZ = -3,
		WindupSeconds = 0.2,
		ActiveSeconds = 0.15,
		RecoverySeconds = 0.3,
		Cooldown = 0.6,
		Damage = 5,
		PostureDamage = 5,
		ArcDegrees = 100,
		MaxTargets = 5,
		AnimationId = "",
	}
	return Fixtures.applyOverrides(candidate, overrides)
end

return function()
	-- MoveRegistryManager owns a single shared, module-level `moves` table (no per-instance
	-- registry object -- see its own header) -- Init() resets it to empty so each test in this file
	-- starts from a known-clean slate regardless of what an earlier test (or another spec file
	-- sharing the same TestEZ VM) left behind, mirroring HitboxTuning.spec.lua's own
	-- "LiveTuningContract.withRestore"-style discipline for shared in-memory state.
	local function reset(): ()
		MoveRegistryManager.Init()
	end

	describe("MoveRegistryManager round trip", function()
		it("List returns nothing before any Upsert", function()
			reset()
			expect(#MoveRegistryManager.List()).to.equal(0)
		end)

		it("Upsert then Get returns the same move by MoveId", function()
			reset()
			local move = MoveRegistryManager.Validate(makeCandidate())
			MoveRegistryManager.Upsert(move :: any)

			local fetched = MoveRegistryManager.Get("registry-test-move")
			expect(fetched).to.be.ok()
			expect((fetched :: any).DisplayName).to.equal("Registry Test Move")
		end)

		it("Get returns nil for an unknown MoveId", function()
			reset()
			expect(MoveRegistryManager.Get("does-not-exist")).to.equal(nil)
		end)

		it("an invalid candidate never reaches Upsert", function()
			reset()
			local move, reason = MoveRegistryManager.Validate(makeCandidate({ MoveId = "" }))
			expect(move).to.equal(nil)
			expect(reason).to.equal("InvalidMoveId")
			-- Validate rejected it -- confirm nothing was ever written under any key.
			expect(#MoveRegistryManager.List()).to.equal(0)
		end)

		it("List reflects every Upserted move", function()
			reset()
			MoveRegistryManager.Upsert(MoveRegistryManager.Validate(makeCandidate({ MoveId = "move-a" })) :: any)
			MoveRegistryManager.Upsert(MoveRegistryManager.Validate(makeCandidate({ MoveId = "move-b" })) :: any)
			expect(#MoveRegistryManager.List()).to.equal(2)
		end)

		it("Upsert with the same MoveId replaces, not appends", function()
			reset()
			MoveRegistryManager.Upsert(MoveRegistryManager.Validate(makeCandidate({ Damage = 5 })) :: any)
			MoveRegistryManager.Upsert(MoveRegistryManager.Validate(makeCandidate({ Damage = 25 })) :: any)
			expect(#MoveRegistryManager.List()).to.equal(1)
			local fetched = MoveRegistryManager.Get("registry-test-move")
			expect((fetched :: any).Damage).to.equal(25)
		end)

		it("Delete removes a move so Get returns nil afterward", function()
			reset()
			MoveRegistryManager.Upsert(MoveRegistryManager.Validate(makeCandidate()) :: any)
			MoveRegistryManager.Delete("registry-test-move")
			expect(MoveRegistryManager.Get("registry-test-move")).to.equal(nil)
			expect(#MoveRegistryManager.List()).to.equal(0)
		end)

		it("Get/List return copies, not the live table -- mutating one never corrupts the registry", function()
			reset()
			MoveRegistryManager.Upsert(MoveRegistryManager.Validate(makeCandidate()) :: any)
			local fetched = MoveRegistryManager.Get("registry-test-move") :: any
			fetched.Damage = 9999

			local fetchedAgain = MoveRegistryManager.Get("registry-test-move") :: any
			expect(fetchedAgain.Damage).to.equal(5)
		end)
	end)

	describe("MoveRegistryManager.GenerateMoveId", function()
		it("slugifies the display name", function()
			reset()
			local moveId = MoveRegistryManager.GenerateMoveId("Rising Dragon Strike!")
			expect(moveId:match("^rising%-dragon%-strike%-%d+$")).to.be.ok()
		end)

		it("never collides with an already-registered MoveId", function()
			reset()
			MoveRegistryManager.Upsert(MoveRegistryManager.Validate(makeCandidate({ MoveId = "slam" })) :: any)
			-- GenerateMoveId retries internally until unique -- run it many times against a name that
			-- happens to slugify to "slam" and confirm none of the results collide with the existing
			-- "slam" entry or each other.
			local seen: { [string]: boolean } = { slam = true }
			for _ = 1, 25 do
				local generated = MoveRegistryManager.GenerateMoveId("Slam")
				expect(seen[generated]).to.equal(nil)
				seen[generated] = true
			end
		end)

		it("falls back to a generic base for a name with no alphanumeric characters", function()
			reset()
			local moveId = MoveRegistryManager.GenerateMoveId("!!!")
			expect(moveId:match("^move%-%d+$")).to.be.ok()
		end)
	end)
end
