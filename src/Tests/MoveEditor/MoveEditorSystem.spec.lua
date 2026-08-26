--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local MoveEditorSystem = require(ServerScriptService.Server.Systems.MoveEditorSystem)

-- EncodeMoveRecord/CandidateFromStoredRecord never touch a live remote, a DataStore, or a Player --
-- MoveEditorSystem.Init() is never called in this spec file, the same "requiring the module never
-- calls Init()" contract every other System's own spec relies on.
--
-- This file exists because encodeMoveRecord silently omitted Art and Grab entirely (both validated
-- fine and worked immediately in the live in-memory registry, so an admin's edit LOOKED saved right
-- up until the next server restart re-loaded moves from a DataStore record that never had them) --
-- there was no test anywhere that would have caught a MoveDefinition field missing from the record
-- an encode function actually writes. Every optional MoveDefinition field with real content
-- (Art/Grab today; Movement/Knockback/Projectile/ObjectStun already covered elsewhere) should have a
-- round-trip case here.

local function baseMove(overrides: { [string]: any }?): { [string]: any }
	local move: { [string]: any } = {
		MoveId = "test_move",
		DisplayName = "Test Move",
		Category = "",
		Author = "TestAuthor",
		CreatedAt = 0,
		UpdatedAt = 0,
		Shape = "Box",
		Dimensions = {
			Width = 4,
			Height = 4,
			Depth = 4,
			Length = 0,
			Thickness = 0,
			Radius = 0,
			InnerRadius = 0,
			AngleDegrees = 0,
		},
		Size = Vector3.new(4, 4, 4),
		Radius = nil,
		Offset = CFrame.new(0, 0, -3),
		OffsetRotation = Vector3.new(0, 0, 0),
		WindupSeconds = 0.2,
		ActiveSeconds = 0.15,
		RecoverySeconds = 0.3,
		Cooldown = 0.6,
		Damage = 5,
		PostureDamage = 5,
		ArcDegrees = 100,
		MaxTargets = 5,
		AnimationId = "",
		Animations = {},
	}
	if overrides then
		for key, value in pairs(overrides) do
			move[key] = value
		end
	end
	return move
end

return function()
	describe("MoveEditorSystem.EncodeMoveRecord -- Art", function()
		it("writes every Art field into the record", function()
			local move = baseMove({
				Art = { TreeId = "celestial", Node = 2, QiCost = 15, RequiredTier = 3, Prerequisite = "other" },
			})
			local record = MoveEditorSystem.EncodeMoveRecord(move :: any)

			expect(record.Art).never.to.equal(nil)
			expect(record.Art.TreeId).to.equal("celestial")
			expect(record.Art.Node).to.equal(2)
			expect(record.Art.QiCost).to.equal(15)
			expect(record.Art.RequiredTier).to.equal(3)
			expect(record.Art.Prerequisite).to.equal("other")
		end)

		it("omits Art from the record for a move that isn't an art", function()
			local record = MoveEditorSystem.EncodeMoveRecord(baseMove() :: any)
			expect(record.Art).to.equal(nil)
		end)

		it("round-trips every Art field back out through CandidateFromStoredRecord", function()
			local move = baseMove({ Art = { TreeId = "demonic", Node = 1, QiCost = 20, RequiredTier = 1 } })
			local record = MoveEditorSystem.EncodeMoveRecord(move :: any)
			local candidate = MoveEditorSystem.CandidateFromStoredRecord(record) :: any

			expect(candidate).never.to.equal(nil)
			expect(candidate.Art.TreeId).to.equal("demonic")
			expect(candidate.Art.Node).to.equal(1)
			expect(candidate.Art.QiCost).to.equal(20)
			expect(candidate.Art.RequiredTier).to.equal(1)
		end)
	end)

	describe("MoveEditorSystem.EncodeMoveRecord -- Grab", function()
		local function grabConfig(): { [string]: any }
			return {
				AttachOffset = CFrame.new(),
				HoldSeconds = 4,
				ThrowUpVelocity = 20,
				ThrowHorizontalVelocity = 30,
				ThrowImpactDamage = 10,
				ThrowSelfDamage = 5,
			}
		end

		it("writes every mutable Grab field into the record, excluding AttachOffset", function()
			local move = baseMove({ Grab = grabConfig() })
			local record = MoveEditorSystem.EncodeMoveRecord(move :: any)

			expect(record.Grab).never.to.equal(nil)
			expect(record.Grab.HoldSeconds).to.equal(4)
			expect(record.Grab.ThrowUpVelocity).to.equal(20)
			expect(record.Grab.ThrowHorizontalVelocity).to.equal(30)
			expect(record.Grab.ThrowImpactDamage).to.equal(10)
			expect(record.Grab.ThrowSelfDamage).to.equal(5)
			-- AttachOffset is never author-edited (validateGrab always re-derives it from
			-- GrabConstants.Defaults.AttachOffset) -- it belongs out of the persisted record.
			expect(record.Grab.AttachOffset).to.equal(nil)
		end)

		it("omits Grab from the record for a move with no Grab config", function()
			local record = MoveEditorSystem.EncodeMoveRecord(baseMove() :: any)
			expect(record.Grab).to.equal(nil)
		end)

		it("round-trips every mutable Grab field back out through CandidateFromStoredRecord", function()
			local move = baseMove({ Grab = grabConfig() })
			local record = MoveEditorSystem.EncodeMoveRecord(move :: any)
			local candidate = MoveEditorSystem.CandidateFromStoredRecord(record) :: any

			expect(candidate).never.to.equal(nil)
			expect(candidate.Grab.HoldSeconds).to.equal(4)
			expect(candidate.Grab.ThrowUpVelocity).to.equal(20)
			expect(candidate.Grab.ThrowHorizontalVelocity).to.equal(30)
			expect(candidate.Grab.ThrowImpactDamage).to.equal(10)
			expect(candidate.Grab.ThrowSelfDamage).to.equal(5)
		end)
	end)

	describe("MoveEditorSystem.CandidateFromStoredRecord -- structural guard", function()
		it("returns nil for a non-table record", function()
			expect(MoveEditorSystem.CandidateFromStoredRecord("not a table")).to.equal(nil)
			expect(MoveEditorSystem.CandidateFromStoredRecord(nil)).to.equal(nil)
		end)
	end)
end
