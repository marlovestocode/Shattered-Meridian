--!strict
-- TransformLayer: composing pose offsets onto a Motor6D must never compound, on a joint nothing animates.
-- The bug this pins: an exact CFrame comparison against a Transform read-back failed every frame, so a
-- hit flinch compounded on the R6 RootJoint until the body spun and flipped upside down (2026-09-30).

local StarterPlayer = game:GetService("StarterPlayer")

local TransformLayer = require(StarterPlayer.StarterPlayerScripts.Client.FX.TransformLayer)

local function makeMotor(): (Motor6D, { Instance })
	local a = Instance.new("Part")
	local b = Instance.new("Part")
	local motor = Instance.new("Motor6D")
	motor.Part0 = a
	motor.Part1 = b
	motor.Parent = a
	return motor, { a, b }
end

local function angleBetween(x: CFrame, y: CFrame): number
	local _, angle = (x:Inverse() * y):ToAxisAngle()
	return math.abs(angle)
end

return function()
	local spawned: { Instance } = {}

	afterEach(function()
		for _, instance in spawned do
			instance:Destroy()
		end
		table.clear(spawned)
	end)

	local function motor(): Motor6D
		local m, parts = makeMotor()
		for _, part in parts do
			table.insert(spawned, part)
		end
		return m
	end

	it("holds an undriven joint at base * offset however many frames it runs", function()
		local joint = motor()
		local offset = CFrame.Angles(math.rad(-12), 0, math.rad(6))
		for _ = 1, 120 do
			TransformLayer.AdvanceFrame()
			TransformLayer.Compose(joint, offset)
		end
		expect(angleBetween(joint.Transform, offset) < 1e-3).to.equal(true)
	end)

	it("composes onto whatever an animation wrote this frame", function()
		local joint = motor()
		local offset = CFrame.Angles(math.rad(-12), 0, 0)
		TransformLayer.AdvanceFrame()
		TransformLayer.Compose(joint, offset)
		local animated = CFrame.Angles(0, math.rad(40), 0)
		joint.Transform = animated
		TransformLayer.AdvanceFrame()
		TransformLayer.Compose(joint, offset)
		expect(angleBetween(joint.Transform, animated * offset) < 1e-3).to.equal(true)
	end)

	it("stacks two layers on one joint without either compounding", function()
		local joint = motor()
		local first = CFrame.Angles(math.rad(-10), 0, 0)
		local second = CFrame.Angles(0, 0, math.rad(8))
		for _ = 1, 60 do
			TransformLayer.AdvanceFrame()
			TransformLayer.Compose(joint, first)
			TransformLayer.Compose(joint, second)
		end
		expect(angleBetween(joint.Transform, first * second) < 1e-3).to.equal(true)
	end)

	it("puts the joint back as it was found once the last layer stops", function()
		local joint = motor()
		TransformLayer.AdvanceFrame()
		TransformLayer.Compose(joint, CFrame.Angles(math.rad(-12), 0, 0))
		TransformLayer.AdvanceFrame()
		TransformLayer.Restore(joint)
		expect(angleBetween(joint.Transform, CFrame.identity) < 1e-3).to.equal(true)
	end)
end
