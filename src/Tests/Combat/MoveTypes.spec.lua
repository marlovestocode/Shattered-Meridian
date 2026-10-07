--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)
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
		it("offers exactly the engine's shapes, once each", function()
			expect(#MoveTypes.Shapes).to.equal(15)
			local seen: { [string]: boolean } = {}
			for _, shape in MoveTypes.Shapes do
				expect(HitboxTypes.IsShapeKind(shape)).to.equal(true)
				expect(seen[shape]).to.equal(nil)
				seen[shape] = true
			end
		end)

		it("accepts every shape the editor offers through the server's own gate", function()
			for _, shape in MoveTypes.Shapes do
				local validated, reason = MoveRegistryManager.Validate(wire({ Shape = shape }))
				expect(reason).to.equal(nil)
				expect((validated :: MoveTypes.MoveDefinition).Shape).to.equal(shape)
			end
		end)

		it("keeps every shape preset inside the editor's authoring limits and the shape's own fields", function()
			expect(#HitboxTypes.Presets > 0).to.equal(true)
			local ids: { [string]: boolean } = {}
			for _, preset in HitboxTypes.Presets do
				expect(ids[preset.Id]).to.equal(nil)
				ids[preset.Id] = true
				expect(HitboxTypes.IsShapeKind(preset.Shape)).to.equal(true)
				local fields = HitboxTypes.FieldsFor(preset.Shape)
				for field, value in preset.Dimensions do
					local range = Constants.MoveEditor.Limits.Dimensions[field]
					expect(range).to.be.ok()
					expect(value >= range.Min and value <= range.Max).to.equal(true)
					-- A preset sets what its shape reads and nothing else.
					expect(table.find(fields, field) ~= nil).to.equal(true)
				end
				local z = Constants.MoveEditor.Limits.OffsetStuds
				expect(preset.OffsetZ >= z.Min and preset.OffsetZ <= z.Max).to.equal(true)
				expect(HitboxTypes.PresetById(preset.Id)).to.equal(preset)
			end
			expect(HitboxTypes.PresetById("nope")).to.equal(nil)
		end)

		it("keeps a preset's InnerRadius at or below its Radius", function()
			for _, preset in HitboxTypes.Presets do
				local inner, radius = preset.Dimensions.InnerRadius, preset.Dimensions.Radius
				if inner ~= nil and radius ~= nil then
					expect(inner <= radius).to.equal(true)
				end
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

	describe("LocksWindup", function()
		it("is off by default and survives Validate, ToWire, Clone and the engine projection", function()
			expect(move().LocksWindup).to.equal(false)
			local locked = move({ LocksWindup = true, LocksMovement = false })
			expect(locked.LocksWindup).to.equal(true)
			-- The two locks are independent.
			expect(locked.LocksMovement).to.equal(false)
			local again = MoveRegistryManager.Validate(MoveTypes.ToWire(locked)) :: MoveTypes.MoveDefinition
			expect(again.LocksWindup).to.equal(true)
			expect(MoveTypes.Clone(locked).LocksWindup).to.equal(true)
			expect(MoveTypes.ToEngineAttackDefinition(locked).LocksWindup).to.equal(true)
		end)

		it("changes the fingerprint, so an edit to it counts as an edit", function()
			expect(MoveTypes.Fingerprint(move({ LocksWindup = true })) ~= MoveTypes.Fingerprint(move())).to.equal(true)
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

		it("casts a realm move volumeless and every other move with its volume", function()
			local plain = MoveTypes.ToEngineAttackDefinition(move())
			expect(plain.Volumeless).to.equal(false)
			local realm = MoveTypes.ToEngineAttackDefinition(move({ Domain = DomainTypes.Defaults() }))
			expect(realm.Volumeless).to.equal(true)
			-- The swing around it is untouched: the same timing, the same locks.
			expect(realm.WindupSeconds).to.equal(plain.WindupSeconds)
			expect(realm.ActiveSeconds).to.equal(plain.ActiveSeconds)
			expect(realm.RecoverySeconds).to.equal(plain.RecoverySeconds)
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

	describe("MoveTypes -- the projectile move type", function()
		local function projectileWire(): { [string]: any }
			local spec = ProjectileTypes.Defaults() :: any
			spec.SpreadPattern = "Fan"
			spec.Count = 5
			spec.SpreadAngle = 30
			spec.Homing = true
			spec.ParryBehavior = "ParryAll"
			spec.ParryResponse = "Reflect"
			spec.ReflectedDamageMultiplier = 1.5
			return spec
		end

		it("is melee without the block and projectile with it", function()
			expect(MoveTypes.IsProjectile(move())).to.equal(false)
			expect(MoveTypes.IsProjectile(move({ Projectile = projectileWire() }))).to.equal(true)
		end)

		it("round-trips every projectile field through ToWire and Validate", function()
			local source = move({ Projectile = projectileWire() })
			local again = MoveRegistryManager.Validate(MoveTypes.ToWire(source) :: any) :: MoveTypes.MoveDefinition
			expect(again).to.be.ok()
			for _, field in ProjectileTypes.Fields do
				expect((again.Projectile :: any)[field.Name]).to.equal((source.Projectile :: any)[field.Name])
			end
			expect(MoveTypes.Fingerprint(again)).to.equal(MoveTypes.Fingerprint(source))
		end)

		it("clones the block rather than aliasing it", function()
			local source = move({ Projectile = projectileWire() })
			local copy = MoveTypes.Clone(source);
			(copy.Projectile :: any).Count = 9
			expect((source.Projectile :: any).Count).to.equal(5)
		end)

		it("sees a projectile edit as a change", function()
			local source = move({ Projectile = projectileWire() })
			local edited = MoveTypes.Clone(source);
			(edited.Projectile :: any).Speed += 10
			expect(MoveTypes.Fingerprint(edited)).never.to.equal(MoveTypes.Fingerprint(source))
			expect(MoveTypes.Fingerprint(move())).never.to.equal(MoveTypes.Fingerprint(source))
		end)

		it("hands the engine the block as a copy", function()
			local source = move({ Projectile = projectileWire() })
			local definition = MoveTypes.ToEngineAttackDefinition(source)
			expect(definition.Projectile).to.be.ok()
			expect((definition.Projectile :: any).Count).to.equal(5);
			(definition.Projectile :: any).Count = 1
			expect((source.Projectile :: any).Count).to.equal(5)
			-- And the engine's own sanitiser keeps it.
			local sanitized = HitboxTypes.SanitizeDefinition(MoveTypes.ToEngineAttackDefinition(source))
			expect((sanitized.Projectile :: any).SpreadPattern).to.equal("Fan")
			expect(HitboxTypes.SanitizeDefinition(MoveTypes.ToEngineAttackDefinition(move())).Projectile).to.equal(nil)
		end)
	end)
end
