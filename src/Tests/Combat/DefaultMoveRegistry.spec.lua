--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry) :: any
local Constants = require(game:GetService("ReplicatedStorage").Shared.Constants)
local LiveTuningContract = require(ServerScriptService.Tests.TestHelpers.LiveTuningContract)

-- DefaultMoveRegistry mutates the REAL, shared Constants.Combat.Weapons/DashPunch/DashHit/AirSlam
-- tables (that is the whole point of this module -- see its own header, and HitboxTuning.lua's
-- before it) -- and TestEZ runs every spec file in one Lua VM/session, so a leaked mutation here
-- would silently change combat behavior for any other spec that happens to read the same attack
-- afterward. Every test that mutates something resets it back inline before returning, rather than
-- relying on an afterEach hook, so this stays correct regardless of hook support/ordering -- see
-- TestHelpers/LiveTuningContract.lua's own header for the shared "mutate+assert, then guarantee the
-- reset still runs" wrapper this file's ApplyEdit tests use.

-- Converts a MoveDefinition projection (DefaultMoveRegistry.List/Get/ApplyEdit/Reset's own return
-- shape) into the wire candidate MoveRegistryManager.Validate (and so DefaultMoveRegistry.ApplyEdit)
-- expects -- Offset decomposed into flat OffsetX/Y/Z numbers, same conversion
-- MoveEditorClient.encodeDraftForWire does for a real client request.
local function toCandidate(move: { [string]: any }): { [string]: any }
	local candidate = table.clone(move)
	local offset = move.Offset :: CFrame
	candidate.Offset = nil
	candidate.OffsetX = offset.X
	candidate.OffsetY = offset.Y
	candidate.OffsetZ = offset.Z
	return candidate
end

local function countMatching(moves: { any }, pattern: string): number
	local count = 0
	for _, move in ipairs(moves) do
		if (move.MoveId :: string):match(pattern) then
			count += 1
		end
	end
	return count
end

