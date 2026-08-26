--!strict
--[[
	BlimpDrive.lua

	Owns: the flight integration -- turning a pilot's three axes into the pose the blimp's drive
	constraints are told to chase, one tick at a time, plus the validation that turns an untrusted table
	off a remote into a DriveIntent.

	TOUCHES NO INSTANCE, ON PURPOSE. Every function here takes a BlimpTypes.DriveState/DriveIntent/
	DriveTuning and returns one; nothing reads a part, a constraint, or workspace. That is what makes the
	whole of this system's actual behaviour -- does it accelerate the way it should, does the altitude
	band hold, does astern really cost more than ahead -- testable in the TestEZ suite without a place
	file, which is the same split Shared/FlightMath.lua's header already argues for from the other side.
	Server/Systems/BlimpSystem.lua owns every Instance touch and calls this for the arithmetic.

	NOTHING HERE EVER READS THE BLIMP'S REAL CFrame BACK. The integrator advances its own Target from its
	own previous Target, and the constraints chase whatever that is. Closing the loop -- re-seeding Target
	from the hull's actual pose each tick -- is the obvious-looking change and it is wrong twice over:
	the gap between target and actual IS the floatiness (a target that snaps to the hull can never lead
	it, so the blimp stops having mass), and a hull that gets shoved by a collision would drag its own
	target along with it, so a nudge would become a permanent course change no pilot asked for.

	ClampLead IS NOT AN EXCEPTION TO THAT, even though it is the one function below that cares where the
	hull actually is. It takes the hull's position as a plain Vector3 argument from its caller rather than
	reading any Instance itself, so this module still touches nothing but numbers. It exists because
	Step's blindness above, while correct for the normal case, has an edge the normal case does not cover:
	if something holds the hull still for long enough (a player wedged against it, a doorway, a stuck
	weld), Target's own march forward has no ceiling, and the gap between Target and the hull becomes debt
	that gets discharged as one large corrective velocity the instant the obstruction clears -- a hull that
	was floating suddenly launches whoever is standing on it. ClampLead is Server/Systems/BlimpSystem.lua's
	backstop for exactly that, called once a tick after Step, with the clamped result fed back into Drive
	itself so the integrator never carries more of that debt forward than BlimpConstants.Drive.MaxLeadStuds
	allows -- not just a value clipped on its way to the constraint, which would hide one frame of the
	problem and keep banking the rest.

	TARGET STAYS UPRIGHT AND IS RE-DERIVED FROM YAW EVERY STEP. Two reasons, and the second is the one
	that bites: an upright target means a blimp knocked askew by anything always rights itself, and
	rebuilding from a yaw-only look vector each step keeps hours of accumulated float error from leaning
	the hull a degree at a time with nothing in the logs. The visible bank is applied at PRESENTATION time
	instead (PresentationCFrame), so a turn that ends leaves no roll to unwind.

	Does not own: the constraints (BlimpAssembly.lua), who is allowed to steer (BlimpSystem.lua), the
	tuning numbers themselves (Shared/Blimp/BlimpConstants.lua), or the per-model overrides
	(Shared/Blimp/BlimpTagging.ResolveTuning).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlimpTypes = require(ReplicatedStorage.Shared.Blimp.BlimpTypes)

local BlimpDrive = {}

-- Seconds. A tick longer than this is a server hitch or a Studio breakpoint, not flight time, and
-- integrating it whole would teleport the target a hundred studs and leave the hull chasing a point it
-- cannot see. Clamping is the honest response: the blimp loses the stalled time rather than banking it.
local MAX_STEP_SECONDS = 0.25

-- Below this the yaw-only rebuild has no direction to work from. Only reachable if a caller hands in a
-- Target that is already degenerate, which is why the fallback is "keep the previous facing" rather than
-- an error -- a blimp that stops turning is recoverable, one that errors every Heartbeat is not.
local EPSILON = 1e-4

local function approach(current: number, target: number, maxDelta: number): number
	if current < target then
		return math.min(current + maxDelta, target)
	end
	return math.max(current - maxDelta, target)
end

local function isFiniteNumber(value: unknown): boolean
	if typeof(value) ~= "number" then
		return false
	end
	local number = value :: number
	-- NaN fails its own equality test; the infinity checks catch the other two ways a number can arrive
	-- unusable. Both matter: a NaN axis propagates into Target and the constraints stop being able to
	-- solve at all, which presents as a blimp that freezes solid and never recovers.
	return number == number and number ~= math.huge and number ~= -math.huge
end

function BlimpDrive.NeutralIntent(): BlimpTypes.DriveIntent
	return { Throttle = 0, Steer = 0, Lift = 0 }
end

-- Fresh state for a blimp that has just been registered, parked exactly where the builder left it. The
-- origin is flattened to yaw-only here rather than trusted as given, so a hull a builder placed at a
-- jaunty angle in Studio does not spend its first seconds of life being righted by the constraints.
function BlimpDrive.NewState(origin: CFrame): BlimpTypes.DriveState
	local look = origin.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	local facing = if flat.Magnitude > EPSILON then flat.Unit else Vector3.new(0, 0, -1)
	return {
		Target = CFrame.lookAt(origin.Position, origin.Position + facing),
		Speed = 0,
		YawRate = 0,
		ClimbRate = 0,
	}
end

-- Turns whatever came off the SetIntent remote into a usable intent, or nil if it was not one. Returns
-- nil rather than a neutral intent for a malformed payload, so the caller can tell "this client sent
-- nonsense" (worth a debug line) apart from "this client is holding no keys" (the common case, and not
-- worth one).
--
-- Clamps rather than rejects an out-of-range axis. A client claiming Throttle = 50 is asking to go fifty
-- times cruise speed and gets full ahead instead; refusing the whole packet would leave the last good
-- intent latched, which is a worse outcome for the one case this actually protects against.
function BlimpDrive.SanitizeIntent(raw: unknown): BlimpTypes.DriveIntent?
	if typeof(raw) ~= "table" then
		return nil
	end
	local candidate = raw :: { [string]: unknown }
	if
		not isFiniteNumber(candidate.Throttle)
		or not isFiniteNumber(candidate.Steer)
		or not isFiniteNumber(candidate.Lift)
	then
		return nil
	end
	return {
		Throttle = math.clamp(candidate.Throttle :: number, -1, 1),
		Steer = math.clamp(candidate.Steer :: number, -1, 1),
		Lift = math.clamp(candidate.Lift :: number, -1, 1),
	}
end

-- Turns whatever came off the SetHelmInput remote into the pilot's two HELD axes, or nil if it was not
-- a pair of them. Same contract, same clamp-rather-than-reject reasoning, and the same nil-means-
-- malformed-not-neutral distinction as SanitizeIntent immediately above.
--
-- A SEPARATE FUNCTION RATHER THAN SanitizeIntent WITH AN IGNORED FIELD. Throttle is a telegraph rung
-- the server owns now (Shared/Blimp/BlimpSpeedLadder.lua), so a client cannot assert a speed at all --
-- and the way to make that true is for the wire shape to have nowhere to put one. Accepting a Throttle
-- field here and quietly dropping it would leave a value in the payload that the server is
-- contractually obliged to ignore, which is exactly the kind of dead field that gets read by accident
-- a year later. See BlimpTypes.HelmInput.
function BlimpDrive.SanitizeHelmInput(raw: unknown): BlimpTypes.HelmInput?
	if typeof(raw) ~= "table" then
		return nil
	end
	local candidate = raw :: { [string]: unknown }
	if not isFiniteNumber(candidate.Steer) or not isFiniteNumber(candidate.Lift) then
		return nil
	end
	return {
		Steer = math.clamp(candidate.Steer :: number, -1, 1),
		Lift = math.clamp(candidate.Lift :: number, -1, 1),
	}
end

-- One tick. Pure: `state` is never mutated, the successor is returned.
--
-- `floorOverride`, when given, replaces tuning.MinAltitude for THIS TICK ONLY and is never written
-- back anywhere. It exists for the unattended landing (Server/Blimp/BlimpFlightMode.ResolveFloor):
-- MinAltitude is an absolute world Y whose whole job is to stop a pilot burying the hull in terrain,
-- so a ship descending onto a mountain would stop dead in mid-air at that altitude and hang there. The
-- landing hands in a floor derived from an actual downward raycast instead.
--
-- A PER-TICK ARGUMENT RATHER THAN A MUTATED tuning.MinAltitude, deliberately. `tuning` is resolved
-- once per hull at registration and is shared by every tick of that hull's life; writing a landing
-- floor into it would mean the hull permanently forgot the floor its builder authored the moment it
-- landed once, and the bug would only surface the next time somebody flew it over low ground. It is
-- also not a field on DriveState for the same reason -- state is what the integrator carries FORWARD,
-- and this is a fact about one tick's environment.
--
-- The ceiling is deliberately not overridable. There is no equivalent case: nothing needs to fly a
-- blimp higher than its hull was authored to go.
function BlimpDrive.Step(
	state: BlimpTypes.DriveState,
	intent: BlimpTypes.DriveIntent,
	tuning: BlimpTypes.DriveTuning,
	deltaTime: number,
	floorOverride: number?
): BlimpTypes.DriveState
	local dt = math.clamp(deltaTime, 0, MAX_STEP_SECONDS)
	if dt <= 0 then
		return state
	end

	-- Astern is its own, much lower ceiling -- see BlimpConstants.Drive.ReverseSpeed. The ramp toward it
	-- is the same, so reversing out of a mooring feels like the same vehicle, just reluctant.
	local commandedSpeed = if intent.Throttle >= 0
		then intent.Throttle * tuning.CruiseSpeed
		else intent.Throttle * tuning.ReverseSpeed
	local speed = approach(state.Speed, commandedSpeed, tuning.Acceleration * dt)
	local yawRate = approach(state.YawRate, intent.Steer * tuning.TurnRate, tuning.TurnAcceleration * dt)
	local climbRate = approach(state.ClimbRate, intent.Lift * tuning.ClimbSpeed, tuning.ClimbAcceleration * dt)

	-- Yaw first, then translate along the NEW heading. Translating first would make every turn a series
	-- of tiny straight segments taken before the nose came round, which reads as the hull crabbing.
	-- Negated because a positive Steer axis is starboard, and Roblox turns right on a negative Y rotation.
	local turned = state.Target * CFrame.Angles(0, -yawRate * dt, 0)
	-- Travel runs along the hull's BOW, which is its own facing plus the authored correction -- NOT along
	-- Target.LookVector directly. Those are the same thing only for a model whose root part happens to be
	-- oriented the way the artist drew the ship, and reading the raw LookVector is exactly how the first
	-- real blimp built against this flew backwards. See BlimpTypes.DriveTuning.ForwardYawRadians.
	--
	-- The yaw INPUT above is untouched by the correction on purpose: which world rotation counts as "to
	-- starboard" does not depend on where the bow is, so steering stays correct the moment travel does.
	local forward = (turned * CFrame.Angles(0, tuning.ForwardYawRadians, 0)).LookVector
	local position = turned.Position + forward * (speed * dt) + Vector3.new(0, climbRate * dt, 0)

	-- The override may legitimately sit ABOVE the authored ceiling on absurd terrain (a hull landing on
	-- a mountain taller than MaxAltitude), so the floor is bounded by the ceiling before use rather than
	-- handed to math.clamp as a min greater than its max -- which returns the MAX, silently teleporting
	-- the hull to the ceiling instead of landing it.
	local floor = math.min(floorOverride or tuning.MinAltitude, tuning.MaxAltitude)
	local clampedY = math.clamp(position.Y, floor, tuning.MaxAltitude)
	if clampedY ~= position.Y then
		-- Zeroed, not just clamped. Leaving the rate intact would let a pilot hold climb against the
		-- ceiling for a minute and then get a minute of stored descent the instant they let go.
		climbRate = 0
		position = Vector3.new(position.X, clampedY, position.Z)
	end

	local look = turned.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	local facing = if flat.Magnitude > EPSILON then flat.Unit else state.Target.LookVector

	return {
		Target = CFrame.lookAt(position, position + facing),
		Speed = speed,
		YawRate = yawRate,
		ClimbRate = climbRate,
	}
end

-- Bounds how far `target` may lead `actualPosition`, clamping only the DISTANCE between them along the
-- straight line that already separates them -- the direction and `target`'s own rotation are untouched.
-- See this file's header for why this is the one place that reads a real position at all and why that
-- does not compromise the rest of the module's purity contract.
--
-- Returns `target` UNCHANGED (the same value, not an equal copy) when it is already within the bound,
-- which is every tick of a clean flight path -- the caller relies on that to know whether it needs to
-- write anything back into Drive at all.
function BlimpDrive.ClampLead(target: CFrame, actualPosition: Vector3, maxLeadStuds: number): CFrame
	local offset = target.Position - actualPosition
	local distance = offset.Magnitude
	if distance <= maxLeadStuds then
		return target
	end
	-- distance > maxLeadStuds >= 0 here, so `offset` cannot be the zero vector and dividing by `distance`
	-- is safe. `target.Rotation` is target's own rotation about the origin -- adding the clamped position
	-- back onto it keeps the yaw ClampLead was handed and touches nothing else about the pose.
	local clampedPosition = actualPosition + (offset / distance) * maxLeadStuds
	return target.Rotation + clampedPosition
end

-- What the orientation constraint is actually given: the upright target plus the bank the current turn
-- rate earns. Derived, never stored -- see this file's header and BlimpTypes.DriveState.
--
-- Negated for the same reason the yaw is: a starboard turn (positive YawRate) should drop the starboard
-- side, and a positive roll about the local Z axis lifts it.
function BlimpDrive.PresentationCFrame(state: BlimpTypes.DriveState, tuning: BlimpTypes.DriveTuning): CFrame
	return state.Target * CFrame.Angles(0, 0, -state.YawRate * tuning.BankRadiansPerTurnRate)
end

return BlimpDrive
