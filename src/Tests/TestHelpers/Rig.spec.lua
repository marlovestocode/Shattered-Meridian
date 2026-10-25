--!strict
local Workspace = game:GetService("Workspace")

local ServerScriptService = game:GetService("ServerScriptService")

local Rig = require(ServerScriptService.Tests.TestHelpers.Rig)

return function()
	afterEach(function()
		Rig.DestroyAll()
	end)

	describe("Rig.Dummy", function()
		it("builds an anchored, non-colliding root under a Humanoid with RequiresNeck off", function()
			local body = Rig.Dummy("RigSpecDummy", Vector3.new(1, 2, 3))
			expect(body.Model.Parent).to.equal(Workspace)
			expect(body.Model.PrimaryPart).to.equal(body.Root)
			expect(body.Root.Name).to.equal("HumanoidRootPart")
			expect(body.Root.Anchored).to.equal(true)
			expect(body.Root.CanCollide).to.equal(false)
			expect(body.Root.Position).to.equal(Vector3.new(1, 2, 3))
			expect(body.Humanoid.RequiresNeck).to.equal(false)
		end)

		it("faces lookAt when given one", function()
			local body = Rig.Dummy("RigSpecFacing", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			expect(body.Root.CFrame.LookVector.Z < -0.99).to.equal(true)
		end)

		it("leaves the root at the origin when given no position", function()
			local body = Rig.Dummy("RigSpecOrigin")
			expect(body.Root.Position).to.equal(Vector3.new(0, 0, 0))
		end)

		it("honours Anchored, Health, Attributes and Parent", function()
			local holder = Instance.new("Folder")
			holder.Parent = Workspace
			Rig.Track(holder)
			local body = Rig.Dummy("RigSpecOptions", nil, nil, {
				Anchored = false,
				Health = 40,
				Attributes = { SpecFlag = true },
				Parent = holder,
			})
			expect(body.Root.Anchored).to.equal(false)
			expect(body.Humanoid.MaxHealth).to.equal(40)
			expect(body.Humanoid.Health).to.equal(40)
			expect(body.Humanoid:GetAttribute("SpecFlag")).to.equal(true)
			expect(body.Model.Parent).to.equal(holder)
		end)

		it("adds a RootJoint under HumanoidRootPart only when asked", function()
			local plain = Rig.Dummy("RigSpecPlain")
			expect(plain.Root:FindFirstChild("RootJoint")).to.equal(nil)
			expect(plain.Model:FindFirstChild("Torso")).to.equal(nil)

			local jointed = Rig.Dummy("RigSpecJoint", nil, nil, { RootJoint = true })
			local joint = jointed.Root:FindFirstChild("RootJoint")
			expect(joint).never.to.equal(nil)
			expect((joint :: Motor6D).Part0).to.equal(jointed.Root)
			expect((joint :: Motor6D).Part1).to.equal(jointed.Model:FindFirstChild("Torso"))
		end)
	end)

	describe("Rig.Character", function()
		it("is unanchored and collidable with a hip height", function()
			local body = Rig.Character("RigSpecCharacter", Vector3.new(0, 50, 0))
			expect(body.Root.Anchored).to.equal(false)
			expect(body.Root.CanCollide).to.equal(true)
			expect(body.Humanoid.HipHeight).to.equal(2)
		end)
	end)

	describe("Rig.R6", function()
		it("is a real R6 rig whose RootJoint sits under HumanoidRootPart", function()
			local body = Rig.R6("RigSpecR6")
			expect(body.Root.Anchored).to.equal(true)
			local joint = body.Model:FindFirstChild("RootJoint", true)
			expect(joint).never.to.equal(nil)
			expect((joint :: Instance).Parent and (joint :: Instance).Parent.Name).to.equal("HumanoidRootPart")
		end)
	end)

	describe("Rig.Limbs and Rig.Bare", function()
		it("Limbs makes the six named limbs and no Humanoid", function()
			local model = Rig.Limbs("RigSpecLimbs")
			for _, limb in Rig.LIMB_NAMES do
				expect(model:FindFirstChild(limb)).never.to.equal(nil)
			end
			expect(model:FindFirstChildOfClass("Humanoid")).to.equal(nil)
		end)

		it("Bare is unparented and carries a part only on request", function()
			local model, humanoid, part = Rig.Bare()
			expect(model.Parent).to.equal(nil)
			expect(humanoid.Parent).to.equal(model)
			expect(part).to.equal(nil)
			local _, _, withPart = Rig.Bare(true)
			expect(withPart).never.to.equal(nil)
		end)
	end)

	describe("Rig.FakePlayer", function()
		it("hands out distinct user ids unless one is given", function()
			local first = Rig.FakePlayer("A")
			local second = Rig.FakePlayer("B")
			expect(first.UserId).never.to.equal(second.UserId)
			expect(Rig.FakePlayer("C", nil, 4242).UserId).to.equal(4242)
		end)
	end)

	describe("Rig.DestroyAll", function()
		it("destroys what it built and what it was handed, then forgets them", function()
			local body = Rig.Dummy("RigSpecDestroy")
			local stray = Instance.new("Part")
			stray.Parent = Workspace
			Rig.Track(stray)
			Rig.DestroyAll()
			expect(body.Model.Parent).to.equal(nil)
			expect(stray.Parent).to.equal(nil)
			Rig.DestroyAll()
		end)
	end)
end
