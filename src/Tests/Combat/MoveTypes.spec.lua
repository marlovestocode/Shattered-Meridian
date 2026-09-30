--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)

-- The schema module's own contract: the vocabulary is the engine's, the wire encoding round-trips
-- through Validate, Clone never aliases, Fingerprint sees exactly the authored fields, and the engine
-- projection is a copy rather than an approximation.

local function wire(overrides: { [string]: any }?): { [string]: any }
	local candidate: { [string]: any } = {
		MoveId = "spec-move",
		DisplayName = "Spec Move",
		Description = "",
		Category = "",
		Author = "Spec",
		CreatedAt = 1,
		UpdatedAt = 2,
		Shape = "Box",
		Dimensions = { Width = 4, Height = 5, Length = 6, Radius = 2, InnerRadius = 0, AngleDegrees = 90 },
		OffsetX = 0,
		OffsetY = 0.5,
		OffsetZ = -3,
		WindupSeconds = 0.3,
		ActiveSeconds = 0.15,
		RecoverySeconds = 0.35,
		Cooldown = 0.8,
		Damage = 10,
		PostureDamage = 8,
		AnimationId = "",
	}
	for key, value in pairs(overrides or {}) do
		candidate[key] = value
	end
	return candidate
end

local function move(overrides: { [string]: any }?): MoveTypes.MoveDefinition
	local validated, reason = MoveRegistryManager.Validate(wire(overrides))
	if not validated then
		error(`fixture rejected: {tostring(reason)}`)
	end
	return validated
end

