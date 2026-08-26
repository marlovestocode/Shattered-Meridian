--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EffectSystem = require(ServerScriptService.Server.Systems.EffectSystem)
local Types = require(ReplicatedStorage.Shared.Types)

-- EffectSystem.Init() is never called in this spec file, the same "requiring the module never calls
-- Init()" contract PlayerDataSystem.spec/QiSystem.spec already rely on -- every function under test
-- here is Player-KEYED but reads/writes only this module's own per-player table, seeded lazily on
-- first use (EffectSystem.lua's own header on why that differs from QiSystem's OnProfileLoaded-seeded
-- one). A plain table stands in for Player throughout, the same trick those specs already use --
-- valid because EffectSystem never touches anything Player-specific beyond using it as an opaque
-- table key and reading `.Name` for a log line.
--
-- The one live dependency, QiSystem.Restore (called by Apply for a "QiRestore" Instant effect), is
-- itself a safe no-op for a player QiSystem was never seeded for (QiSystem.spec.lua's own "Spend/
-- Refund are safe no-ops" coverage already establishes that contract) -- so exercising Apply's
-- QiRestore branch here needs no live QiSystem state, only that it does not error and does not track
-- anything.

local function timedSpec(durationSeconds: number): Types.ActiveModifierSpec
	return {
		Kind = "Tag",
		Lifetime = "Timed",
		Tag = "TestTag",
		Magnitude = 1,
		DurationSeconds = durationSeconds,
	}
end

local function boundAttributeSpec(key: Types.ActiveModifierAttributeKey, delta: number): Types.ActiveModifierSpec
	return {
		Kind = "AttributeDelta",
		Lifetime = "Bound",
		AttributeKey = key,
		Delta = delta,
	}
end

return function()
	describe("EffectSystem.Apply", function()
		it("tracks a Timed spec and returns a non-empty Id", function()
			local player = {} :: any
			local id = EffectSystem.Apply(player, "RaceTrait", "trait-a", timedSpec(30))

			expect(id).never.to.equal(nil)
			expect((id :: string) ~= "").to.equal(true)
			local modifiers = EffectSystem.GetActiveModifiers(player)
			expect(#modifiers).to.equal(1)
			expect(modifiers[1].Id).to.equal(id)
			expect(modifiers[1].SourceKind).to.equal("RaceTrait")
			expect(modifiers[1].SourceId).to.equal("trait-a")
			expect(modifiers[1].ExpiresAt).never.to.equal(nil)
		end)

		it("refuses a Bound-lifetime spec, tracking nothing", function()
			local player = {} :: any
			local id = EffectSystem.Apply(player, "RaceTrait", "trait-a", boundAttributeSpec("Might", 5))

			expect(id).to.equal(nil)
			expect(#EffectSystem.GetActiveModifiers(player)).to.equal(0)
		end)

		it("never tracks an Instant QiRestore spec, and does not error with no live QiSystem state", function()
			local player = {} :: any
			local id = EffectSystem.Apply(player, "BloodlineStage", "bloodline-a", {
				Kind = "QiRestore",
				Lifetime = "Instant",
				QiRestoreAmount = 20,
			})

			expect(id).to.equal(nil)
			expect(#EffectSystem.GetActiveModifiers(player)).to.equal(0)
		end)

		it("refuses an Instant spec with an unsupported Kind, tracking nothing", function()
			local player = {} :: any
			local id = EffectSystem.Apply(player, "RaceTrait", "trait-a", {
				Kind = "Tag",
				Lifetime = "Instant",
				Tag = "NotSupportedAsInstant",
			})

			expect(id).to.equal(nil)
			expect(#EffectSystem.GetActiveModifiers(player)).to.equal(0)
		end)
	end)

	describe("EffectSystem.ReclaimExpiredModifiers (Timed tick-expire)", function()
		it("removes a Timed modifier once now has passed its ExpiresAt", function()
			local player = {} :: any
			local id = EffectSystem.Apply(player, "RaceTrait", "trait-a", timedSpec(5))
			local appliedAt = EffectSystem.GetActiveModifiers(player)[1].AppliedAt

			-- Comfortably before expiry -- must survive.
			EffectSystem.ReclaimExpiredModifiers(appliedAt + 1)
			expect(#EffectSystem.GetActiveModifiers(player)).to.equal(1)

			-- Comfortably after expiry -- must be reclaimed.
			EffectSystem.ReclaimExpiredModifiers(appliedAt + 999)
			expect(#EffectSystem.GetActiveModifiers(player)).to.equal(0)
			expect(EffectSystem.Clear(player, id :: string)).to.equal(false)
		end)

		it("never touches a Bound modifier regardless of how far now advances", function()
			local player = {} :: any
			EffectSystem.SetBoundModifiers(player, "RaceTrait", "trait-a", { boundAttributeSpec("Might", 5) })

			EffectSystem.ReclaimExpiredModifiers(os.clock() + 100000)

			expect(#EffectSystem.GetActiveModifiers(player)).to.equal(1)
		end)

		it("only reclaims the expired entry, leaving a not-yet-expired one from a different source alone", function()
			local player = {} :: any
			EffectSystem.Apply(player, "RaceTrait", "trait-a", timedSpec(1))
			local farOutId = EffectSystem.Apply(player, "BloodlineStage", "bloodline-a", timedSpec(1000))
			local farOutAppliedAt = EffectSystem.GetActiveModifiers(player)[1].AppliedAt

			EffectSystem.ReclaimExpiredModifiers(farOutAppliedAt + 5)

			local remaining = EffectSystem.GetActiveModifiers(player)
			expect(#remaining).to.equal(1)
			expect(remaining[1].Id).to.equal(farOutId)
		end)
	end)

	describe("EffectSystem.SetBoundModifiers (atomic replace)", function()
		it("tracks every spec in the given set under the given source", function()
			local player = {} :: any
			EffectSystem.SetBoundModifiers(
				player,
				"RaceTrait",
				"trait-a",
				{ boundAttributeSpec("Might", 5), boundAttributeSpec("Pressure", 3) }
			)

			expect(#EffectSystem.GetActiveModifiers(player)).to.equal(2)
			expect(EffectSystem.GetAttributeDelta(player, "Might")).to.equal(5)
			expect(EffectSystem.GetAttributeDelta(player, "Pressure")).to.equal(3)
		end)

		it("replaces the previous set from the same source entirely on the next call", function()
			local player = {} :: any
			EffectSystem.SetBoundModifiers(
				player,
				"RaceTrait",
				"trait-a",
				{ boundAttributeSpec("Might", 5), boundAttributeSpec("Pressure", 3) }
			)

			EffectSystem.SetBoundModifiers(player, "RaceTrait", "trait-a", { boundAttributeSpec("Might", 8) })

			expect(#EffectSystem.GetActiveModifiers(player)).to.equal(1)
			expect(EffectSystem.GetAttributeDelta(player, "Might")).to.equal(8)
			expect(EffectSystem.GetAttributeDelta(player, "Pressure")).to.equal(0)
		end)

		it("clears every modifier from the source when given an empty set", function()
			local player = {} :: any
			EffectSystem.SetBoundModifiers(player, "RaceTrait", "trait-a", { boundAttributeSpec("Might", 5) })

			EffectSystem.SetBoundModifiers(player, "RaceTrait", "trait-a", {})

			expect(#EffectSystem.GetActiveModifiers(player)).to.equal(0)
		end)

		it("never touches a Bound modifier held by a DIFFERENT source", function()
			local player = {} :: any
			EffectSystem.SetBoundModifiers(player, "RaceTrait", "trait-a", { boundAttributeSpec("Might", 5) })
			EffectSystem.SetBoundModifiers(
				player,
				"BloodlineStage",
				"bloodline-a",
				{ boundAttributeSpec("Pressure", 2) }
			)

			EffectSystem.SetBoundModifiers(player, "RaceTrait", "trait-a", {})

			expect(EffectSystem.GetAttributeDelta(player, "Might")).to.equal(0)
			expect(EffectSystem.GetAttributeDelta(player, "Pressure")).to.equal(2)
		end)

		it("drops a non-Bound entry rather than mistracking it or throwing", function()
			local player = {} :: any
			EffectSystem.SetBoundModifiers(player, "RaceTrait", "trait-a", { timedSpec(30) })

			expect(#EffectSystem.GetActiveModifiers(player)).to.equal(0)
		end)
	end)

	describe("EffectSystem.Clear / ClearAllFromSource", function()
		it("Clear removes a tracked modifier by Id and returns true", function()
			local player = {} :: any
			local id = EffectSystem.Apply(player, "RaceTrait", "trait-a", timedSpec(30)) :: string

			expect(EffectSystem.Clear(player, id)).to.equal(true)
			expect(#EffectSystem.GetActiveModifiers(player)).to.equal(0)
		end)

		it("Clear returns false for an unknown Id, without erroring", function()
			local player = {} :: any
			expect(EffectSystem.Clear(player, "not-a-real-id")).to.equal(false)
		end)

		it(
			"ClearAllFromSource removes every Timed and Bound modifier from that source and reports the count",
			function()
				local player = {} :: any
				EffectSystem.Apply(player, "RaceTrait", "trait-a", timedSpec(30))
				EffectSystem.SetBoundModifiers(player, "RaceTrait", "trait-a", { boundAttributeSpec("Might", 5) })
				EffectSystem.SetBoundModifiers(
					player,
					"BloodlineStage",
					"bloodline-a",
					{ boundAttributeSpec("Pressure", 2) }
				)

				local removed = EffectSystem.ClearAllFromSource(player, "RaceTrait", "trait-a")

				expect(removed).to.equal(2)
				local remaining = EffectSystem.GetActiveModifiers(player)
				expect(#remaining).to.equal(1)
				expect(remaining[1].SourceKind).to.equal("BloodlineStage")
			end
		)

		it("ClearAllFromSource returns 0 for a source that holds nothing", function()
			local player = {} :: any
			expect(EffectSystem.ClearAllFromSource(player, "RaceTrait", "no-such-trait")).to.equal(0)
		end)
	end)

	describe("EffectSystem.GetAttributeDelta / HasTag / GetTagMagnitude (stacking)", function()
		it("sums AttributeDelta across multiple sources targeting the same key", function()
			local player = {} :: any
			EffectSystem.SetBoundModifiers(player, "RaceTrait", "trait-a", { boundAttributeSpec("Fleetness", 4) })
			EffectSystem.SetBoundModifiers(
				player,
				"BloodlineStage",
				"bloodline-a",
				{ boundAttributeSpec("Fleetness", 6) }
			)

			expect(EffectSystem.GetAttributeDelta(player, "Fleetness")).to.equal(10)
		end)

		it("is zero for an AttributeKey nothing currently targets", function()
			local player = {} :: any
			EffectSystem.SetBoundModifiers(player, "RaceTrait", "trait-a", { boundAttributeSpec("Might", 5) })

			expect(EffectSystem.GetAttributeDelta(player, "Vitality")).to.equal(0)
		end)

		it("HasTag is true regardless of Magnitude, including zero", function()
			local player = {} :: any
			EffectSystem.Apply(player, "RaceTrait", "trait-a", {
				Kind = "Tag",
				Lifetime = "Timed",
				Tag = "ZeroMagTag",
				Magnitude = 0,
				DurationSeconds = 30,
			})

			expect(EffectSystem.HasTag(player, "ZeroMagTag")).to.equal(true)
			expect(EffectSystem.GetTagMagnitude(player, "ZeroMagTag")).to.equal(0)
		end)

		it("GetTagMagnitude sums stacking grants of the same tag from different sources", function()
			local player = {} :: any
			EffectSystem.SetBoundModifiers(player, "RaceTrait", "trait-a", {
				{ Kind = "Tag", Lifetime = "Bound", Tag = "Resilient", Magnitude = 2 },
			})
			EffectSystem.Apply(player, "BloodlineStage", "bloodline-a", {
				Kind = "Tag",
				Lifetime = "Timed",
				Tag = "Resilient",
				Magnitude = 3,
				DurationSeconds = 30,
			})

			expect(EffectSystem.GetTagMagnitude(player, "Resilient")).to.equal(5)
		end)

		it("HasTag/GetTagMagnitude are false/zero for a tag nothing holds", function()
			local player = {} :: any
			expect(EffectSystem.HasTag(player, "NeverGranted")).to.equal(false)
			expect(EffectSystem.GetTagMagnitude(player, "NeverGranted")).to.equal(0)
		end)
	end)

	describe("EffectSystem.GetActiveModifiers", function()
		it("returns a copy -- mutating the result never affects the tracked modifier", function()
			local player = {} :: any
			local id = EffectSystem.Apply(player, "RaceTrait", "trait-a", timedSpec(30)) :: string

			local snapshot = EffectSystem.GetActiveModifiers(player)
			snapshot[1].Spec.Magnitude = 999
			snapshot[1].SourceId = "tampered"

			local fresh = EffectSystem.GetActiveModifiers(player)
			expect(fresh[1].Id).to.equal(id)
			expect(fresh[1].Spec.Magnitude).to.equal(1)
			expect(fresh[1].SourceId).to.equal("trait-a")
		end)
	end)

	describe("EffectSystem (no modifier ever applied)", function()
		it("every reader is a safe zero/empty/false result for an untouched player", function()
			local player = {} :: any
			expect(#EffectSystem.GetActiveModifiers(player)).to.equal(0)
			expect(EffectSystem.GetAttributeDelta(player, "Might")).to.equal(0)
			expect(EffectSystem.HasTag(player, "Anything")).to.equal(false)
			expect(EffectSystem.GetTagMagnitude(player, "Anything")).to.equal(0)
			expect(EffectSystem.Clear(player, "no-such-id")).to.equal(false)
			expect(EffectSystem.ClearAllFromSource(player, "RaceTrait", "no-such-trait")).to.equal(0)
		end)
	end)
end
