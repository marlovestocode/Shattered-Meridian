--!strict
-- Covers the two guards at the top of Server/Systems/BlimpSystem.registerBlimp -- "only register a hull
-- that is actually in the world" and "strip anything a hull inherited from a registration that happened
-- before it got there."
--
-- WHY THIS IS AN INTEGRATION SPEC AND NOT A PURE ONE. Every other Blimp spec tests a pure module
-- (BlimpDrive/BlimpFuel/BlimpSpeedLadder) or one geometric resolver (BlimpTagging). The behaviour here is
-- not a function's return value at all -- it is which Instances end up parented into a Model after
-- CollectionService raises its added signal -- so the only honest test is to tag a real Model and look.
--
-- WHICH MAKES THIS THE ONE SPEC IN THIS SUITE THAT CALLS A SYSTEM'S Init(), against the convention every
-- other one states plainly (Tests/Combat/Engagement/EngagementSystem.spec.lua's own header: "Init() is
-- never called either, for the ordinary reason every spec in this folder gives"). There is no
-- Main.server.lua in test.project.json -- nothing boots any System here -- so without this call
-- BlimpSystem's tag watch is not live and every assertion below passes for the wrong reason, which is
-- exactly what the first draft of this file did.
--
-- It is safe to do here and would not be elsewhere: BlimpConstants.Tags.Model appears in no other spec
-- in this suite, so the live watch this starts cannot reach another file's fixtures. That is the whole
-- justification -- if a second spec ever tags a model "Blimp", this one has to be reconsidered, the same
-- shared-VM-state trap Tests/TestHelpers' weapon fixture already documents.
--
-- THE BUG THESE PIN, in one sentence: CollectionService:GetTagged searches the whole DataModel, so a
-- Blimp template parked in ServerStorage for VehicleManager to clone was registered as if it were a
-- flying hull -- which welded it, unanchored it, and left an AlignPosition in its root that every clone
-- taken afterwards inherited, fighting its own drive to a standstill. See registerBlimp's own header.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local ServerScriptService = game:GetService("ServerScriptService")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpSystem = require(ServerScriptService.Server.Systems.BlimpSystem)

-- The instance BlimpAssembly.Build parents into a hull's root, and the single cheapest proof that a
-- model was registered. Named rather than searched for by class: a builder's own AlignPosition would be
-- a different name, and this spec must not confuse the two.
local DRIVE_POSITION_NAME = "BlimpDrivePosition"

-- Registration happens on CollectionService's added signal, which is not synchronous with AddTag. Two
-- Heartbeats rather than one: the first lets the signal fire, the second lets registerBlimp's own work
-- land before anything is asserted about it.
local function settle(): ()
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
end

-- Collection time, once. See this file's header for why this is the exception rather than drift.
BlimpSystem.Init()

return function()
	local models: { Model } = {}

	-- A minimal hull: one anchored part big enough to be a deck, plus a helm so the model is a legal
	-- blimp rather than a warning case. Parented wherever the caller says -- which is the whole variable
	-- under test.
	local function newHull(parent: Instance): Model
		local model = Instance.new("Model")
		model.Name = "RegistrationTestHull"

		local hull = Instance.new("Part")
		hull.Name = "Hull"
		hull.Size = Vector3.new(20, 2, 40)
		hull.Anchored = true
		hull.CanCollide = false
		hull.CFrame = CFrame.new(0, 500, 0)
		hull.Parent = model

		local helm = Instance.new("Part")
		helm.Name = "Helm"
		helm.Size = Vector3.new(2, 2, 2)
		helm.Anchored = true
		helm.CanCollide = false
		helm.CFrame = CFrame.new(0, 502, 0)
		helm.Parent = model
		CollectionService:AddTag(helm, BlimpConstants.Tags.Helm)

		model.PrimaryPart = hull
		model.Parent = parent
		table.insert(models, model)
		return model
	end

	local function driveConstraintCount(model: Model): number
		local count = 0
		for _, descendant in model:GetDescendants() do
			if descendant.Name == DRIVE_POSITION_NAME then
				count += 1
			end
		end
		return count
	end

	local function promptCount(model: Model): number
		local count = 0
		for _, descendant in model:GetDescendants() do
			if descendant.Name == BlimpConstants.Prompt.StationPromptName then
				count += 1
			end
		end
		return count
	end

	afterEach(function()
		for _, model in models do
			-- Untagged before it is destroyed so unregisterBlimp runs while the model still exists --
			-- otherwise the System tears down an assembly whose parts have already gone.
			CollectionService:RemoveTag(model, BlimpConstants.Tags.Model)
			model:Destroy()
		end
		table.clear(models)
		settle()
	end)

	describe("registering a tagged model", function()
		it("registers a hull that is in the world", function()
			local model = newHull(Workspace)
			CollectionService:AddTag(model, BlimpConstants.Tags.Model)
			settle()

			expect(driveConstraintCount(model)).to.equal(1)
		end)

		it("does NOT register a tagged model that is outside the world", function()
			-- The template case, exactly: tagged, legal, and sitting where VehicleConstants requires a
			-- vehicle template to live. Before the guard this came back from GetTagged looking like a
			-- hull and was welded, unanchored and given a drive constraint in place.
			local model = newHull(ServerStorage)
			CollectionService:AddTag(model, BlimpConstants.Tags.Model)
			settle()

			expect(driveConstraintCount(model)).to.equal(0)
			expect(promptCount(model)).to.equal(0)
		end)

		it("leaves an out-of-world model's parts anchored, so a clone of it is not born unanchored", function()
			-- The half of the damage that is invisible until the model is cloned: registration unanchors
			-- every part, and :Clone() copies that.
			local model = newHull(ServerStorage)
			CollectionService:AddTag(model, BlimpConstants.Tags.Model)
			settle()

			local hull = model:FindFirstChild("Hull") :: BasePart
			expect(hull.Anchored).to.equal(true)
		end)

		it("registers it later, if it is moved into the world", function()
			-- The guard is "not yet", not "never" -- a builder who drags a tagged hull out of storage
			-- and into Workspace at runtime still gets a blimp.
			local model = newHull(ServerStorage)
			CollectionService:AddTag(model, BlimpConstants.Tags.Model)
			settle()
			expect(driveConstraintCount(model)).to.equal(0)

			model.Parent = Workspace
			settle()
			expect(driveConstraintCount(model)).to.equal(1)
		end)

		it("strips a drive constraint the model arrived already carrying", function()
			-- A place file saved while a template was polluted hands every hull one of these forever.
			-- Registration has to end with exactly one drive constraint whatever it was handed.
			local model = newHull(Workspace)
			local stale = Instance.new("AlignPosition")
			stale.Name = DRIVE_POSITION_NAME
			stale.Parent = model.PrimaryPart
			expect(driveConstraintCount(model)).to.equal(1)

			CollectionService:AddTag(model, BlimpConstants.Tags.Model)
			settle()

			-- One, not two -- and specifically not the one that was already there. The inherited
			-- constraint is what pins a hull at the template's position while its own drive tries to
			-- fly it somewhere else.
			expect(driveConstraintCount(model)).to.equal(1)
			expect(stale.Parent).to.equal(nil)
		end)

		it("strips a station prompt the model arrived already carrying", function()
			-- The other half of the same inheritance, and the one a player felt: two prompts on one
			-- wheel, both on the Interact key, only one of them connected to anything.
			local model = newHull(Workspace)
			local helm = model:FindFirstChild("Helm") :: BasePart
			local stale = Instance.new("ProximityPrompt")
			stale.Name = BlimpConstants.Prompt.StationPromptName
			stale.Parent = helm

			CollectionService:AddTag(model, BlimpConstants.Tags.Model)
			settle()

			expect(promptCount(model)).to.equal(1)
		end)
	end)
end
