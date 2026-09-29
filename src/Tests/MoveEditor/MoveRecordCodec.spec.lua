--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local MoveRecordCodec = require(ServerScriptService.Server.Systems.Support.MoveRecordCodec)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

-- The codec is where a stored move becomes a move again, so it carries two promises: a record written
-- today reads back as exactly the move that was saved, and a record written BEFORE the 2026-09-29
-- rebuild still loads -- as the same hit it always was, minus only the fields nothing ever ran.

local ROSTER = WeaponFixture.Install()

-- The identity fields every stored custom record carries.
local function legacyRecord(fields: { [string]: any }): { [string]: any }
	local record: { [string]: any } = {
		SchemaVersion = 2,
		MoveId = "legacy-move",
		DisplayName = "Legacy",
		Description = "",
		Category = "",
		Author = "OldAdmin",
		CreatedAt = 10,
		UpdatedAt = 20,
		OffsetX = 0,
		OffsetY = 0,
		OffsetZ = -3,
		WindupSeconds = 0.3,
		ActiveSeconds = 0.2,
		RecoverySeconds = 0.3,
		Cooldown = 0.8,
		Damage = 12,
		PostureDamage = 9,
		AnimationId = "",
	}
	for key, value in pairs(fields) do
		record[key] = value
	end
	return record
end

local function load(raw: unknown): (MoveTypes.MoveDefinition, { string })
	local candidate, dropped = MoveRecordCodec.Decode(raw)
	assert(candidate, "decode returned nothing")
	local validated, reason = MoveRegistryManager.Validate(candidate)
	if not validated then
		error(`legacy record rejected: {tostring(reason)}`)
	end
	return validated, dropped
end

