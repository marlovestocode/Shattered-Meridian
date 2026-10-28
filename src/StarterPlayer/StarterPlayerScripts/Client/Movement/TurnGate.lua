--!strict
--[[
	TurnGate.lua

	Owns: the local Humanoid's AutoRotate (turn to face the movement direction) -- the one client writer
	of it. Every reason to take the body's turning away from the Humanoid is a named claim; AutoRotate is
	off while any claim is held and back on when the last one goes. JumpGate's twin, for the same reason.

	WHY. Four modules wrote AutoRotate directly, and each took a snapshot when it switched it off and wrote
	the snapshot back when it was done:
	  * CombatCamera, false while engaged and true on release;
	  * ParkourMotor, for every frame it owns the body, restoring its capture on release;
	  * SwingTracking, for a swing's turn-to-target and facing hold;
	  * GrabInputClient, for a grab throw's clip.
	A snapshot is only right if nothing else wrote the property in the meantime, and these overlap all the
	time. A grab throw is a swing, so SwingTracking switched AutoRotate off, the throw captured that `false`,
	and the swing's end then wrote `true` in the middle of the throw clip: the thrower turned with their
	movement during a throw meant to root them. A swing that ended after the player engaged shift lock
	wrote `true` under it, and the Humanoid's turn then fought shift lock's yaw write on every strafe.
	CombatCamera had grown a handler that re-asserted its own answer after parkour's restore to repair
	one of these pairs. With one writer and a claim per owner, no owner can undo another's hold, and that
	repair is gone.

	Claims are keyed by Humanoid with weak keys (Client/Movement/HumanoidClaims.lua), so a fresh Humanoid
	starts with none and the engine's default (AutoRotate on) is the right answer.

	Does not own: what steers the body while AutoRotate is off (each owner does), or the server's own
	AutoRotate writes (AdminActionSystem's flight, the training bot's server-side body).
]]

local HumanoidClaims = require(script.Parent.HumanoidClaims)

local TurnGate = {}

-- Every owner. A new reason to stop the Humanoid turning the body is a new entry here, never a direct
-- AutoRotate write.
TurnGate.Owners = {
	-- Shift lock is engaged; the body follows the camera's yaw (CombatCamera).
	ShiftLock = "ShiftLock",
	-- Parkour owns the body and its orientation drive steers it (ParkourMotor).
	Parkour = "Parkour",
	-- A swing turns toward, then holds facing on, its target (SwingTracking).
	SwingTrack = "SwingTrack",
	-- A grab thrower is rooted for their throw clip (GrabInputClient, off GrabThrowing).
	GrabThrow = "GrabThrow",
}

local gate = HumanoidClaims.New(function(humanoid: Humanoid, held: boolean): ()
	local autoRotate = not held
	if humanoid.AutoRotate ~= autoRotate then
		humanoid.AutoRotate = autoRotate
	end
end)

-- Takes (`held` true) or drops (`held` false) `owner`'s claim. Idempotent, and it re-publishes every call,
-- so an owner restating its answer also repairs a value something outside this module wrote.
TurnGate.Set = gate.Set

-- Whether `owner` (or, with no owner, anybody) holds this Humanoid's turning.
TurnGate.IsHeld = gate.IsHeld

-- Whether anybody other than `owner` holds it -- "is something else steering this body".
TurnGate.IsHeldExcept = gate.IsHeldExcept

return TurnGate
