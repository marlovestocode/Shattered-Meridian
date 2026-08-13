--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local Fixtures = require(ServerScriptService.Tests.TestHelpers.Fixtures)

-- A well-formed Box move candidate in the WIRE shape MoveRegistryManager.Validate expects
-- (OffsetX/Y/Z flat numbers, not a CFrame -- see Validate's own header) -- mirrors exactly what
-- MoveEditorClient.lua's encodeDraftForWire produces.
local function makeBoxCandidate(overrides: { [string]: any }?): { [string]: any }
	local candidate = {
		MoveId = "test-move",
		DisplayName = "Test Move",
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
	describe("MoveRegistryManager.Validate", function()
		it("accepts a well-formed Box move", function()
			local move, reason = MoveRegistryManager.Validate(makeBoxCandidate())
			expect(reason).to.equal(nil)
			expect(move).to.be.ok()
			expect((move :: any).Shape).to.equal("Box")
			expect((move :: any).Size).to.equal(Vector3.new(4, 4, 4))
			expect((move :: any).Radius).to.equal(nil)
			expect((move :: any).Offset).to.equal(CFrame.new(0, 0, -3))
		end)

		it("accepts a well-formed Sphere move", function()
			local candidate = makeBoxCandidate({ Shape = "Sphere", Size = nil, Radius = 5 })
			local move, reason = MoveRegistryManager.Validate(candidate)
			expect(reason).to.equal(nil)
			expect(move).to.be.ok()
			expect((move :: any).Shape).to.equal("Sphere")
			expect((move :: any).Radius).to.equal(5)
			expect((move :: any).Size).to.equal(nil)
		end)

		it("rejects a non-table candidate", function()
			local move, reason = MoveRegistryManager.Validate("not a table")
			expect(move).to.equal(nil)
			expect(reason).to.equal("InvalidShape")
		end)

		it("rejects a missing MoveId", function()
			local move, reason = MoveRegistryManager.Validate(makeBoxCandidate({ MoveId = "" }))
			expect(move).to.equal(nil)
			expect(reason).to.equal("InvalidMoveId")
		end)

		-- v1 rejected these as MissingSize/MissingRadius. Dimensions replaced that pair, so the single
		-- MissingDimensions is now the successor to both -- see dimensionsFromCandidate's own header on
		-- why "geometry cannot be determined at all" stayed a hard reject rather than defaulting.
		-- `Size` is REMOVED after the fact rather than passed as `{ Size = nil }`. A Lua table
		-- constructor stores nothing for an explicit nil value, so `{ Size = nil }` is simply `{}` and
		-- Fixtures.applyOverrides (a `pairs` loop) has no key to apply -- meaning both of these tests
		-- used to hand Validate a candidate that still carried its default Size, and assert it was
		-- rejected. It never was, and never could have been.
		it("rejects Shape == Box with neither Size nor Dimensions", function()
			local candidate = makeBoxCandidate()
			candidate.Size = nil
			local move, reason = MoveRegistryManager.Validate(candidate)
			expect(move).to.equal(nil)
			expect(reason).to.equal("MissingDimensions")
		end)

		it("rejects Shape == Sphere with neither Radius nor Dimensions", function()
			local candidate = makeBoxCandidate({ Shape = "Sphere" })
			candidate.Size = nil
			local move, reason = MoveRegistryManager.Validate(candidate)
			expect(move).to.equal(nil)
			expect(reason).to.equal("MissingDimensions")
		end)

		-- The reserved-category gate. A custom move claiming "Default" would masquerade as a
		-- DefaultMoveRegistry projection to every UI consumer without being backed by a live Constants
		-- table -- unreachable and undeletable. See Validate's own allowReservedCategory header.
		it("rejects the reserved Default category from a client-submitted candidate", function()
			local candidate = makeBoxCandidate({ Category = MoveTypes.DefaultCategory })
			local move, reason = MoveRegistryManager.Validate(candidate)
			expect(move).to.equal(nil)
			expect(reason).to.equal("ReservedCategory")
		end)

		it("accepts the reserved Default category when allowReservedCategory is true", function()
			local candidate = makeBoxCandidate({ Category = MoveTypes.DefaultCategory })
			local move, reason = MoveRegistryManager.Validate(candidate, true)
			expect(reason).to.equal(nil)
			expect(move).to.be.ok()
			expect((move :: any).Category).to.equal(MoveTypes.DefaultCategory)
		end)

		-- Pinned deliberately: the sentinel is an EXACT match, because DefaultMoveRegistry writes
		-- exactly "Default" and every UI filter compares with ==. A lowercase category is an ordinary
		-- author tag, and making the gate case-insensitive would be a silent behaviour change.
		it("accepts a lowercase 'default' as an ordinary category", function()
			local move, reason = MoveRegistryManager.Validate(makeBoxCandidate({ Category = "default" }))
			expect(reason).to.equal(nil)
			expect(move).to.be.ok()
			expect((move :: any).Category).to.equal("default")
		end)

		it("still accepts an empty category", function()
			local move, reason = MoveRegistryManager.Validate(makeBoxCandidate({ Category = "" }))
			expect(reason).to.equal(nil)
			expect(move).to.be.ok()
		end)

		it("rejects an unrecognized Shape", function()
			local move, reason = MoveRegistryManager.Validate(makeBoxCandidate({ Shape = "Trapezoid" }))
			expect(move).to.equal(nil)
			expect(reason).to.equal("InvalidShapeField")
		end)

		-- The complement of the case above, and the regression that matters most about the widened
		-- vocabulary: "Cone" USED to be an unrecognized shape and is now a real one. A shape beyond the
		-- original Box/Sphere pair carries its geometry in Dimensions only, so it must validate without
		-- a Size and must come back with both legacy fields nil -- see deriveLegacyGeometry.
		it("accepts a non-legacy shape carrying Dimensions", function()
			local candidate = makeBoxCandidate({
				Shape = "Cone",
				Dimensions = { Length = 12, AngleDegrees = 45 },
			})
			-- Removed, not overridden to nil -- see the two tests above on why that distinction matters.
			candidate.Size = nil
			local move, reason = MoveRegistryManager.Validate(candidate)
			expect(reason).to.equal(nil)
			expect(move).to.be.ok()
			expect((move :: any).Shape).to.equal("Cone")
			expect((move :: any).Dimensions.Length).to.equal(12)
			expect((move :: any).Dimensions.AngleDegrees).to.equal(45)
			expect((move :: any).Size).to.equal(nil)
			expect((move :: any).Radius).to.equal(nil)
		end)

		it("clamps an out-of-range timing field instead of rejecting it", function()
			local move = MoveRegistryManager.Validate(makeBoxCandidate({ WindupSeconds = 999 }))
			expect(move).to.be.ok()
			expect((move :: any).WindupSeconds).to.equal(5) -- CLAMP_MAX_SECONDS
		end)

		it("rejects a non-string AnimationId", function()
			local move, reason = MoveRegistryManager.Validate(makeBoxCandidate({ AnimationId = 5 }))
			expect(move).to.equal(nil)
			expect(reason).to.equal("InvalidAnimationId")
		end)

		it("accepts a well-formed Movement grant", function()
			local candidate = makeBoxCandidate({ Movement = { LungeDistanceStuds = 8, LungeDurationSeconds = 0.2 } })
			local move, reason = MoveRegistryManager.Validate(candidate)
			expect(reason).to.equal(nil)
			expect((move :: any).Movement.LungeDistanceStuds).to.equal(8)
		end)

		it("rejects a malformed Movement grant", function()
			local candidate = makeBoxCandidate({ Movement = { LungeDistanceStuds = "not a number" } })
			local move, reason = MoveRegistryManager.Validate(candidate)
			expect(move).to.equal(nil)
			expect(reason).to.equal("InvalidMovement")
		end)

		it("leaves Movement/Knockback/Projectile nil when absent", function()
			local move = MoveRegistryManager.Validate(makeBoxCandidate())
			expect((move :: any).Movement).to.equal(nil)
			expect((move :: any).Knockback).to.equal(nil)
			expect((move :: any).Projectile).to.equal(nil)
		end)

		it("accepts a well-formed Projectile config", function()
			local candidate = makeBoxCandidate({ Projectile = { Speed = 40, MaxRange = 60 } })
			local move, reason = MoveRegistryManager.Validate(candidate)
			expect(reason).to.equal(nil)
			expect((move :: any).Projectile.Speed).to.equal(40)
			expect((move :: any).Projectile.MaxRange).to.equal(60)
		end)

		it("clamps an out-of-range Projectile Speed/MaxRange instead of rejecting", function()
			local candidate = makeBoxCandidate({ Projectile = { Speed = 9999, MaxRange = -5 } })
			local move = MoveRegistryManager.Validate(candidate)
			expect(move).to.be.ok()
			expect((move :: any).Projectile.Speed).to.equal(150) -- CLAMP_MAX_PROJECTILE_SPEED
			expect((move :: any).Projectile.MaxRange).to.equal(5) -- CLAMP_MIN_PROJECTILE_RANGE
		end)

		it("rejects a malformed Projectile config", function()
			local candidate = makeBoxCandidate({ Projectile = { Speed = "fast" } })
			local move, reason = MoveRegistryManager.Validate(candidate)
			expect(move).to.equal(nil)
			expect(reason).to.equal("InvalidProjectile")
		end)

		it("defaults Knockback.StartsAirCombo to false when absent", function()
			local candidate =
				makeBoxCandidate({ Knockback = { UpVelocity = 20, HorizontalVelocity = 10, RagdollSeconds = 0.5 } })
			local move, reason = MoveRegistryManager.Validate(candidate)
			expect(reason).to.equal(nil)
			expect((move :: any).Knockback.StartsAirCombo).to.equal(false)
		end)

		it("accepts Knockback.StartsAirCombo == true", function()
			local candidate = makeBoxCandidate({
				Knockback = { UpVelocity = 20, HorizontalVelocity = 10, RagdollSeconds = 0.5, StartsAirCombo = true },
			})
			local move, reason = MoveRegistryManager.Validate(candidate)
			expect(reason).to.equal(nil)
			expect((move :: any).Knockback.StartsAirCombo).to.equal(true)
		end)

		it("rejects a non-boolean Knockback.StartsAirCombo", function()
			local candidate = makeBoxCandidate({
				Knockback = { UpVelocity = 20, HorizontalVelocity = 10, RagdollSeconds = 0.5, StartsAirCombo = "yes" },
			})
			local move, reason = MoveRegistryManager.Validate(candidate)
			expect(move).to.equal(nil)
			expect(reason).to.equal("InvalidKnockback")
		end)
	end)

	describe("MoveTypes.ToHitboxAttackDefinition", function()
		it("projects a Box move losslessly, with DebugName == MoveId", function()
			local move = MoveRegistryManager.Validate(makeBoxCandidate()) :: MoveTypes.MoveDefinition
			local definition = MoveTypes.ToHitboxAttackDefinition(move)
			expect(definition.DebugName).to.equal("test-move")
			expect(definition.WindupSeconds).to.equal(move.WindupSeconds)
			expect(definition.ActiveSeconds).to.equal(move.ActiveSeconds)
			expect(definition.RecoverySeconds).to.equal(move.RecoverySeconds)
			expect(definition.Size).to.equal(move.Size)
			expect(definition.Offset).to.equal(move.Offset)
			expect(definition.Damage).to.equal(move.Damage)
			expect(definition.PostureDamage).to.equal(move.PostureDamage)
			expect(definition.Cooldown).to.equal(move.Cooldown)
			expect(definition.ArcDegrees).to.equal(move.ArcDegrees)
			expect(definition.MaxTargets).to.equal(move.MaxTargets)
			expect(definition.Shape).to.equal("Box")
			expect(definition.Radius).to.equal(nil)
		end)

		it("projects a Sphere move's Shape/Radius through", function()
			local candidate = makeBoxCandidate({ Shape = "Sphere", Size = nil, Radius = 6 })
			local move = MoveRegistryManager.Validate(candidate) :: MoveTypes.MoveDefinition
			local definition = MoveTypes.ToHitboxAttackDefinition(move)
			expect(definition.Shape).to.equal("Sphere")
			expect(definition.Radius).to.equal(6)
			expect(definition.Size).to.equal(nil)
		end)

		it("projects Knockback through when present", function()
			local candidate =
				makeBoxCandidate({ Knockback = { UpVelocity = 20, HorizontalVelocity = 10, RagdollSeconds = 0.5 } })
			local move = MoveRegistryManager.Validate(candidate) :: MoveTypes.MoveDefinition
			local definition = MoveTypes.ToHitboxAttackDefinition(move)
			expect(definition.Knockback).to.be.ok()
			expect((definition.Knockback :: any).UpVelocity).to.equal(20)
		end)

		it("projects Projectile through when present", function()
			local candidate = makeBoxCandidate({ Projectile = { Speed = 40, MaxRange = 60 } })
			local move = MoveRegistryManager.Validate(candidate) :: MoveTypes.MoveDefinition
			local definition = MoveTypes.ToHitboxAttackDefinition(move)
			expect(definition.Projectile).to.be.ok()
			expect((definition.Projectile :: any).Speed).to.equal(40)
			expect((definition.Projectile :: any).MaxRange).to.equal(60)
		end)

		it("leaves Projectile nil for an ordinary melee move", function()
			local move = MoveRegistryManager.Validate(makeBoxCandidate()) :: MoveTypes.MoveDefinition
			local definition = MoveTypes.ToHitboxAttackDefinition(move)
			expect(definition.Projectile).to.equal(nil)
		end)
	end)

	-- A move carrying every optional sub-table, including the one three-level path in this schema
	-- (ObjectStun -> FollowUp -> Dimensions). Built through Validate so it is a real, normalized
	-- MoveDefinition rather than a hand-assembled approximation of one.
	local function makeRichMove(): MoveTypes.MoveDefinition
		local candidate = makeBoxCandidate({
			Movement = { LungeDistanceStuds = 8, LungeDurationSeconds = 0.2 },
			Knockback = { UpVelocity = 20, HorizontalVelocity = 10, RagdollSeconds = 0.6, StartsAirCombo = true },
			Projectile = { Speed = 40, MaxRange = 60 },
			Animations = {
				{ AnimationId = "rbxassetid://1", StartSeconds = 0, Speed = 1, Weight = 1 },
				{ AnimationId = "rbxassetid://2", StartSeconds = 0.3, Speed = 1, Weight = 1 },
			},
			ObjectStun = {
				Enabled = true,
				Surfaces = { Walls = true, Floors = false, Ceilings = false, Props = true },
				BonusDamage = 12,
				FollowUp = {
					Enabled = true,
					DelaySeconds = 0.1,
					WindupSeconds = 0.1,
					ActiveSeconds = 0.1,
					RecoverySeconds = 0.1,
					Damage = 9,
					PostureDamage = 4,
					MaxTargets = 1,
					Shape = "Box",
					AnimationId = "",
				},
			},
		})
		return MoveRegistryManager.Validate(candidate) :: MoveTypes.MoveDefinition
	end

	describe("MoveTypes.DefaultCategory", function()
		it("is the exact sentinel DefaultMoveRegistry stamps", function()
			expect(MoveTypes.DefaultCategory).to.equal("Default")
		end)
	end)

	describe("MoveTypes.Clone", function()
		it("preserves every authored field", function()
			local original = makeRichMove()
			local copy = MoveTypes.Clone(original)
			expect(copy.DisplayName).to.equal(original.DisplayName)
			expect(copy.Category).to.equal(original.Category)
			expect(copy.Shape).to.equal(original.Shape)
			expect(copy.Offset).to.equal(original.Offset)
			expect(copy.Damage).to.equal(original.Damage)
			expect(#copy.Animations).to.equal(#original.Animations)
		end)

		it("does not alias Dimensions", function()
			local original = makeRichMove()
			local copy = MoveTypes.Clone(original)
			expect(copy.Dimensions).never.to.equal(original.Dimensions)
			copy.Dimensions.Width = 99
			expect(original.Dimensions.Width).never.to.equal(99)
		end)

		it("does not alias Movement/Knockback/Projectile", function()
			local original = makeRichMove()
			local copy = MoveTypes.Clone(original);
			(copy.Movement :: any).LungeDistanceStuds = 99
			(copy.Knockback :: any).UpVelocity = 99
			(copy.Projectile :: any).Speed = 99
			expect((original.Movement :: any).LungeDistanceStuds).to.equal(8)
			expect((original.Knockback :: any).UpVelocity).to.equal(20)
			expect((original.Projectile :: any).Speed).to.equal(40)
		end)

		it("does not alias individual Animations clips", function()
			local original = makeRichMove()
			local copy = MoveTypes.Clone(original)
			copy.Animations[1].StartSeconds = 99
			expect(original.Animations[1].StartSeconds).never.to.equal(99)
		end)

		-- The deepest path in the schema, and the one a shallow clone silently gets wrong.
		it("does not alias ObjectStun.Surfaces or ObjectStun.FollowUp.Dimensions", function()
			local original = makeRichMove()
			local copy = MoveTypes.Clone(original)
			local copyStun = copy.ObjectStun :: any
			local originalStun = original.ObjectStun :: any
			copyStun.Surfaces.Walls = false
			copyStun.FollowUp.Damage = 99
			copyStun.FollowUp.Dimensions.Width = 99
			expect(originalStun.Surfaces.Walls).to.equal(true)
			expect(originalStun.FollowUp.Damage).to.equal(9)
			expect(originalStun.FollowUp.Dimensions.Width).never.to.equal(99)
		end)

		it("round-trips to an identical fingerprint", function()
			local original = makeRichMove()
			expect(MoveTypes.Fingerprint(MoveTypes.Clone(original))).to.equal(MoveTypes.Fingerprint(original))
		end)
	end)

	describe("MoveTypes.Fingerprint", function()
		it("is stable across repeated calls", function()
			local move = makeRichMove()
			expect(MoveTypes.Fingerprint(move)).to.equal(MoveTypes.Fingerprint(move))
		end)

		-- Two independently-constructed moves with identical content must digest identically -- the
		-- property digestValue's sort-keys-at-every-level walk exists to guarantee, since `pairs`
		-- order is unspecified and a rebuilt sub-table is free to enumerate differently.
		it("matches across two independently built but identical moves", function()
			local a = makeRichMove()
			local b = makeRichMove();
			(b :: any).Dimensions = table.clone(a.Dimensions)
			expect(MoveTypes.Fingerprint(b)).to.equal(MoveTypes.Fingerprint(a))
		end)

		-- The assertion that keeps dirty-tracking from being permanently stuck on: these four are
		-- re-stamped server-side on EVERY round trip (MoveEditorSystem.stampTrustedMetadata).
		it("ignores MoveId, Author, CreatedAt and UpdatedAt", function()
			local move = makeRichMove()
			local before = MoveTypes.Fingerprint(move)
			move.MoveId = "totally-different-id"
			move.Author = "SomeoneElse"
			move.CreatedAt = 999999
			move.UpdatedAt = 123456789
			expect(MoveTypes.Fingerprint(move)).to.equal(before)
		end)

		it("changes when an authored scalar changes", function()
			local move = makeRichMove()
			local before = MoveTypes.Fingerprint(move)
			move.Damage += 1
			expect(MoveTypes.Fingerprint(move)).never.to.equal(before)
		end)

		it("changes when the offset translation changes", function()
			local move = makeRichMove()
			local before = MoveTypes.Fingerprint(move)
			move.Offset = CFrame.new(0, 0, -4)
			expect(MoveTypes.Fingerprint(move)).never.to.equal(before)
		end)

		it("changes when OffsetRotation changes", function()
			local move = makeRichMove()
			local before = MoveTypes.Fingerprint(move)
			move.OffsetRotation = Vector3.new(0, 45, 0)
			expect(MoveTypes.Fingerprint(move)).never.to.equal(before)
		end)

		it("changes when a clip is added, and when clip order changes", function()
			local move = makeRichMove()
			local before = MoveTypes.Fingerprint(move)
			table.insert(move.Animations, { AnimationId = "rbxassetid://3", StartSeconds = 0.5, Speed = 1, Weight = 1 })
			local added = MoveTypes.Fingerprint(move)
			expect(added).never.to.equal(before)

			local swapped = MoveTypes.Clone(move)
			swapped.Animations[1], swapped.Animations[2] = swapped.Animations[2], swapped.Animations[1]
			expect(MoveTypes.Fingerprint(swapped)).never.to.equal(added)
		end)

		it("changes when an optional sub-table is removed", function()
			local move = makeRichMove()
			local before = MoveTypes.Fingerprint(move)
			move.Knockback = nil
			expect(MoveTypes.Fingerprint(move)).never.to.equal(before)
		end)

		it("changes when a nested ObjectStun follow-up field changes", function()
			local move = makeRichMove()
			local before = MoveTypes.Fingerprint(move);
			((move.ObjectStun :: any).FollowUp :: any).Damage = 42
			expect(MoveTypes.Fingerprint(move)).never.to.equal(before)
		end)
	end)
end
