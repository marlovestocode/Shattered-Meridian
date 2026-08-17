--!strict
-- Covers Server/Combat/AttackCatalog.lua -- the Move-Creation-System-to-engine bridge.
--
-- Exercised against the REAL registries rather than stubs, because the whole claim this module makes
-- is that authored moves reach the combat stack intact. A stubbed registry would verify the plumbing
-- and prove nothing about the bridge.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackCatalog = require(ServerScriptService.Server.Combat.AttackCatalog)
local AttackWindows = require(ReplicatedStorage.Shared.Attack.AttackWindows)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

-- DefaultMoveRegistry projects this from Constants.Combat.Weapons.Primary's first basic stage. Used
-- rather than invented because a catalogue that only resolves moves the spec itself authored would
-- never catch the bridge breaking against real authored data.
local DEFAULT_MOVE_ID = "default:Primary:Basic:1"

return function()
	afterEach(function()
		AttackCatalog.Reset()
		MoveRegistryManager.Init()
	end)

	describe("AttackCatalog.Get -- resolution", function()
		it("resolves a Default move into an engine definition and a damage profile", function()
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID)
			expect(entry).to.be.ok()
			local resolved = entry :: any
			expect(resolved.MoveId).to.equal(DEFAULT_MOVE_ID)
			expect(resolved.Definition).to.be.ok()
			expect(resolved.Profile).to.be.ok()
			expect(type(resolved.Profile.Damage)).to.equal("number")
			expect(resolved.Profile.Damage > 0).to.equal(true)
		end)

		it("names the definition by MoveId, which is what makes the round trip work", function()
			-- HitReport.DebugName is the ONLY key the damage layer has to look an attack back up by. If
			-- this were ever separately authored, a landed hit could not be priced at all.
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Definition.DebugName).to.equal(DEFAULT_MOVE_ID)
		end)

		it("returns nil for an unknown id rather than a stand-in attack", function()
			-- Substituting a default would turn "this ability is broken" into "this ability does the
			-- wrong thing," which is far harder to notice.
			expect(AttackCatalog.Get("no-such-move")).to.equal(nil)
			expect(AttackCatalog.Get("")).to.equal(nil)
			expect(AttackCatalog.Get(nil :: any)).to.equal(nil)
		end)
	end)

	describe("AttackCatalog.Get -- precedence", function()
		it("prefers a custom move over a Default one sharing its id", function()
			-- Mirrors the Move Editor's own List/ListDefaultMoves split: a custom move sharing an id is
			-- the more recent authored intent.
			local default = DefaultMoveRegistry.Get(DEFAULT_MOVE_ID)
			expect(default).to.be.ok()

			local custom = MoveTypes.Clone(default :: any)
			custom.Damage = (default :: any).Damage + 777
			MoveRegistryManager.Upsert(custom)

			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Profile.Damage).to.equal((default :: any).Damage + 777)
		end)

		it("falls back to the Default registry once the custom move is deleted", function()
			local default = DefaultMoveRegistry.Get(DEFAULT_MOVE_ID) :: any
			local custom = MoveTypes.Clone(default)
			custom.Damage = default.Damage + 777
			MoveRegistryManager.Upsert(custom)
			MoveRegistryManager.Delete(DEFAULT_MOVE_ID)

			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Profile.Damage).to.equal(default.Damage)
		end)

		it("sees an edit immediately, because it holds no cache", function()
			-- The Move Editor's whole "edits take effect immediately" design depends on this. A cache
			-- here would need invalidating on both Upsert and Delete and could serve a stale move.
			local default = DefaultMoveRegistry.Get(DEFAULT_MOVE_ID) :: any
			local custom = MoveTypes.Clone(default)
			custom.Damage = 1
			MoveRegistryManager.Upsert(custom)
			expect((AttackCatalog.Get(DEFAULT_MOVE_ID) :: any).Profile.Damage).to.equal(1)

			custom = MoveTypes.Clone(custom)
			custom.Damage = 2
			MoveRegistryManager.Upsert(custom)
			expect((AttackCatalog.Get(DEFAULT_MOVE_ID) :: any).Profile.Damage).to.equal(2)
		end)
	end)

	describe("AttackCatalog.Get -- the WindupSeconds override's Cooldown bound", function()
		-- Constants.Combat.Weapons.Primary.Stages.Basic[1]: WindupSeconds 0.31, ActiveSeconds 0.22,
		-- RecoverySeconds 0.14, Cooldown 0.44. Active+Recovery = 0.36, so the override survives only
		-- when it is at least Cooldown - (Active+Recovery) = 0.08.
		local ANIMATION_ID = "rbxassetid://104588315151150" -- AttackAnimations["default:Primary:Basic:1"]

		local function serveMarker(time: number): ()
			AttackWindows.SetExtractor(function(): KeyframeSequence?
				local sequence = Instance.new("KeyframeSequence")
				local keyframe = Instance.new("Keyframe")
				keyframe.Time = time
				local marker = Instance.new("KeyframeMarker")
				marker.Name = "AttackM1"
				marker.Parent = keyframe
				keyframe.Parent = sequence
				return sequence
			end)
		end

		afterEach(function()
			AttackWindows.Reset()
			AttackWindows.SetExtractor(function()
				return nil
			end)
		end)

		it("keeps the hardcoded WindupSeconds when the override would drop the swing below its own Cooldown", function()
			serveMarker(0.05) -- 0.05 + 0.22 + 0.14 = 0.41, under the 0.44 Cooldown
			AttackWindows.Prefetch(ANIMATION_ID, "AttackM1")
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Definition.WindupSeconds).to.be.near(0.31, 1e-6)
		end)

		it("applies the override once the swing still meets or exceeds its own Cooldown", function()
			serveMarker(0.10) -- 0.10 + 0.22 + 0.14 = 0.46, at or over the 0.44 Cooldown
			AttackWindows.Prefetch(ANIMATION_ID, "AttackM1")
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Definition.WindupSeconds).to.be.near(0.10, 1e-6)
		end)
	end)

	describe("AttackCatalog.Has", function()
		it("answers existence without paying for the projection", function()
			expect(AttackCatalog.Has(DEFAULT_MOVE_ID)).to.equal(true)
			expect(AttackCatalog.Has("no-such-move")).to.equal(false)
			expect(AttackCatalog.Has("")).to.equal(false)
		end)
	end)
end
