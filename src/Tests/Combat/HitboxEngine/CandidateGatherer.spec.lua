--!strict
-- Covers Server/Combat/HitboxEngine/CandidateGatherer.lua -- the hurtbox broadphase. A body's hurtbox is its
-- root plus its direct-child BaseParts: never an accessory's Handle or the held weapon's parts, which used to
-- resolve to their owner (striking a sword was a hit on its wielder) and crowd the candidate cap.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CandidateGatherer = require(ServerScriptService.Server.Combat.HitboxEngine.CandidateGatherer)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)

local spawned: { Instance } = {}

local function part(name: string, position: Vector3, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = Vector3.new(1, 1, 1)
	p.Anchored = true
	p.CanCollide = false
	p.CFrame = CFrame.new(position)
	p.Parent = parent
	return p
end

-- A body at `position` with a root, an arm, a hat and a sword out in front of it.
local function makeBody(name: string, position: Vector3): (Model, BasePart, BasePart, BasePart)
	local model = Instance.new("Model")
	model.Name = name
	local root = part("HumanoidRootPart", position, model)
	part("RightArm", position + Vector3.new(1.5, 0, 0), model)
	local accessory = Instance.new("Accessory")
	accessory.Parent = model
	local handle = part("Handle", position + Vector3.new(0, 2, 0), accessory)
	local weapon = Instance.new("Model")
	weapon.Name = "EquippedWeapon"
	weapon.Parent = model
	local blade = part("Blade", position + Vector3.new(0, 0, -3), weapon)
	model.PrimaryPart = root
	model.Parent = Workspace
	table.insert(spawned, model)
	return model, root, handle, blade
end

local function gathered(centre: Vector3, radius: number): { BasePart }
	local out: { BasePart } = {}
	CandidateGatherer.GatherSphere(centre, radius, out)
	return out
end

return function()
	afterEach(function()
		CandidateGatherer.Reset()
		for _, instance in spawned do
			instance:Destroy()
		end
		table.clear(spawned)
	end)

	describe("CandidateGatherer -- hurtbox index", function()
		it("gathers a body's root and limbs, and never its accessories or weapon", function()
			local model, root, handle, blade = makeBody("Target", Vector3.new(0, 5, 0))
			CandidateGatherer.SetBodies({ { Model = model, RootPart = root } })

			local out = gathered(Vector3.new(0, 5, 0), 10)
			expect(table.find(out, root)).to.be.ok()
			expect(table.find(out, model:FindFirstChild("RightArm") :: BasePart)).to.be.ok()
			expect(table.find(out, handle)).never.to.be.ok()
			expect(table.find(out, blade)).never.to.be.ok()
		end)

		it("gathers nothing from a body nowhere near the query", function()
			local model, root = makeBody("Far", Vector3.new(500, 5, 0))
			CandidateGatherer.SetBodies({ { Model = model, RootPart = root } })
			expect(#gathered(Vector3.new(0, 5, 0), 10)).to.equal(0)
		end)

		it("picks up a limb that arrives after registration", function()
			local model, root = makeBody("Late", Vector3.new(0, 5, 0))
			CandidateGatherer.SetBodies({ { Model = model, RootPart = root } })
			local leg = part("LeftLeg", Vector3.new(0, 3, 0), model)
			expect(table.find(gathered(Vector3.new(0, 3, 0), 1), leg)).to.be.ok()
		end)

		it("forgets a body the registry dropped", function()
			local model, root = makeBody("Gone", Vector3.new(0, 5, 0))
			CandidateGatherer.SetBodies({ { Model = model, RootPart = root } })
			CandidateGatherer.SetBodies({})
			expect(#gathered(Vector3.new(0, 5, 0), 10)).to.equal(0)
		end)

		it("stops at the candidate cap", function()
			local bodies = {}
			for index = 1, HitboxEngineConstants.MaxCandidatesPerSample do
				local model, root = makeBody(`Crowd{index}`, Vector3.new(0, 5, 0))
				table.insert(bodies, { Model = model, RootPart = root })
			end
			CandidateGatherer.SetBodies(bodies)
			local count = #gathered(Vector3.new(0, 5, 0), 10)
			expect(count).to.equal(HitboxEngineConstants.MaxCandidatesPerSample)
			expect(CandidateGatherer.WasSaturated(count)).to.equal(true)
		end)

		-- Gather takes a SHAPE and a pose and works out the sphere itself. HitboxGeometry.BoundingBox hands back the
		-- box's centre as a CFrame, and a reach shape's is not the identity -- it once reached GatherSphere as a
		-- CFrame, which threw on every swing (2026-10-09) and left nothing able to hit anything.
		describe("Gather -- a shape at a pose", function()
			it("finds a body inside a cone's reach, which sits forward of the pose", function()
				local model, root = makeBody("InFront", Vector3.new(0, 5, -6))
				CandidateGatherer.SetBodies({ { Model = model, RootPart = root } })

				local dimensions = HitboxTypes.DefaultDimensions()
				dimensions.Length = 10
				dimensions.AngleDegrees = 60
				local out: { BasePart } = {}
				local count = CandidateGatherer.Gather("Cone", dimensions, CFrame.new(0, 5, 0), out)

				expect(count > 0).to.equal(true)
				expect(table.find(out, root)).to.be.ok()
			end)

			it("finds nothing behind a cone, and does not throw for a centred shape", function()
				local model, root = makeBody("Behind", Vector3.new(0, 5, 60))
				CandidateGatherer.SetBodies({ { Model = model, RootPart = root } })

				local dimensions = HitboxTypes.DefaultDimensions()
				dimensions.Length = 10
				dimensions.AngleDegrees = 60
				local out: { BasePart } = {}
				expect(CandidateGatherer.Gather("Cone", dimensions, CFrame.new(0, 5, 0), out)).to.equal(0)
				expect(CandidateGatherer.Gather("Sphere", dimensions, CFrame.new(0, 5, 0), out)).to.equal(0)
			end)
		end)
	end)
end
