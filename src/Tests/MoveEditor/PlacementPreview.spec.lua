--!strict
-- Covers the Move Editor's Place mode math (Client/DevTools/MoveEditor/PlacementMath.lua) and how the
-- in-world preview builds each shape (HitboxPreviewShapes.lua). Both are pure; the gizmo and the parts
-- themselves are playtest-only (docs/architecture/2026-09-29-move-editor-tools-plan.md section 9).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Constants = require(ReplicatedStorage.Shared.Constants)
local HitboxGeometry = require(ReplicatedStorage.Shared.HitboxEngine.HitboxGeometry)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local MoveEditorClientFolder = (StarterPlayer :: any).StarterPlayerScripts.Client.DevTools.MoveEditor
local HitboxPreviewShapes = require(MoveEditorClientFolder.HitboxPreviewShapes)
local PlacementCamera = require(MoveEditorClientFolder.PlacementCamera)
local PlacementMath = require(MoveEditorClientFolder.PlacementMath)

local LIMITS = Constants.MoveEditor.Limits

local function dims(overrides: { [string]: number }?): MoveTypes.MoveDimensions
	local result = HitboxTypes.DefaultDimensions()
	result.Width, result.Height, result.Length = 4, 5, 6
	result.Radius, result.InnerRadius, result.AngleDegrees = 2, 0, 90
	for key, value in pairs(overrides or {}) do
		(result :: any)[key] = value
	end
	return result
end

local function near(a: Vector3, b: Vector3): boolean
	return (a - b).Magnitude < 1e-4
end

