--!strict
-- Covers Client/FX/CameraRotationComposer.lua's slot composition and the exactness of its undo. The render steps need a
-- live camera and a frame clock; what they apply is Step's sum as RotationOf's CFrame, and both are checked here.

local StarterPlayer = game:GetService("StarterPlayer")

local CameraRotationComposer = require(StarterPlayer.StarterPlayerScripts.Client.FX.CameraRotationComposer)

local FRAME = 1 / 60

local function near(a: Vector3, b: Vector3, epsilon: number): boolean
	return (a - b).Magnitude < epsilon
end

return function()
	describe("CameraRotationComposer", function()
		afterEach(function()
			CameraRotationComposer.ResetForTesting()
		end)

		it("is level with no slots", function()
			expect(CameraRotationComposer.Step(FRAME)).to.equal(Vector3.zero)
		end)

		it("snaps a slot with no ease and sums slots from different callers, axis by axis", function()
			CameraRotationComposer.SetContinuous("Lean", Vector3.new(0, 0, 0.05), nil)
			CameraRotationComposer.SetContinuous("Blimp", Vector3.new(0.02, -0.03, -0.01), nil)
			expect(near(CameraRotationComposer.Step(FRAME), Vector3.new(0.02, -0.03, 0.04), 1e-9)).to.equal(true)
		end)

		it("eases a slot toward its target and never past it", function()
			CameraRotationComposer.SetContinuous("Tilt", Vector3.new(0, 0, 0.1), 8)
			local previous = 0
			for _ = 1, 120 do
				local roll = CameraRotationComposer.Step(FRAME).Z
				expect(roll >= previous).to.equal(true)
				expect(roll <= 0.1 + 1e-9).to.equal(true)
				previous = roll
			end
			expect(previous).to.be.near(0.1, 1e-3)
		end)

		it("eases at the same rate at any frame rate", function()
			local function after(fps: number): number
				CameraRotationComposer.ResetForTesting()
				CameraRotationComposer.SetContinuous("Tilt", Vector3.new(0, 0, 0.1), 8)
				local roll = 0
				for _ = 1, fps / 6 do
					roll = CameraRotationComposer.Step(1 / fps).Z
				end
				return roll
			end
			local reference = after(240)
			for _, fps in { 30, 60, 144 } do
				expect(after(fps)).to.be.near(reference, 1e-5)
			end
		end)

		it("releases a slot smoothly when it is set back to zero", function()
			CameraRotationComposer.SetContinuous("Tilt", Vector3.new(0, 0, 0.1), nil)
			CameraRotationComposer.Step(FRAME)
			CameraRotationComposer.SetContinuous("Tilt", Vector3.zero, 8)
			local first = CameraRotationComposer.Step(FRAME).Z
			expect(first > 0.05 and first < 0.1).to.equal(true)
			local last = first
			for _ = 1, 180 do
				last = CameraRotationComposer.Step(FRAME).Z
			end
			expect(last).to.be.near(0, 1e-3)
		end)

		it("drops a cleared slot at once and leaves the others", function()
			CameraRotationComposer.SetContinuous("A", Vector3.new(0, 0.05, 0), nil)
			CameraRotationComposer.SetContinuous("B", Vector3.new(0, 0.02, 0), nil)
			CameraRotationComposer.ClearContinuous("A")
			expect(near(CameraRotationComposer.Step(FRAME), Vector3.new(0, 0.02, 0), 1e-9)).to.equal(true)
		end)

		-- The bug this module fixes: a yaw left on the camera became the next frame's look and was applied again. The undo
		-- must hand the camera scripts back EXACTLY the look they produced, with a shake (applied before, undone after) in
		-- between, frame after frame.
		it("hands the camera back exactly the look it was given, through a shake, for any number of frames", function()
			local look = CFrame.lookAt(Vector3.new(5, 10, 5), Vector3.new(30, 4, -12))
			local sway = CameraRotationComposer.RotationOf(Vector3.new(0.12, -0.18, 0.24))
			local camera = look
			for frame = 1, 120 do
				local shake = CFrame.Angles(0.02 * math.sin(frame), 0.03 * math.cos(frame), 0.01)
				-- Camera + 3 shake, Camera + 4 rotation; next frame: rotation undo, then shake undo.
				camera = camera * shake * sway
				camera = camera * sway:Inverse()
				camera = camera * shake:Inverse()
			end
			-- CFrame is float32, so 480 multiplies leave rounding in the fifth decimal -- and NOT a degree per frame, which is
			-- what a rotation left on the camera accumulated before this module.
			expect(near(camera.LookVector, look.LookVector, 1e-4)).to.equal(true)
			expect(near(camera.Position, look.Position, 1e-3)).to.equal(true)
		end)
	end)
end