return function()
	describe("MoveRecordCodec -- current records", function()
		it("reads back exactly the move that was saved", function()
			local original = MoveRegistryManager.Validate({
				MoveId = "saved-move",
				DisplayName = "Saved",
				Author = "Spec",
				CreatedAt = 1,
				UpdatedAt = 2,
				Shape = "Capsule",
				Dimensions = { Radius = 1.5, Length = 4 },
				OffsetX = 0.5,
				OffsetY = 0,
				OffsetZ = -2,
				OffsetYaw = 20,
				AttachmentPart = "RightHand",
				WindupSeconds = 0.25,
				ActiveSeconds = 0.1,
				RecoverySeconds = 0.3,
				Cooldown = 2,
				Damage = 14,
				PostureDamage = 10,
				Knockback = { UpVelocity = 5, HorizontalVelocity = 30, StartsAirCombo = true },
				Art = { TreeId = "common_foundation", Node = 2, QiCost = 15, RequiredTier = 2, Prerequisite = "x" },
			}) :: MoveTypes.MoveDefinition
			local record = MoveRecordCodec.Encode(original)
			expect(record.SchemaVersion).to.equal(Constants.MoveEditor.SchemaVersion)
			local loaded, dropped = load(record)
			expect(#dropped).to.equal(0)
			expect(MoveTypes.Fingerprint(loaded)).to.equal(MoveTypes.Fingerprint(original))
			expect(loaded.Author).to.equal("Spec")
			expect(loaded.CreatedAt).to.equal(1)
		end)

		it("returns nothing for a record that is not even a table", function()
			expect(MoveRecordCodec.Decode("corrupt")).to.equal(nil)
		end)
	end)

	describe("MoveRecordCodec -- upgrading v1/v2 records", function()
		it("maps the old Box's Depth onto the engine's Length", function()
			local loaded = load(legacyRecord({
				Shape = "Box",
				Dimensions = {
					Width = 3,
					Height = 4,
					Depth = 7,
					Length = 99,
					Thickness = 1,
					Radius = 2,
					InnerRadius = 0,
					AngleDegrees = 90,
				},
			}))
			expect(loaded.Shape).to.equal("Box")
			expect(loaded.Dimensions.Width).to.equal(3)
			expect(loaded.Dimensions.Length).to.equal(7)
		end)

		it("rebuilds a v1 record's geometry from Size and Radius", function()
			local box = load(legacyRecord({ SchemaVersion = 1, Shape = "Box", Size = { X = 2, Y = 3, Z = 5 } }))
			expect(box.Dimensions.Length).to.equal(5)
			local sphere = load(legacyRecord({ SchemaVersion = 1, Shape = "Sphere", Radius = 3.5 }))
			expect(sphere.Shape).to.equal("Sphere")
			expect(sphere.Dimensions.Radius).to.equal(3.5)
		end)

		it("turns the five retired shapes into the volume they were already swinging", function()
			local disc = load(legacyRecord({ Shape = "Disc", Dimensions = { Radius = 4, Thickness = 1.5 } }))
			expect(disc.Shape).to.equal("Cylinder")
			expect(disc.Dimensions.Radius).to.equal(4)
			expect(disc.Dimensions.Length).to.equal(1.5)

			local blade = load(
				legacyRecord({ Shape = "Blade", Dimensions = { Width = 1, Thickness = 2, Height = 3, Length = 6 } })
			)
			expect(blade.Shape).to.equal("Box")
			expect(blade.Dimensions.Width).to.equal(2)
			expect(blade.Dimensions.Length).to.equal(6)

			local slice =
				load(legacyRecord({ Shape = "Slice", Dimensions = { Width = 5, Height = 2, Thickness = 0.5 } }))
			expect(slice.Shape).to.equal("Box")
			expect(slice.Dimensions.Length).to.equal(0.5)

			for _, shape in { "Wedge", "Pyramid" } do
				expect(
					load(legacyRecord({ Shape = shape, Dimensions = { Width = 2, Height = 2, Depth = 2, Length = 2 } })).Shape
				).to.equal("Box")
			end
		end)

		it("keeps the authored rotation under its new names", function()
			local loaded = load(legacyRecord({
				Shape = "Box",
				Dimensions = { Width = 2, Height = 2, Depth = 2 },
				OffsetRotationX = 10,
				OffsetRotationY = 45,
				OffsetRotationZ = -5,
			}))
			expect(loaded.OffsetRotation).to.equal(Vector3.new(10, 45, -5))
		end)

		it("keeps a timeline-only move's clip", function()
			local loaded = load(legacyRecord({
				Shape = "Box",
				Dimensions = { Width = 2, Height = 2, Depth = 2 },
				AnimationId = "",
				Animations = {
					{ AnimationId = "rbxassetid://111", Enabled = false },
					{ AnimationId = "rbxassetid://222", Enabled = true },
				},
			}))
			expect(loaded.AnimationId).to.equal("rbxassetid://222")
		end)

		it("keeps knockback's velocities and launcher flag, and reports every field it dropped", function()
			local loaded, dropped = load(legacyRecord({
				Shape = "Box",
				Dimensions = { Width = 2, Height = 2, Depth = 2 },
				ArcDegrees = 100,
				Movement = { LungeDistanceStuds = 5, LungeDurationSeconds = 0.2 },
				Projectile = { Speed = 60, MaxRange = 80 },
				ObjectStun = { Enabled = true },
				Knockback = { UpVelocity = 12, HorizontalVelocity = 40, RagdollSeconds = 1, StartsAirCombo = true },
			}))
			local knockback = loaded.Knockback :: MoveTypes.MoveKnockback
			expect(knockback.UpVelocity).to.equal(12)
			expect(knockback.HorizontalVelocity).to.equal(40)
			expect(knockback.StartsAirCombo).to.equal(true)
			for _, field in { "ArcDegrees", "Movement", "Projectile", "ObjectStun", "Knockback.RagdollSeconds" } do
				expect(table.find(dropped, field)).to.be.ok()
			end
		end)

		it("carries an art binding through untouched", function()
			local loaded = load(legacyRecord({
				Shape = "Box",
				Dimensions = { Width = 2, Height = 2, Depth = 2 },
				Art = { TreeId = "common_foundation", Node = 1, QiCost = 20, RequiredTier = 1 },
			}))
			expect((loaded.Art :: MoveTypes.MoveArtBinding).QiCost).to.equal(20)
		end)
	end)

	describe("MoveRecordCodec -- Default-move overrides", function()
		local moveId = `default:{ROSTER[1]}:Basic:1`

		it("lays a current override over the built move", function()
			local built = DefaultMoveRegistry.GetBuilt(moveId) :: MoveTypes.MoveDefinition
			local edited = MoveTypes.Clone(built)
			edited.Damage = 33
			local candidate = MoveRecordCodec.DecodeOverride(built, MoveRecordCodec.EncodeOverride(edited)) :: any
			expect(candidate.Damage).to.equal(33)
			expect(candidate.WindupSeconds).to.equal(built.WindupSeconds)
		end)

		it("upgrades an old override record that stored only some fields", function()
			local built = DefaultMoveRegistry.GetBuilt(moveId) :: MoveTypes.MoveDefinition
			local candidate, dropped = MoveRecordCodec.DecodeOverride(built, {
				SchemaVersion = 2,
				Shape = "Box",
				Size = { X = 6, Y = 5, Z = 9 },
				WindupSeconds = 0.5,
				ArcDegrees = 110,
			})
			local applied = DefaultMoveRegistry.ApplyEdit(moveId, candidate) :: MoveTypes.MoveDefinition
			expect(applied.WindupSeconds).to.equal(0.5)
			expect(applied.Dimensions.Length).to.equal(9)
			expect(applied.Damage).to.equal(built.Damage)
			expect(table.find(dropped, "ArcDegrees")).to.be.ok()
			DefaultMoveRegistry.Reset(moveId)
		end)
	end)
end