return function()
	describe("PlacementMath.UnwrapDelta", function()
		it("takes the short way across the 2*pi wrap ArcHandles reports mid-drag", function()
			-- Logged in the Phase 0b spike: 0.096 then -6.071 is a +0.116 step, not -6.167.
			expect(PlacementMath.UnwrapDelta(0.096, -6.071)).to.be.near(0.116, 1e-3)
			-- And the alternating pair, the same pose on both sides of the wrap, nets to nothing.
			local accumulated = 2.58
			local previous = 2.58
			for _, raw in { -3.69, 2.59, -3.68, 2.60 } do
				accumulated += PlacementMath.UnwrapDelta(previous, raw)
				previous = raw
			end
			expect(accumulated).to.be.near(2.60, 1e-3)
		end)

		it("passes an ordinary small step straight through", function()
			expect(PlacementMath.UnwrapDelta(0.2, 0.35)).to.be.near(0.15, 1e-9)
			expect(PlacementMath.UnwrapDelta(0.35, 0.2)).to.be.near(-0.15, 1e-9)
		end)
	end)

	describe("PlacementMath.Move", function()
		it("moves along the face's normal in the hitbox's own frame, snapped", function()
			local start = CFrame.new(0, 1, -3)
			expect(near(PlacementMath.Move(start, Enum.NormalId.Front, 1.1, 0.5), Vector3.new(0, 1, -4))).to.equal(true)
			expect(near(PlacementMath.Move(start, Enum.NormalId.Top, 0.3, 0), Vector3.new(0, 1.3, -3))).to.equal(true)
		end)

		it("carries the direction through the offset's own rotation", function()
			-- Yawed 90 degrees: the hitbox's Front (-Z) points along the anchor's -X.
			local start = MoveTypes.ComposeOffset(Vector3.zero, Vector3.new(0, 90, 0))
			expect(near(PlacementMath.Move(start, Enum.NormalId.Front, 2, 0), Vector3.new(-2, 0, 0))).to.equal(true)
		end)

		it("clamps to the authorable offset range", function()
			local moved = PlacementMath.Move(CFrame.identity, Enum.NormalId.Front, 1000, 0)
			expect(moved.Z).to.equal(LIMITS.OffsetStuds.Min)
		end)
	end)

	describe("PlacementMath.Resize", function()
		it("grows a Box one-sided: the dragged face moves, the opposite face stays", function()
			local dimensions, position =
				PlacementMath.Resize("Box", dims(), CFrame.new(0, 0, -3), Enum.NormalId.Right, 2, 0)
			expect(dimensions.Width).to.equal(6)
			expect(near(position, Vector3.new(1, 0, -3))).to.equal(true)
		end)

		it("maps Y to Height and Z to Length on a Box", function()
			expect((PlacementMath.Resize("Box", dims(), CFrame.identity, Enum.NormalId.Top, 1, 0)).Height).to.equal(6)
			expect((PlacementMath.Resize("Box", dims(), CFrame.identity, Enum.NormalId.Back, 1, 0)).Length).to.equal(7)
		end)

		it("sizes a cylinder's radius by half the drag, so its far side stays put", function()
			local dimensions, position =
				PlacementMath.Resize("Cylinder", dims(), CFrame.identity, Enum.NormalId.Right, 2, 0)
			expect(dimensions.Radius).to.equal(3)
			expect(near(position, Vector3.new(1, 0, 0))).to.equal(true)
		end)

		it("keeps a reach shape's origin for its tip and moves it for its base", function()
			local tip, tipAt = PlacementMath.Resize("Beam", dims(), CFrame.identity, Enum.NormalId.Front, 2, 0)
			expect(tip.Length).to.equal(8)
			expect(near(tipAt, Vector3.zero)).to.equal(true)
			local base, baseAt = PlacementMath.Resize("Beam", dims(), CFrame.identity, Enum.NormalId.Back, 2, 0)
			expect(base.Length).to.equal(8)
			expect(near(baseAt, Vector3.new(0, 0, 2))).to.equal(true)
		end)

		it("grows a ring or ball around its fixed origin", function()
			local ring, ringAt = PlacementMath.Resize("Arc", dims(), CFrame.identity, Enum.NormalId.Right, 1, 0)
			expect(ring.Radius).to.equal(3)
			expect(near(ringAt, Vector3.zero)).to.equal(true)
			local ball = PlacementMath.Resize("Sphere", dims(), CFrame.identity, Enum.NormalId.Top, 1, 0)
			expect(ball.Radius).to.equal(3)
		end)

		it("leaves a cone's width alone -- its width is its angle", function()
			local dimensions = PlacementMath.Resize("Cone", dims(), CFrame.identity, Enum.NormalId.Right, 3, 0)
			expect(HitboxPreviewShapes.Signature("Cone", dimensions)).to.equal(
				HitboxPreviewShapes.Signature("Cone", dims())
			)
		end)

		it("clamps, and a clamped drag does not slide the volume", function()
			local dimensions, position =
				PlacementMath.Resize("Box", dims({ Width = 0.2 }), CFrame.identity, Enum.NormalId.Right, -5, 0)
			expect(dimensions.Width).to.equal(LIMITS.Dimensions.Width.Min)
			expect(position.X).to.be.near(-0.05, 1e-6)
		end)
	end)

	describe("PlacementMath.Rotate", function()
		it("composes about the hitbox's own axis and reads back in ComposeOffset's order", function()
			local rotation = PlacementMath.Rotate(Vector3.zero, Enum.Axis.Y, math.rad(30), false)
			expect(near(rotation, Vector3.new(0, 30, 0))).to.equal(true)
			-- Round trip: the degrees rebuild the same orientation.
			local tilted = PlacementMath.Rotate(Vector3.new(0, 45, 0), Enum.Axis.X, math.rad(20), false)
			local expected = MoveTypes.ComposeOffset(Vector3.zero, Vector3.new(0, 45, 0))
				* CFrame.fromAxisAngle(Vector3.xAxis, math.rad(20))
			local rebuilt = MoveTypes.ComposeOffset(Vector3.zero, tilted)
			expect((rebuilt.LookVector - expected.LookVector).Magnitude < 1e-3).to.equal(true)
			expect((rebuilt.UpVector - expected.UpVector).Magnitude < 1e-3).to.equal(true)
		end)

		it("snaps to the rotation step when snapping is on", function()
			local rotation = PlacementMath.Rotate(Vector3.zero, Enum.Axis.Y, math.rad(37), true)
			expect(rotation.Y).to.be.near(PlacementMath.RotationSnapDegrees * 2, 1e-6)
		end)
	end)

	describe("PlacementCamera orbit", function()
		it("looks at its focus from the distance it was given", function()
			local focus = Vector3.new(10, 5, -3)
			local frame = PlacementCamera.Frame(focus, math.rad(30), math.rad(-20), 12)
			expect((frame.Position - focus).Magnitude).to.be.near(12, 1e-6)
			expect((frame.LookVector - (focus - frame.Position).Unit).Magnitude < 1e-6).to.equal(true)
		end)

		it("recovers the orbit that reproduces an existing camera, so entering Place mode does not jump", function()
			local focus = Vector3.new(0, 3, 0)
			local before = PlacementCamera.Frame(focus, math.rad(-70), math.rad(25), 9)
			local yaw, pitch, distance = PlacementCamera.AnglesFrom(before, focus)
			local after = PlacementCamera.Frame(focus, yaw, pitch, distance)
			expect((after.Position - before.Position).Magnitude < 1e-4).to.equal(true)
		end)

		it("clamps the starting distance to its zoom range", function()
			local focus = Vector3.zero
			local _, _, far = PlacementCamera.AnglesFrom(CFrame.new(0, 0, 500), focus)
			expect(far).to.equal(PlacementCamera.DistanceLimits.Max)
			local _, _, close = PlacementCamera.AnglesFrom(CFrame.new(0, 0, 0.5), focus)
			expect(close).to.equal(PlacementCamera.DistanceLimits.Min)
		end)
	end)

	describe("HitboxPreviewShapes.Build", function()
		it("builds each shape from the parts it is described with", function()
			local counts = {
				Box = 1,
				Sphere = 1,
				Cylinder = 1,
				Capsule = 3,
				Beam = 1,
				Cone = HitboxPreviewShapes.ConeSlices,
				Arc = HitboxPreviewShapes.ArcSegments,
			}
			for _, shape in MoveTypes.Shapes do
				expect(#HitboxPreviewShapes.Build(shape, dims())).to.equal(counts[shape])
			end
		end)

		it("sizes the simple shapes exactly", function()
			local box = HitboxPreviewShapes.Build("Box", dims())[1]
			expect(box.Size).to.equal(Vector3.new(4, 5, 6))
			local sphere = HitboxPreviewShapes.Build("Sphere", dims())[1]
			expect(sphere.Size).to.equal(Vector3.new(4, 4, 4))
			local cylinder = HitboxPreviewShapes.Build("Cylinder", dims())[1]
			expect(cylinder.Size).to.equal(Vector3.new(6, 4, 4))
			-- Turned to lie along Z, the engine's axis.
			expect(math.abs(cylinder.Local.RightVector.Z)).to.be.near(1, 1e-6)
		end)

		it("puts a beam in front of its origin, where the engine counts it", function()
			local beam = HitboxPreviewShapes.Build("Beam", dims())[1]
			expect(beam.Local.Position.Z).to.be.near(-3, 1e-6)
		end)

		it("keeps every piece's centre inside the volume the engine tests", function()
			for _, shape in MoveTypes.Shapes do
				local dimensions = dims({ InnerRadius = 1, AngleDegrees = 120 })
				for _, piece in HitboxPreviewShapes.Build(shape, dimensions) do
					expect(HitboxGeometry.ContainsPoint(shape, dimensions, piece.Local.Position, 1e-3)).to.equal(true)
				end
			end
		end)

		it("widens a cone's slices toward its base", function()
			local slices = HitboxPreviewShapes.Build("Cone", dims())
			expect(slices[#slices].Size.Y > slices[1].Size.Y).to.equal(true)
		end)
	end)
end
