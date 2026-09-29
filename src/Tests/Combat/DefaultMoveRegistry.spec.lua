--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local LiveTuningContract = require(ServerScriptService.Tests.TestHelpers.LiveTuningContract)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

-- The real roster this file reads. Weapons are models in Workspace.Weapons, so a spec that installs
-- none finds no weapon moves at all.
local ROSTER = WeaponFixture.Install()
local FIRST_WEAPON = ROSTER[1]
local SECOND_WEAPON = ROSTER[2]
local BASIC_ONE = `default:{FIRST_WEAPON}:Basic:1`

-- Every edit here is an override on shared module state (TestEZ runs every spec in one VM), so each
-- one is undone through Reset inside LiveTuningContract.withRestore -- the reset runs even when an
-- expectation fails.
local function withOverride(moveId: string, body: () -> ()): ()
	LiveTuningContract.withRestore(body, function()
		DefaultMoveRegistry.Reset(moveId)
	end)
end

local function candidateFor(moveId: string, edit: ({ [string]: any }) -> ()): { [string]: any }
	local wire = MoveTypes.ToWire(DefaultMoveRegistry.Get(moveId) :: any)
	edit(wire)
	return wire
end

local function countMatching(moves: { MoveTypes.MoveDefinition }, pattern: string): number
	local count = 0
	for _, move in ipairs(moves) do
		if string.match(move.MoveId, pattern) then
			count += 1
		end
	end
	return count
end