return function()
	describe("MoveTypes vocabulary", function()
		it("offers exactly the engine's seven shapes", function()
			expect(#MoveTypes.Shapes).to.equal(7)
			for _, shape in MoveTypes.Shapes do
				expect(HitboxTypes.IsShapeKind(shape)).to.equal(true)
			end
		end)

		it("offers the engine's four anchors", function()
			expect(#MoveTypes.AttachmentPoints).to.equal(4)
			for _, point in MoveTypes.AttachmentPoints do
				local definition = HitboxTypes.SanitizeDefinition({ Shape = "Box", AttachmentPart = point })
				expect(definition.AttachmentPart).to.equal(point)
			end
		end)
	end)

	describe("MoveTypes weight class and feintability", function()
		it("defaults a move that authors neither to class 1, not feintable", function()
			local plain = move()
			expect(MoveTypes.PowerLevelOf(plain)).to.equal(MoveTypes.DefaultPowerLevel)
			expect(MoveTypes.IsFeintable(plain)).to.equal(false)
		end)

		it("clamps PowerLevel into its limits when read", function()
			expect(MoveTypes.PowerLevelOf({ PowerLevel = 99 })).to.equal(MoveTypes.PowerLevelLimits.Max)
			expect(MoveTypes.PowerLevelOf({ PowerLevel = 0 / 0 })).to.equal(MoveTypes.DefaultPowerLevel)
		end)

		it("weighs a weapon string by stage: Heavy and Finisher above Basic; Basic and Heavy feintable", function()
			expect(MoveTypes.PowerLevelByStage.Heavy > MoveTypes.PowerLevelByStage.Basic).to.equal(true)
			expect(MoveTypes.PowerLevelByStage.Finisher > MoveTypes.PowerLevelByStage.Basic).to.equal(true)
			expect(MoveTypes.FeintableByStage.Basic).to.equal(true)
			expect(MoveTypes.FeintableByStage.Heavy).to.equal(true)
			expect(MoveTypes.FeintableByStage.Finisher).to.equal(false)
		end)
	end)

	describe("MoveTypes.ToWire", function()
		it("round-trips through Validate to the same authored move", function()
			local original = move({
				OffsetYaw = 30,
				OffsetPitch = -10,
				Knockback = { UpVelocity = 10, HorizontalVelocity = 40, StartsAirCombo = true },
				Grab = {
					HoldSeconds = 2,
					ThrowUpVelocity = 20,
					ThrowHorizontalVelocity = 30,
					ThrowImpactDamage = 5,
					ThrowSelfDamage = 5,
				},
				Art = { TreeId = "common_foundation", Node = 1, QiCost = 10, RequiredTier = 1 },
				PowerLevel = 3,
				Feintable = true,
				MaxTargets = 2,
				AttachmentPart = "RightHand",
				LocksMovement = true,
			})
			local stamped = MoveTypes.ToWire(original)
			stamped.Author = original.Author
			stamped.CreatedAt = original.CreatedAt
			stamped.UpdatedAt = original.UpdatedAt
			local again = MoveRegistryManager.Validate(stamped)
			expect(again).to.be.ok()
			expect(MoveTypes.Fingerprint(again :: any)).to.equal(MoveTypes.Fingerprint(original))
		end)

		it("never carries a CFrame, a projected field or the grab's attach offset", function()
			local source = move({
				Grab = {
					HoldSeconds = 2,
					ThrowUpVelocity = 20,
					ThrowHorizontalVelocity = 30,
					ThrowImpactDamage = 5,
					ThrowSelfDamage = 5,
				},
			})
			source.WeaponSpeed = 1.5
			local encoded = MoveTypes.ToWire(source)
			for _, value in pairs(encoded) do
				expect(typeof(value) == "CFrame" or typeof(value) == "Vector3").to.equal(false)
			end
			expect(encoded.WeaponSpeed).to.equal(nil)
			expect(encoded.Grab.AttachOffset).to.equal(nil)
		end)
	end)

	describe("MoveTypes.ComposeOffset", function()
		it("keeps the translation and applies yaw, then pitch, then roll", function()
			local composed = MoveTypes.ComposeOffset(Vector3.new(1, 2, -3), Vector3.new(10, 20, 30))
			local expected = CFrame.new(1, 2, -3) * CFrame.fromEulerAnglesYXZ(math.rad(10), math.rad(20), math.rad(30))
			expect((composed.Position - expected.Position).Magnitude).to.be.near(0, 1e-6)
			expect(composed.LookVector:Dot(expected.LookVector)).to.be.near(1, 1e-6)
		end)
	end)

	describe("MoveTypes.Clone", function()
		it("preserves every authored field", function()
			local source = move({ Knockback = { UpVelocity = 5, HorizontalVelocity = 6 }, MaxTargets = 3 })
			local copy = MoveTypes.Clone(source)
			expect(MoveTypes.Fingerprint(copy)).to.equal(MoveTypes.Fingerprint(source))
			expect(copy.MoveId).to.equal(source.MoveId)
			expect(copy.Author).to.equal(source.Author)
		end)

		it("does not alias Dimensions, Knockback, Grab or Art", function()
			local source = move({
				Knockback = { UpVelocity = 5, HorizontalVelocity = 6 },
				Grab = {
					HoldSeconds = 2,
					ThrowUpVelocity = 20,
					ThrowHorizontalVelocity = 30,
					ThrowImpactDamage = 5,
					ThrowSelfDamage = 5,
				},
				Art = { TreeId = "common_foundation", Node = 1, QiCost = 10, RequiredTier = 1 },
			})
			local copy = MoveTypes.Clone(source)
			copy.Dimensions.Width = 99
			(copy.Knockback :: any).UpVelocity = 99
			(copy.Grab :: any).HoldSeconds = 9
			(copy.Art :: any).QiCost = 50
			expect(source.Dimensions.Width).to.equal(4)
			expect((source.Knockback :: any).UpVelocity).to.equal(5)
			expect((source.Grab :: any).HoldSeconds).to.equal(2)
			expect((source.Art :: any).QiCost).to.equal(10)
		end)
	end)

	describe("MoveTypes.Fingerprint", function()
		it("is stable and matches two independently built identical moves", function()
			expect(MoveTypes.Fingerprint(move())).to.equal(MoveTypes.Fingerprint(move()))
		end)

		it("ignores identity stamps and projected fields", function()
			local a = move()
			local b = move({ MoveId = "other-id", Author = "Someone", CreatedAt = 50, UpdatedAt = 60 })
			b.WeaponSpeed = 2
			b.Tempo = 0.5
			expect(MoveTypes.Fingerprint(a)).to.equal(MoveTypes.Fingerprint(b))
		end)

		it("changes when any authored field changes", function()
			local base = MoveTypes.Fingerprint(move())
			local variants: { { [string]: any } } = {
				{ Damage = 11 },
				{ Description = "the punish" },
				{ OffsetZ = -4 },
				{ OffsetYaw = 15 },
				{ Shape = "Sphere" },
				{ AttachmentPart = "Weapon" },
				{ LocksMovement = true },
				{ AnimationId = "rbxassetid://1" },
				{ Knockback = { UpVelocity = 1, HorizontalVelocity = 1 } },
				{ Art = { TreeId = "common_foundation", Node = 1, QiCost = 10, RequiredTier = 1 } },
			}
			for _, variant in variants do
				expect(MoveTypes.Fingerprint(move(variant)) ~= base).to.equal(true)
			end
		end)
	end)

	describe("MoveTypes.ToEngineAttackDefinition", function()
		it("copies the geometry, timing and anchor straight onto the engine definition", function()
			local source = move({ Shape = "Cone", MaxTargets = 2, AttachmentPart = "LeftHand", LocksMovement = true })
			local definition, profile = MoveTypes.ToEngineAttackDefinition(source)
			expect(definition.DebugName).to.equal(source.MoveId)
			expect(definition.Shape).to.equal("Cone")
			expect(definition.BaseDimensions.Length).to.equal(source.Dimensions.Length)
			expect(definition.BaseDimensions.AngleDegrees).to.equal(source.Dimensions.AngleDegrees)
			expect(definition.Offset).to.equal(source.Offset)
			expect(definition.AttachmentPart).to.equal("LeftHand")
			expect(definition.WindupSeconds).to.equal(source.WindupSeconds)
			expect(definition.MaxTargetsPerSwing).to.equal(2)
			expect(definition.LocksMovement).to.equal(true)
			expect(definition.SizeFromAttachmentPart).to.equal(false)
			expect(profile.Damage).to.equal(source.Damage)
			expect(profile.PostureDamage).to.equal(source.PostureDamage)
		end)

		it("survives the engine's own sanitiser with nothing to correct", function()
			local definition = MoveTypes.ToEngineAttackDefinition(move({ Shape = "Arc" }))
			local _, problems = HitboxTypes.SanitizeDefinition(definition)
			expect(#problems).to.equal(0)
		end)

		it("sizes a weapon-anchored swing off the blade", function()
			local definition = MoveTypes.ToEngineAttackDefinition(move({ AttachmentPart = "Weapon" }))
			expect(definition.SizeFromAttachmentPart).to.equal(true)
		end)

		it("hands the damage layer the knockback and grab it authored", function()
			local source = move({
				Knockback = { UpVelocity = 5, HorizontalVelocity = 6, StartsAirCombo = true },
				Grab = {
					HoldSeconds = 2,
					ThrowUpVelocity = 20,
					ThrowHorizontalVelocity = 30,
					ThrowImpactDamage = 5,
					ThrowSelfDamage = 5,
				},
			})
			local _, profile = MoveTypes.ToEngineAttackDefinition(source)
			expect((profile.Knockback :: any).StartsAirCombo).to.equal(true)
			expect((profile.Grab :: any).HoldSeconds).to.equal(2)
		end)

		it("does not alias the move's dimensions into the engine definition", function()
			local source = move()
			local definition = MoveTypes.ToEngineAttackDefinition(source)
			definition.BaseDimensions.Width = 99
			expect(source.Dimensions.Width).to.equal(4)
		end)
	end)
end
