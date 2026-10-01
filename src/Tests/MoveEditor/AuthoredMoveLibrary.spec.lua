--!strict
-- Covers Server/Combat/AuthoredMoveLibrary.lua -- moves shipped in the game's source, loaded at boot. Driven
-- through LoadFrom with the fixture folder Tests/Fixtures/AuthoredMoves (real files, so nothing here
-- depends on the harness being allowed to write a ModuleScript's Source).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AuthoredMoveLibrary = require(ServerScriptService.Server.Combat.AuthoredMoveLibrary)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local FIXTURES = ServerScriptService.Tests.Fixtures.AuthoredMoves
local SHIPPED_ID = "fixture-shipped-move"
local OVERRIDDEN_ID = "default:DashPunch"

return function()
	beforeEach(function()
		MoveRegistryManager.Init()
		AuthoredMoveLibrary.Reset()
	end)

	afterEach(function()
		DefaultMoveRegistry.SetShipped(OVERRIDDEN_ID, nil)
		DefaultMoveRegistry.Reset(OVERRIDDEN_ID)
		AuthoredMoveLibrary.Reset()
		MoveRegistryManager.Init()
	end)

	describe("AuthoredMoveLibrary.LoadFrom", function()
		it("puts a shipped custom move in the registry and remembers it shipped", function()
			AuthoredMoveLibrary.LoadFrom(FIXTURES)
			local move = MoveRegistryManager.Get(SHIPPED_ID)
			expect(move).to.be.ok()
			expect((move :: any).Damage).to.equal(11)
			expect(AuthoredMoveLibrary.IsShipped(SHIPPED_ID)).to.equal(true)
			local shipped = AuthoredMoveLibrary.GetShippedMove(SHIPPED_ID) :: MoveTypes.MoveDefinition
			expect(MoveTypes.Fingerprint(shipped)).to.equal(MoveTypes.Fingerprint(move :: MoveTypes.MoveDefinition))
		end)

		it("skips a file that throws and a file that is not a move, and loads the rest", function()
			AuthoredMoveLibrary.LoadFrom(FIXTURES)
			expect(MoveRegistryManager.Get(SHIPPED_ID)).to.be.ok()
			expect(#MoveRegistryManager.List()).to.equal(1)
		end)

		it("makes a shipped override part of what the weapon move is built as", function()
			local before = (DefaultMoveRegistry.GetBuilt(OVERRIDDEN_ID) :: any).Damage
			expect(before ~= 13).to.equal(true)
			AuthoredMoveLibrary.LoadFrom(FIXTURES)
			expect((DefaultMoveRegistry.GetBuilt(OVERRIDDEN_ID) :: any).Damage).to.equal(13)
			expect((DefaultMoveRegistry.Get(OVERRIDDEN_ID) :: any).Damage).to.equal(13)
			expect(AuthoredMoveLibrary.IsShipped(OVERRIDDEN_ID)).to.equal(true)
		end)

		it("still lets a live (DataStore) override layer over the shipped one, and Reset returns to it", function()
			AuthoredMoveLibrary.LoadFrom(FIXTURES)
			local wire = MoveTypes.ToWire(DefaultMoveRegistry.Get(OVERRIDDEN_ID) :: MoveTypes.MoveDefinition)
			wire.Damage = 20
			expect(DefaultMoveRegistry.ApplyEdit(OVERRIDDEN_ID, wire)).to.be.ok()
			expect((DefaultMoveRegistry.Get(OVERRIDDEN_ID) :: any).Damage).to.equal(20)
			expect((DefaultMoveRegistry.GetBuilt(OVERRIDDEN_ID) :: any).Damage).to.equal(13)
			DefaultMoveRegistry.Reset(OVERRIDDEN_ID)
			expect((DefaultMoveRegistry.Get(OVERRIDDEN_ID) :: any).Damage).to.equal(13)
		end)

		it("is harmless with no folder at all", function()
			AuthoredMoveLibrary.LoadFrom(nil)
			expect(#MoveRegistryManager.List()).to.equal(0)
		end)
	end)
end