return function()
	describe("DefaultMoveRegistry.List", function()
		it("returns at least one Basic stage and exactly one Finisher per weapon", function()
			local moves = DefaultMoveRegistry.List()
			expect(countMatching(moves, "^default:Primary:Basic:") > 0).to.equal(true)
			expect(countMatching(moves, "^default:Secondary:Basic:") > 0).to.equal(true)
			expect(countMatching(moves, "^default:Primary:Finisher$")).to.equal(1)
			expect(countMatching(moves, "^default:Secondary:Finisher$")).to.equal(1)
		end)

		it("includes all three standalone attacks", function()
			local moves = DefaultMoveRegistry.List()
			expect(countMatching(moves, "^default:DashPunch$")).to.equal(1)
			expect(countMatching(moves, "^default:DashHit$")).to.equal(1)
			expect(countMatching(moves, "^default:AirSlam$")).to.equal(1)
		end)

		it('every move is stamped Category = "Default", Author = "System", no animation/sub-tables', function()
			for _, move in ipairs(DefaultMoveRegistry.List()) do
				expect(move.Category).to.equal("Default")
				expect(move.Author).to.equal("System")
				expect(move.AnimationId).to.equal("")
				expect(move.Movement).to.equal(nil)
				expect(move.Knockback).to.equal(nil)
				expect(move.Projectile).to.equal(nil)
			end
		end)

		it("every move reports positive timing fields", function()
			for _, move in ipairs(DefaultMoveRegistry.List()) do
				expect(move.WindupSeconds > 0).to.equal(true)
				expect(move.ActiveSeconds > 0).to.equal(true)
				expect(move.RecoverySeconds > 0).to.equal(true)
			end
		end)
	end)

	describe("DefaultMoveRegistry.Get", function()
		it("resolves a known synthetic MoveId", function()
			local move = DefaultMoveRegistry.Get("default:Primary:Basic:1")
			expect(move).to.be.ok()
			expect((move :: any).DisplayName).to.equal("Primary Basic 1")
		end)

		it("returns nil for an unknown MoveId", function()
			expect(DefaultMoveRegistry.Get("default:NotARealMove")).to.equal(nil)
		end)
	end)

	describe("DefaultMoveRegistry.ApplyEdit", function()
		it("mutates the live stage and returns the updated value", function()
			local before = DefaultMoveRegistry.Get("default:Primary:Basic:1")
			expect(before).to.be.ok()
			local baseline = (before :: any).WindupSeconds :: number

			LiveTuningContract.withRestore(function()
				local candidate = toCandidate(before :: any)
				candidate.WindupSeconds = baseline + 0.05
				local result = DefaultMoveRegistry.ApplyEdit("default:Primary:Basic:1", candidate)
				expect(result).to.be.ok()
				expect((result :: any).WindupSeconds).to.equal(baseline + 0.05)
			end, function()
				DefaultMoveRegistry.Reset("default:Primary:Basic:1")
			end)
		end)

		it("persists the mutation for a later List call (proves the live-reference claim)", function()
			LiveTuningContract.withRestore(function()
				local before = DefaultMoveRegistry.Get("default:Primary:Basic:1") :: any
				local candidate = toCandidate(before)
				candidate.ActiveSeconds = 0.2 + before.ActiveSeconds
				DefaultMoveRegistry.ApplyEdit("default:Primary:Basic:1", candidate)

				local found = false
				for _, move in ipairs(DefaultMoveRegistry.List()) do
					if move.MoveId == "default:Primary:Basic:1" then
						found = true
						expect(move.ActiveSeconds >= 0.2).to.equal(true)
					end
				end
				expect(found).to.equal(true)
			end, function()
				DefaultMoveRegistry.Reset("default:Primary:Basic:1")
			end)
		end)

		it("never touches the live DebugName", function()
			LiveTuningContract.withRestore(function()
				local before = DefaultMoveRegistry.Get("default:Primary:Basic:1") :: any
				local candidate = toCandidate(before)
				candidate.Damage = 999
				DefaultMoveRegistry.ApplyEdit("default:Primary:Basic:1", candidate)
				expect(Constants.Combat.Weapons.Primary.Stages.Basic[1].DebugName).to.equal("Basic1")
			end, function()
				DefaultMoveRegistry.Reset("default:Primary:Basic:1")
			end)
		end)

		it("clamps a value beyond the sanity ceiling via MoveRegistryManager.Validate", function()
			LiveTuningContract.withRestore(function()
				local before = DefaultMoveRegistry.Get("default:Primary:Basic:1") :: any
				local candidate = toCandidate(before)
				candidate.WindupSeconds = 999
				local result = DefaultMoveRegistry.ApplyEdit("default:Primary:Basic:1", candidate)
				expect(result).to.be.ok()
				expect((result :: any).WindupSeconds).to.equal(5)
			end, function()
				DefaultMoveRegistry.Reset("default:Primary:Basic:1")
			end)
		end)

		it("widens the editable surface to Shape/Size/Radius (beyond HitboxTuning's old timing-only scope)", function()
			LiveTuningContract.withRestore(function()
				local before = DefaultMoveRegistry.Get("default:Primary:Basic:1") :: any
				local candidate = toCandidate(before)
				candidate.Shape = "Sphere"
				-- Authored through Dimensions, NOT the legacy top-level Radius field. toCandidate clones
				-- the whole move, so the candidate still carries the Box's own Dimensions bag -- and
				-- Dimensions is authoritative: Size/Radius are DERIVED from it by Validate, never
				-- separately authored (see MoveTypes.lua's header). Setting `candidate.Radius = 6` here
				-- and expecting 6 back asserted the opposite precedence, so it read the Box default's
				-- Dimensions.Radius (4) instead and had been failing.
				candidate.Dimensions = table.clone(candidate.Dimensions)
				candidate.Dimensions.Radius = 6
				candidate.Size = nil
				local result = DefaultMoveRegistry.ApplyEdit("default:Primary:Basic:1", candidate) :: any
				expect(result).to.be.ok()
				expect(result.Shape).to.equal("Sphere")
				expect(result.Radius).to.equal(6)
				expect(result.Size).to.equal(nil)
				expect(Constants.Combat.Weapons.Primary.Stages.Basic[1].Shape).to.equal("Sphere")
			end, function()
				DefaultMoveRegistry.Reset("default:Primary:Basic:1")
			end)
		end)

		it("returns nil for an unknown MoveId", function()
			local result, reason = DefaultMoveRegistry.ApplyEdit("default:NotARealMove", {})
			expect(result).to.equal(nil)
			expect(reason).to.equal("InvalidMoveId")
		end)

		it("rejects a structurally invalid candidate without mutating the live table", function()
			local before = DefaultMoveRegistry.Get("default:DashPunch") :: any
			local result, reason = DefaultMoveRegistry.ApplyEdit("default:DashPunch", { Shape = "NotAShape" })
			expect(result).to.equal(nil)
			expect(reason).to.be.ok()
			local after = DefaultMoveRegistry.Get("default:DashPunch") :: any
			expect(after.WindupSeconds).to.equal(before.WindupSeconds)
		end)

		it("edits a standalone attack (DashPunch) the same way as a weapon stage", function()
			local before = DefaultMoveRegistry.Get("default:DashPunch") :: any
			local baselineOffsetZ = before.Offset.Z

			LiveTuningContract.withRestore(function()
				local candidate = toCandidate(before)
				candidate.OffsetZ = baselineOffsetZ - 1
				local result = DefaultMoveRegistry.ApplyEdit("default:DashPunch", candidate) :: any
				expect(result).to.be.ok()
				expect(result.Offset.Z).to.equal(baselineOffsetZ - 1)
			end, function()
				DefaultMoveRegistry.Reset("default:DashPunch")
			end)
		end)
	end)

	describe("DefaultMoveRegistry.Reset", function()
		it("restores the captured file default after a mutation", function()
			local original = DefaultMoveRegistry.Get("default:Primary:Basic:2") :: any
			local originalWindup = original.WindupSeconds

			local candidate = toCandidate(original)
			candidate.WindupSeconds = originalWindup + 1
			DefaultMoveRegistry.ApplyEdit("default:Primary:Basic:2", candidate)

			local restored = DefaultMoveRegistry.Reset("default:Primary:Basic:2")
			expect(restored).to.be.ok()
			expect((restored :: any).WindupSeconds).to.equal(originalWindup)
		end)

		it("returns nil for an unknown MoveId", function()
			expect(DefaultMoveRegistry.Reset("default:NotARealMove")).to.equal(nil)
		end)
	end)
end
