--!strict
--[[
	FrameOrder.lua

	Owns: every client RenderStep slot, by name, in one ordered table -- what each binding reads that an earlier one wrote. A module
	calling RunService:BindToRenderStep takes its priority from `FrameOrder.Priority(name)`; it never writes an
	Enum.RenderPriority expression of its own.

	WHY (coworking plan F6, W10). Nineteen bindings each picked a priority at their own call site, and nothing showed that four
	modules sat at Camera+1, three at Character+1 and two each at Camera-1 and Camera-2. Inside one value the engine's order is not
	specified, so "which camera writer wins this frame" was an accident. The table below makes the order -- and every clash -- one
	readable fact. Tests/Client/FrameOrder.spec.lua fails on any clash not listed in KNOWN_CLASHES, so a NEW one cannot be added.

	THE CAMERA BAND WAS SETTLED ON 2026-10-27 (docs/architecture/2026-10-27-camera-motion.md): its three clashes are gone and
	every camera slot has its own value. The pose clash at Character + 1 is still listed, not fixed -- separating it changes
	which writer runs first, which is a playtest change (docs/architecture/2026-10-27-frame-order.md has the proposal).

	Does not own: what any binding does, Heartbeat/PreRender/Stepped callbacks (those carry no priority), or the server's tick
	(Server/Combat/CombatTick.lua owns combat's frame order).
]]

local FrameOrder = {}

local RP = Enum.RenderPriority

-- name -> { value, what it reads that something earlier wrote }. Ordered by value; ties are KNOWN_CLASHES.
local SLOTS: { [string]: { Value: number, Reads: string } } = {
	TransformLayer = {
		Value = RP.First.Value,
		Reads = "nothing: resets every composed Motor6D.Transform before anything this frame adds to it",
	},
	HitStopInputHold = {
		Value = RP.Input.Value + 1,
		Reads = "the input the engine just read, to hold it during a hit-stop",
	},
	-- THE CAMERA BAND (settled 2026-10-27, docs/architecture/2026-10-27-camera-motion.md): one value per slot, so the order is
	-- a fact rather than an accident. Undo the continuous rotation, then the shake (last on, first off); then everything that
	-- reads the clean camera or the body and sets a composer slot; then the composer; then the engine's camera; then what
	-- copies or composes onto its result.
	CameraRotationUndo = {
		Value = RP.Camera.Value - 9,
		Reads = "last frame's continuous rotation, the last one applied, so it comes off first",
	},
	CameraShakeUndo = {
		Value = RP.Camera.Value - 8,
		Reads = "last frame's shake, which it removes before anything reads the camera's look",
	},
	FlightCamera = { Value = RP.Camera.Value - 7, Reads = "the flight velocity and bank FlightController pushed" },
	BlimpCamera = { Value = RP.Camera.Value - 6, Reads = "the mounted hull's physics after the step" },
	CameraMotion = {
		Value = RP.Camera.Value - 5,
		Reads = "the root's velocity after physics and the clean camera look, which orients its lean and pull",
	},
	CameraFollow = { Value = RP.Camera.Value - 4, Reads = "the root's position after physics" },
	CombatCameraShoulder = {
		Value = RP.Camera.Value - 3,
		Reads = "the clean camera yaw and this frame's root rotation",
	},
	CombatCameraAim = { Value = RP.Camera.Value - 2, Reads = "the lock-on target and the clean camera look it pulls" },
	CameraOffsetComposer = { Value = RP.Camera.Value - 1, Reads = "every Humanoid.CameraOffset slot set above" },
	CombatCameraBody = {
		Value = RP.Camera.Value + 1,
		Reads = "this frame's camera yaw from the engine, which the body copies",
	},
	FOVOffset = { Value = RP.Camera.Value + 2, Reads = "every FieldOfView slot, onto the default camera's FieldOfView" },
	CameraShake = { Value = RP.Camera.Value + 3, Reads = "the frame's final pose, onto which it composes the shake" },
	CameraRotation = {
		Value = RP.Camera.Value + 4,
		Reads = "the camera after shake: the last rotation on the frame's pose",
	},
	BlimpPose = { Value = RP.Character.Value + 1, Reads = "the animator's pose, which the helm arm/lean overwrite" },
	BoatPose = { Value = RP.Character.Value + 1, Reads = "the animator's pose, which the helm arm/lean overwrite" },
	HitFlinchPose = { Value = RP.Character.Value + 1, Reads = "the animator's pose, which the flinch adds to" },
	GuardStrainPose = { Value = RP.Character.Value + 2, Reads = "the animator's pose, which the guard strain adds to" },
	GrabHoldPose = { Value = RP.Character.Value + 3, Reads = "the animator's pose, which the grab hold overwrites" },
	PlacementCamera = {
		Value = RP.Last.Value + 2,
		Reads = "everything: a dev camera that owns the frame while placing",
	},
}

-- The clashes that existed when this table was written (2026-10-27), by value. Each is a set of slots the engine orders
-- arbitrarily. Fixing one means giving its slots distinct values here (a playtest change) and deleting its row.
local KNOWN_CLASHES: { { string } } = {
	{ "BlimpPose", "BoatPose", "HitFlinchPose" },
}

function FrameOrder.Priority(name: string): number
	local slot = SLOTS[name]
	assert(slot ~= nil, `FrameOrder.Priority("{name}"): no such slot -- add it to Client/FrameOrder.lua`)
	return slot.Value
end

-- Every set of two or more slots sharing a value, each sorted, for the spec.
function FrameOrder.Clashes(): { { string } }
	local byValue: { [number]: { string } } = {}
	for name, slot in SLOTS do
		byValue[slot.Value] = byValue[slot.Value] or {}
		table.insert(byValue[slot.Value], name)
	end
	local clashes: { { string } } = {}
	for _, names in byValue do
		if #names > 1 then
			table.sort(names)
			table.insert(clashes, names)
		end
	end
	return clashes
end

function FrameOrder.KnownClashes(): { { string } }
	local copy: { { string } } = {}
	for _, names in KNOWN_CLASHES do
		local sorted = table.clone(names)
		table.sort(sorted)
		table.insert(copy, sorted)
	end
	return copy
end

return FrameOrder
