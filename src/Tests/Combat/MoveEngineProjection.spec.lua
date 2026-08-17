--!strict
-- Covers MoveTypes.ToEngineAttackDefinition -- the projection from the Move Creation System's authored
-- schema onto the rebuilt HitboxEngine's.
--
-- Pure, so no rig and no registry: a MoveDefinition in, an AttackDefinition and a DamageProfile out.
-- Kept out of MoveTypes.spec.lua deliberately -- that file covers the LEGACY projection onto the
-- deleted combat system's schema, and the two answer different questions about the same input.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxShapes = require(ReplicatedStorage.Shared.HitboxShapes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local function makeMove(overrides: { [string]: any }?): MoveTypes.MoveDefinition
	local base: { [string]: any } = {
		MoveId = "spec-move",
		DisplayName = "Spec Move",
		Category = "Spec",
		Author = "Spec",
		CreatedAt = 0,
		UpdatedAt = 0,
		Shape = "Box",
		Dimensions = HitboxShapes.DefaultDimensions("Box"),
		Size = nil,
		Radius = nil,
		Offset = CFrame.new(0, 1, -3),
		OffsetRotation = Vector3.zero,
		WindupSeconds = 0.2,
		ActiveSeconds = 0.3,
		RecoverySeconds = 0.1,
		Cooldown = 0.5,
		Damage = 11,
		PostureDamage = 13,
		ArcDegrees = nil,
		MaxTargets = 2,
		AnimationId = "",
		Animations = {},
		Movement = nil,
		Knockback = nil,
		Projectile = nil,
		ObjectStun = nil,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return base :: any
end

-- Builds a full authored Dimensions bag with the named fields overridden, so a case can state only
-- the measurements its shape actually reads.
local function dimensions(shape: string, values: { [string]: number }): MoveTypes.MoveDimensions
	local base = HitboxShapes.DefaultDimensions(shape)
	for key, value in values do
		(base :: any)[key] = value
	end
	return base
end

return function()
	describe("ToEngineAttackDefinition -- identity and timing", function()
		it("names the definition by MoveId so the damage layer can look it back up", function()
			local definition = MoveTypes.ToEngineAttackDefinition(makeMove())
			expect(definition.DebugName).to.equal("spec-move")
		end)

		it("carries timing across unchanged", function()
			local definition = MoveTypes.ToEngineAttackDefinition(makeMove())
			expect(definition.WindupSeconds).to.equal(0.2)
			expect(definition.ActiveSeconds).to.equal(0.3)
			expect(definition.RecoverySeconds).to.equal(0.1)
			expect(definition.MaxTargetsPerSwing).to.equal(2)
		end)

		it("separates damage from geometry", function()
			-- The whole reason there are two return values: HitboxTypes.AttackDefinition deliberately
			-- carries no damage field, so an engine that never learns what a hit is worth stays
			-- domain-agnostic.
			local _, profile = MoveTypes.ToEngineAttackDefinition(makeMove())
			expect(profile.Damage).to.equal(11)
			expect(profile.PostureDamage).to.equal(13)
		end)

		it("defaults to a flat scaling profile, since nothing authors a growth curve yet", function()
			local definition = MoveTypes.ToEngineAttackDefinition(makeMove())
			expect(#definition.Scaling.ComboStageMultipliers).to.equal(1)
			expect(definition.Scaling.ComboStageMultipliers[1]).to.equal(1)
			expect(definition.Scaling.ChargeSeconds).to.equal(0)
		end)

		it("never grants a movement lock the author did not ask for", function()
			local definition = MoveTypes.ToEngineAttackDefinition(makeMove())
			expect(definition.LocksMovement).to.equal(false)
			expect(definition.AttachmentPart).to.equal("Root")
		end)
	end)

	describe("ToEngineAttackDefinition -- shapes that map exactly", function()
		it("renames a box's Depth to the engine's Length", function()
			-- THE ONE GENUINE VOCABULARY CLASH. HitboxShapes calls a box's forward extent Depth and
			-- ALSO has a separate Length (a reach measurement), so the two schemas disagree about a
			-- field name rather than merely spelling one differently. A generic table copy would put
			-- the wrong number in the wrong axis and produce a box the wrong way round.
			local move =
				makeMove({ Shape = "Box", Dimensions = dimensions("Box", { Width = 5, Height = 6, Depth = 7 }) })
			local definition = MoveTypes.ToEngineAttackDefinition(move)
			expect(definition.Shape).to.equal("Box")
			expect(definition.BaseDimensions.Width).to.equal(5)
			expect(definition.BaseDimensions.Height).to.equal(6)
			expect(definition.BaseDimensions.Length).to.equal(7)
		end)

		it("carries an arc's four measurements across", function()
			local move = makeMove({
				Shape = "Arc",
				Dimensions = dimensions("Arc", { Radius = 9, InnerRadius = 2, Height = 5, AngleDegrees = 120 }),
			})
			local definition = MoveTypes.ToEngineAttackDefinition(move)
			expect(definition.Shape).to.equal("Arc")
			expect(definition.BaseDimensions.Radius).to.equal(9)
			expect(definition.BaseDimensions.InnerRadius).to.equal(2)
			expect(definition.BaseDimensions.AngleDegrees).to.equal(120)
		end)

		it("maps every shape the engine shares by name onto itself", function()
			for _, shape in { "Box", "Sphere", "Cone", "Arc", "Beam", "Cylinder", "Capsule" } do
				local definition = MoveTypes.ToEngineAttackDefinition(makeMove({
					Shape = shape,
					Dimensions = HitboxShapes.DefaultDimensions(shape),
				}))
				expect(definition.Shape).to.equal(shape)
			end
		end)

		it("reports no corrections for a shape the engine understands", function()
			local _, _, notes = MoveTypes.ToEngineAttackDefinition(makeMove({ Shape = "Sphere" }))
			expect(#notes).to.equal(0)
		end)
	end)

	describe("ToEngineAttackDefinition -- shapes the engine dropped", function()
		it("turns a disc into the thin cylinder it actually is", function()
			-- Not a Box fallback: a disc IS a thin cylinder, so radius and thickness carry across with
			-- no reinterpretation. Falling back to Box would turn a round shockwave square, which is a
			-- silent gameplay change rather than an approximation.
			local move = makeMove({
				Shape = "Disc",
				Dimensions = dimensions("Disc", { Radius = 6, Thickness = 0.4 }),
			})
			local definition, _, notes = MoveTypes.ToEngineAttackDefinition(move)
			expect(definition.Shape).to.equal("Cylinder")
			expect(definition.BaseDimensions.Radius).to.equal(6)
			expect(definition.BaseDimensions.Length).to.equal(0.4)
			expect(#notes > 0).to.equal(true)
		end)

		it("falls back to a bounding box for the shapes with no honest analogue", function()
			for _, shape in { "Wedge", "Blade", "Slice", "Pyramid" } do
				local definition, _, notes = MoveTypes.ToEngineAttackDefinition(makeMove({
					Shape = shape,
					Dimensions = HitboxShapes.DefaultDimensions(shape),
				}))
				expect(definition.Shape).to.equal("Box")
				-- Reported, never silent: an author who picked one of these is entitled to know.
				expect(#notes > 0).to.equal(true)
			end
		end)

		it("keeps a slice's thickness as its forward extent rather than losing it", function()
			local move = makeMove({
				Shape = "Slice",
				Dimensions = dimensions("Slice", { Width = 10, Height = 8, Thickness = 0.08 }),
			})
			local definition = MoveTypes.ToEngineAttackDefinition(move)
			expect(definition.BaseDimensions.Width).to.equal(10)
			expect(definition.BaseDimensions.Height).to.equal(8)
			expect(definition.BaseDimensions.Length).to.equal(0.08)
		end)
	end)

	describe("ToEngineAttackDefinition -- authored fields with nowhere to go", function()
		it("reports a projectile rather than silently throwing it as melee", function()
			local move = makeMove({ Projectile = { Speed = 80, MaxRange = 120 } })
			local _, _, notes = MoveTypes.ToEngineAttackDefinition(move)
			expect(#notes).to.equal(1)
			expect(string.find(notes[1], "Projectile") ~= nil).to.equal(true)
		end)

		it("reports an authored facing arc, which the engine no longer gates on", function()
			-- The old system gated a hit on the attacker's facing arc IN ADDITION to the hitbox. The
			-- engine tests containment only, so a move relying on the arc to avoid hitting behind the
			-- attacker now can.
			local _, _, notes = MoveTypes.ToEngineAttackDefinition(makeMove({ ArcDegrees = 100 }))
			expect(#notes).to.equal(1)
			expect(string.find(notes[1], "ArcDegrees") ~= nil).to.equal(true)
		end)

		it("reports each dropped subsystem separately", function()
			local move = makeMove({
				Projectile = { Speed = 80, MaxRange = 120 },
				Movement = { LungeDistanceStuds = 5, LungeDurationSeconds = 0.2 },
				ArcDegrees = 90,
			})
			local _, _, notes = MoveTypes.ToEngineAttackDefinition(move)
			expect(#notes).to.equal(3)
		end)
	end)
end
