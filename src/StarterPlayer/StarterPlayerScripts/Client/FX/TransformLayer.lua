--!strict
--[[
	TransformLayer.lua

	Owns: composing procedural offsets onto a Motor6D's Transform AFTER the animation step, without them
	ever accumulating -- for every pose layer that does it (GuardStrainPose, HitFlinchPose).

	THE PROBLEM IT SOLVES. A joint an animation drives has its Transform rewritten every frame, so
	"animated pose * offset" is stable. A joint NO clip drives (an R6 RootJoint under the default idle and
	walk) keeps whatever was last written, and composing onto THAT compounds the offset every frame. So each
	joint remembers the base it composed onto and the value it wrote: if the joint still holds that write,
	nothing rewrote it and the remembered base is reused.

	"STILL HOLDS THAT WRITE" IS A TOLERANCE, NEVER ==. Both pose modules first shipped with their own copy of
	this and an exact CFrame comparison, and a value read back from Motor6D.Transform is not bit-identical to
	the one written. The comparison failed every frame, the layer's own write was taken for a fresh animated
	base, and the offset compounded: on the undriven RootJoint a 10-degree flinch became the whole body
	spinning and flipping upside down within a second (2026-09-30).

	ONE BASE PER JOINT PER FRAME, SHARED BY EVERY LAYER. Two layers keeping separate bookkeeping on one joint
	(a guard strain blending out while a guard-break hit flinches the same body) would each read the other's
	write as a new base and ratchet exactly as above. So the state is keyed by the Motor6D, not by the layer:
	the first layer to touch a joint in a frame settles its base, every later layer that frame composes onto
	the same base, and the joint holds base * (every live layer's offset). A layer that stops simply stops
	contributing; the next frame rebuilds from the base without it, and Restore puts the base back once no
	layer is left.

	Does not own: what any offset is (each pose module), when to apply it (their RenderStep bindings, which
	must run above Enum.RenderPriority.Character), or which joints.
]]

local RunService = game:GetService("RunService")

local TransformLayer = {}

-- Studs of position, and radians of rotation, under which two Transforms are the same pose: far above the
-- round-off a Transform read-back carries, far below anything an animation moves in one frame.
local SAME_POSE_EPSILON = 1e-3

type JointRecord = {
	-- The pose the layers compose onto: the animated value, or for an undriven joint the value found there.
	Base: CFrame,
	-- What was last written, and the offset product it was written from.
	Written: CFrame?,
	Offset: CFrame,
	-- The frame the record was last composed in.
	Frame: number,
}

local records: { [Motor6D]: JointRecord } = setmetatable({}, { __mode = "k" }) :: any

-- Counts frames, ahead of every pose layer and of the animation step.
local frame = 0
local frameBound = false
local FRAME_BINDING = "TransformLayerFrame"

local function ensureFrameCounter(): ()
	if frameBound then
		return
	end
	frameBound = true
	-- pcall: RenderStep does not exist outside a client (the spec harness), where AdvanceFrame drives it.
	pcall(function()
		RunService:BindToRenderStep(FRAME_BINDING, Enum.RenderPriority.First.Value, function()
			frame += 1
		end)
	end)
end

-- Spec-only: steps the frame counter the RenderStep binding would, so a spec can compose across frames.
function TransformLayer.AdvanceFrame(): ()
	frame += 1
end

function TransformLayer.SamePose(a: CFrame, b: CFrame): boolean
	if (a.Position - b.Position).Magnitude > SAME_POSE_EPSILON then
		return false
	end
	local _, angle = (a:Inverse() * b):ToAxisAngle()
	return math.abs(angle) <= SAME_POSE_EPSILON
end

-- Adds `offset` to `motor` for this frame, on top of whatever other layers have added this frame.
function TransformLayer.Compose(motor: Motor6D, offset: CFrame): ()
	if motor.Parent == nil then
		return
	end
	ensureFrameCounter()
	local record = records[motor]
	if record == nil then
		record = { Base = motor.Transform, Written = nil, Offset = CFrame.identity, Frame = -1 }
		records[motor] = record
	end
	if record.Frame ~= frame then
		-- First layer on this joint this frame: settle the base. Anything but our own last write means an
		-- animation (or something else) set the joint since, and that is the new base.
		local current = motor.Transform
		local written = record.Written
		if written == nil or not TransformLayer.SamePose(current, written) then
			record.Base = current
		end
		record.Frame = frame
		record.Offset = offset
	else
		record.Offset = record.Offset * offset
	end
	local nextWritten = record.Base * record.Offset
	motor.Transform = nextWritten
	record.Written = nextWritten
end

-- A layer is done with `motor`. If no layer has composed onto it this frame and it still holds the last
-- write, the base goes back -- the joint is left as it was found. If another layer is still composing, it
-- rebuilds from the base on its own next frame, without this layer's offset.
function TransformLayer.Restore(motor: Motor6D): ()
	local record = records[motor]
	if record == nil or record.Frame == frame then
		return
	end
	local written = record.Written
	if written and motor.Parent ~= nil and TransformLayer.SamePose(motor.Transform, written) then
		motor.Transform = record.Base
	end
	records[motor] = nil
end

return TransformLayer