return function()
	describe("DefaultMoveRegistry.List", function()
		it("lists every weapon's string, air combo and finisher, plus both standalones", function()
			local moves = DefaultMoveRegistry.List()
			for _, weapon in { FIRST_WEAPON, SECOND_WEAPON } do
				expect(countMatching(moves, `^default:{weapon}:Basic:`) > 0).to.equal(true)
				expect(countMatching(moves, `^default:{weapon}:Finisher$`)).to.equal(1)
				expect(countMatching(moves, `^default:{weapon}:Launcher$`)).to.equal(1)
				expect(countMatching(moves, `^default:{weapon}:Air:%d$`)).to.equal(3)
				expect(countMatching(moves, `^default:{weapon}:AirFinisher:Slam$`)).to.equal(1)
			end
			expect(countMatching(moves, "^default:DashPunch$")).to.equal(1)
			expect(countMatching(moves, "^default:DashHit$")).to.equal(1)
		end)

		it("projects every stage as a validated-shape Box with no clip and no optional blocks", function()
			for _, move in ipairs(DefaultMoveRegistry.List()) do
				expect(move.Shape).to.equal("Box")
				expect(move.Author).to.equal("System")
				expect(move.AnimationId).to.equal("")
				expect(move.Knockback).to.equal(nil)
				expect(move.Grab).to.equal(nil)
				expect(move.Art).to.equal(nil)
				expect(move.WindupSeconds > 0).to.equal(true)
				expect(move.ActiveSeconds > 0).to.equal(true)
			end
		end)

		it("reads its box straight off the weapon-built stage's Size", function()
			local stage = (WeaponRoster.Get(FIRST_WEAPON) :: any).Stages.Basic[1]
			local move = DefaultMoveRegistry.Get(BASIC_ONE) :: any
			expect(move.Dimensions.Width).to.equal(stage.Size.X)
			expect(move.Dimensions.Height).to.equal(stage.Size.Y)
			expect(move.Dimensions.Length).to.equal(stage.Size.Z)
		end)

		it("weighs each stage by its place in the string", function()
			expect((DefaultMoveRegistry.Get(BASIC_ONE) :: any).PowerLevel).to.equal(MoveTypes.PowerLevelByStage.Basic)
			local finisher = DefaultMoveRegistry.Get(`default:{FIRST_WEAPON}:Finisher`) :: any
			expect(finisher.PowerLevel).to.equal(MoveTypes.PowerLevelByStage.Finisher)
			expect(finisher.Feintable).to.equal(false)
		end)

		it("groups by weapon, and the standalones together", function()
			expect(DefaultMoveRegistry.GroupOf(BASIC_ONE)).to.equal(FIRST_WEAPON)
			expect(DefaultMoveRegistry.GroupOf("default:DashPunch")).to.equal(DefaultMoveRegistry.StandaloneGroup)
			expect(DefaultMoveRegistry.GroupOf("default:NotAMove")).to.equal(nil)
		end)
	end)

	describe("DefaultMoveRegistry.ApplyEdit", function()
		it("overrides the move without writing the weapon's stage table", function()
			local stage = (WeaponRoster.Get(FIRST_WEAPON) :: any).Stages.Basic[1]
			local stageWindup = stage.WindupSeconds
			withOverride(BASIC_ONE, function()
				local result = DefaultMoveRegistry.ApplyEdit(
					BASIC_ONE,
					candidateFor(BASIC_ONE, function(wire)
						wire.WindupSeconds = 0.9
						wire.Shape = "Sphere"
					end)
				) :: any
				expect(result.WindupSeconds).to.equal(0.9)
				expect(result.Shape).to.equal("Sphere")
				expect((DefaultMoveRegistry.Get(BASIC_ONE) :: any).WindupSeconds).to.equal(0.9)
				expect(DefaultMoveRegistry.IsOverridden(BASIC_ONE)).to.equal(true)
				expect(stage.WindupSeconds).to.equal(stageWindup)
			end)
		end)

		it("keeps identity, anchor and optional blocks the move's own, whatever the candidate claims", function()
			local built = DefaultMoveRegistry.GetBuilt(BASIC_ONE) :: any
			withOverride(BASIC_ONE, function()
				local result = DefaultMoveRegistry.ApplyEdit(
					BASIC_ONE,
					candidateFor(BASIC_ONE, function(wire)
						wire.MoveId = "someone-else"
						wire.DisplayName = "Renamed"
						wire.AttachmentPart = "LeftHand"
						wire.Knockback = { UpVelocity = 50, HorizontalVelocity = 50 }
					end)
				) :: any
				expect(result.MoveId).to.equal(BASIC_ONE)
				expect(result.DisplayName).to.equal(built.DisplayName)
				expect(result.AttachmentPart).to.equal(built.AttachmentPart)
				expect(result.Knockback).to.equal(nil)
			end)
		end)

		it("clamps through MoveRegistryManager.Validate like any other move", function()
			withOverride("default:DashPunch", function()
				local result = DefaultMoveRegistry.ApplyEdit(
					"default:DashPunch",
					candidateFor("default:DashPunch", function(wire)
						wire.Damage = 99999
					end)
				) :: any
				expect(result.Damage < 99999).to.equal(true)
			end)
		end)

		it("refuses an unknown id or a structurally invalid candidate, leaving no override", function()
			local _, unknown = DefaultMoveRegistry.ApplyEdit("default:NotARealMove", {})
			expect(unknown).to.equal("MoveNotFound")
			local result, reason = DefaultMoveRegistry.ApplyEdit(
				BASIC_ONE,
				candidateFor(BASIC_ONE, function(wire)
					wire.Shape = "Wedge"
				end)
			)
			expect(result).to.equal(nil)
			expect(reason).to.equal("InvalidShapeKind")
			expect(DefaultMoveRegistry.IsOverridden(BASIC_ONE)).to.equal(false)
		end)
	end)

	describe("DefaultMoveRegistry.Reset", function()
		it("forgets the override, so the move is exactly its built self again", function()
			local builtPrint = MoveTypes.Fingerprint(DefaultMoveRegistry.GetBuilt(BASIC_ONE) :: any)
			DefaultMoveRegistry.ApplyEdit(
				BASIC_ONE,
				candidateFor(BASIC_ONE, function(wire)
					wire.Damage = 1
				end)
			)
			local reset = DefaultMoveRegistry.Reset(BASIC_ONE) :: any
			expect(MoveTypes.Fingerprint(reset)).to.equal(builtPrint)
			expect(MoveTypes.Fingerprint(DefaultMoveRegistry.Get(BASIC_ONE) :: any)).to.equal(builtPrint)
			expect(DefaultMoveRegistry.IsOverridden(BASIC_ONE)).to.equal(false)
		end)

		it("returns nil for an unknown id", function()
			expect(DefaultMoveRegistry.Reset("default:NotARealMove")).to.equal(nil)
		end)
	end)
end
