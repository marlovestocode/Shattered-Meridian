--!strict
-- Covers MoveEditorSystem.ScaleMove -- the pure core of the Move Editor's bulk edit. The remote around it
-- (MoveEditor_BulkScale) is admin-gated and DataStore-backed, which this harness cannot stand up.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local MoveEditorSystem = require(ServerScriptService.Server.Systems.MoveEditorSystem)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local LIMITS = Constants.MoveEditor.BulkScaleLimits

local function move(): MoveTypes.MoveDefinition
	return MoveRegistryManager.Validate({
		MoveId = "bulk-spec",
		DisplayName = "Bulk Spec",
		Author = "Spec",
		CreatedAt = 1,
		UpdatedAt = 1,
		Shape = "Box",
		Dimensions = { Width = 4, Height = 5, Length = 5 },
		OffsetX = 0,
		OffsetY = 0,
		OffsetZ = -3,
		WindupSeconds = 0.3,
		ActiveSeconds = 0.2,
		RecoverySeconds = 0.4,
		Cooldown = 1,
		Damage = 10,
		PostureDamage = 8,
	}) :: MoveTypes.MoveDefinition
end

return function()
	describe("MoveEditorSystem.ScaleMove", function()
		it("multiplies exactly the fields it is given and leaves the rest as they were", function()
			local source = move()
			local wire = MoveEditorSystem.ScaleMove(source, { WindupSeconds = 1.1, Damage = 0.95 })
			expect(wire.WindupSeconds).to.be.near(0.33, 1e-9)
			expect(wire.Damage).to.be.near(9.5, 1e-9)
			expect(wire.ActiveSeconds).to.equal(source.ActiveSeconds)
			expect(wire.RecoverySeconds).to.equal(source.RecoverySeconds)
			expect(wire.Cooldown).to.equal(source.Cooldown)
			expect(wire.PostureDamage).to.equal(source.PostureDamage)
			-- And nothing outside the scalable set rides along changed.
			expect(wire.Dimensions.Width).to.equal(4)
			expect(wire.OffsetZ).to.equal(-3)
		end)

		it("clamps a multiplier to the bulk limits", function()
			local source = move()
			local wire = MoveEditorSystem.ScaleMove(source, { Damage = 100, PostureDamage = 0.01 })
			expect(wire.Damage).to.be.near(source.Damage * LIMITS.Max, 1e-9)
			expect(wire.PostureDamage).to.be.near(source.PostureDamage * LIMITS.Min, 1e-9)
		end)

		it("ignores a factor that is not a number", function()
			local source = move()
			local wire = MoveEditorSystem.ScaleMove(source, { Damage = 0 / 0, Cooldown = "twice" :: any })
			expect(wire.Damage).to.equal(source.Damage)
			expect(wire.Cooldown).to.equal(source.Cooldown)
		end)

		it("produces a draft the validator accepts, clamping a product past the authorable bound", function()
			local source = move()
			local wire = MoveEditorSystem.ScaleMove(source, { RecoverySeconds = 4, Damage = 4 })
			wire.Author, wire.CreatedAt, wire.UpdatedAt = source.Author, source.CreatedAt, source.UpdatedAt
			local validated = MoveRegistryManager.Validate(wire)
			expect(validated).to.be.ok()
			expect((validated :: any).RecoverySeconds).to.be.near(1.6, 1e-9)
			expect((validated :: any).Damage <= Constants.MoveEditor.Limits.Damage.Max).to.equal(true)
		end)
	end)
end
