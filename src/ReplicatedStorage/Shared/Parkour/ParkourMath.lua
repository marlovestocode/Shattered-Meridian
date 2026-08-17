--!strict
--[[
	ParkourMath.lua

	Owns: every piece of pure, Instance-free math the parkour framework runs on -- momentum
	integration, slope resolution, wall tangent/approach geometry, wall-jump velocity composition,
	landing classification, air steering, and the two assist-window predicates (coyote time and
	input buffering).

	Deliberately has no Roblox Instance dependency (no Humanoid, no BasePart, no Workspace, no
	Constants lookup -- every tunable arrives as a plain parameter), the same shape
	Shared/FlightMath.lua already established and for the same reason: it makes the whole decision
	layer of this feature headlessly TestEZ-testable, which is the only way a movement system with
	this many interacting numbers stays trustworthy through retuning. Shared/Parkour/
	ObstacleClassifier.lua and ParkourValidation.lua are the two sibling modules held to the same
	rule.

	Reuses Shared/FlightMath.EaseAlpha rather than re-deriving the rate->alpha exponential ease --
	that function's own header names re-derivation across modules as the exact problem it was
	extracted to stop, and FlightMath is equally Instance-free so requiring it costs this module
	nothing.

	Does not own: any Constants.Parkour lookup (callers pass numbers in), any state, or any decision
	about WHEN to call these (the Client/Parkour/States/ modules own that).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)

local ParkourMath = {}

-- Below this magnitude a direction vector has no usable .Unit (Roblox returns NaN for the unit of a
-- zero vector, which then silently poisons every downstream Vector3 it touches). Every function
-- here that normalizes goes through Safe* helpers instead of touching .Unit directly.
local ZERO_EPSILON = 1e-4

local UP = Vector3.new(0, 1, 0)

-- Unit vector, or `fallback` when `vector` is too close to zero to have a meaningful direction.
-- Never returns a NaN vector.
function ParkourMath.SafeUnit(vector: Vector3, fallback: Vector3): Vector3
	if vector.Magnitude < ZERO_EPSILON then
		return fallback
	end
	return vector.Unit
end

-- The XZ (horizontal) component of a vector, Y zeroed. The framework's single definition of
-- "planar" -- momentum, move intent, wall tangents and travel direction are all planar quantities,
-- and flattening them in one named place keeps that consistent.
function ParkourMath.Flatten(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

-- Planar magnitude -- Flatten(...).Magnitude, named because it appears in almost every state.
function ParkourMath.PlanarSpeed(velocity: Vector3): number
	return Vector3.new(velocity.X, 0, velocity.Z).Magnitude
end

-- Removes the component of `vector` pointing along `normal`, leaving only what lies in the plane.
-- Used for slope-projected movement (walking along a ramp rather than into it) and for keeping
-- wall-run velocity parallel to the wall face.
function ParkourMath.ProjectOnPlane(vector: Vector3, normal: Vector3): Vector3
	local unitNormal = ParkourMath.SafeUnit(normal, UP)
	return vector - unitNormal * vector:Dot(unitNormal)
end

-- Frame-rate-independent step toward `target` at `ratePerSecond`, never overshooting even across a
-- lag spike. Identical in intent to FlightMath's own (private) stepToward -- reproduced here rather
-- than exported from there because this module applies it to a SCALAR momentum, where FlightMath
-- applies it per-axis to a velocity vector, and merging the two would mean exporting a helper whose
-- only shared property is the clamp.
function ParkourMath.StepToward(current: number, target: number, ratePerSecond: number, deltaTime: number): number
	local gap = target - current
	local maxStep = math.max(ratePerSecond, 0) * math.max(deltaTime, 0)
	if math.abs(gap) <= maxStep then
		return target
	end
	return current + maxStep * (if gap > 0 then 1 else -1)
end

-- The core of the momentum model: advances planar speed toward `targetSpeed`.
--
-- Three regimes, not one, which is what makes momentum actually READ as momentum:
--   * Below target with input held -> accelerate at `acceleration`.
--   * Below target with no input   -> decelerate at `deceleration` toward zero (target is ignored;
--                                     releasing the stick means stopping, not coasting to walk pace).
--   * Above target (any input)     -> bleed off at `deceleration + overspeedDecay`. This is the
--                                     branch that decides how long speed earned from a slide, vault
--                                     or wall-jump survives -- the single most important feel knob
--                                     in the whole system, which is why overspeed is its own regime
--                                     rather than folded into plain deceleration.
--
-- `hasInput` is the caller's own movement-intent test (magnitude vs. the input threshold), passed in
-- rather than re-derived here so this stays a pure numeric function.
function ParkourMath.IntegrateMomentum(
	currentSpeed: number,
	targetSpeed: number,
	hasInput: boolean,
	acceleration: number,
	deceleration: number,
	overspeedDecay: number,
	deltaTime: number
): number
	if currentSpeed > targetSpeed then
		return ParkourMath.StepToward(currentSpeed, targetSpeed, deceleration + overspeedDecay, deltaTime)
	end
	if not hasInput then
		return ParkourMath.StepToward(currentSpeed, 0, deceleration, deltaTime)
	end
	return ParkourMath.StepToward(currentSpeed, targetSpeed, acceleration, deltaTime)
end

-- Angle (degrees, 0-90) between a surface normal and straight up -- a floor's steepness. 0 is
-- perfectly flat, 90 is a vertical wall.
function ParkourMath.SlopeAngle(normal: Vector3): number
	local unitNormal = ParkourMath.SafeUnit(normal, UP)
	return math.deg(math.acos(math.clamp(unitNormal:Dot(UP), -1, 1)))
end

-- Angle (degrees, 0-90) a surface tilts away from VERTICAL -- a wall's uprightness, the complement
-- of SlopeAngle above. Its own named function rather than `90 - SlopeAngle` at each call site
-- because the two are asking opposite questions ("is this floor flat enough to stand on" vs. "is
-- this wall upright enough to run along") and conflating them is how a wall-run ends up legal on a
-- gentle ramp.
function ParkourMath.SurfaceTilt(normal: Vector3): number
	return 90 - ParkourMath.SlopeAngle(normal)
end

-- Where the character's ROOT sits while hanging from an edge: below the lip by `verticalOffset` and
-- backed off from the wall face along its outward normal by `horizontalOffset`.
--
-- Lives here rather than inside States/LedgeHanging.lua because two callers need the same answer and
-- must not be able to disagree about it: the state, which poses the character, and
-- EnvironmentProbe.probeLedge, which has to test whether that pose is actually clear of the floor
-- before the grab is offered at all. A probe checking one position while the state moves to another
-- is a refusal that protects nothing.
function ParkourMath.HangPosition(
	edgePosition: Vector3,
	wallNormal: Vector3,
	verticalOffset: number,
	horizontalOffset: number
): Vector3
	local outward = ParkourMath.SafeUnit(ParkourMath.Flatten(wallNormal), Vector3.zero)
	return edgePosition + Vector3.new(0, verticalOffset, 0) + outward * -horizontalOffset
end

-- The horizontal fall line of a surface: the unit direction a body resting on it slides toward.
-- Returns the zero vector for a flat floor (no fall line exists) and for a degenerate normal.
--
-- Extracted so the sign lives in exactly ONE place. It was previously inlined in SignedSlopeAlong
-- with the negation backwards, which inverted every slope decision in the feature; a second caller
-- re-deriving it would have been a second chance to get it wrong the same way. See SignedSlopeAlong
-- below for the two derivations proving the direction.
function ParkourMath.DownhillDirection(normal: Vector3): Vector3
	local unitNormal = ParkourMath.SafeUnit(normal, UP)
	return ParkourMath.SafeUnit(Vector3.new(unitNormal.X, 0, unitNormal.Z), Vector3.zero)
end

-- Signed slope along a direction of travel, in degrees: positive means travelling DOWNHILL,
-- negative means uphill, zero on the flat. This is what lets slide/walk speed respond to terrain
-- with one number instead of a normal plus a separate uphill/downhill boolean.
function ParkourMath.SignedSlopeAlong(normal: Vector3, travelDirection: Vector3): number
	local flatTravel = ParkourMath.Flatten(travelDirection)
	if flatTravel.Magnitude < ZERO_EPSILON then
		return 0
	end
	local unitNormal = ParkourMath.SafeUnit(normal, UP)
	local slope = ParkourMath.SlopeAngle(unitNormal)
	if slope < ZERO_EPSILON then
		return 0
	end
	-- The downhill direction is the surface normal projected onto the horizontal plane, NOT negated: a
	-- normal tilted toward +X belongs to a surface that falls away toward +X, the same way. This was
	-- negated for a long time, which inverted every slope decision in the feature -- you slid UP ramps
	-- and died on the way down -- and the spec agreed with it because it was written from the same
	-- wrong premise. Two independent derivations, so the next reader does not have to re-litigate it,
	-- both using n = (0.5, 1, 0).Unit:
	--   * Points on the plane satisfy n:Dot(p) == 0. At x = 1 that gives y = -0.5; at x = -1, y = 0.5.
	--     Height falls as x rises, so downhill is +X -- the way the normal leans.
	--   * Gravity projected onto the surface, g - (g:Dot(n))n with g = (0, -g, 0), comes out to
	--     (0.4g, -0.2g, 0). The pull is toward +X. Bodies fall downhill, so downhill is +X.
	local downhill = ParkourMath.DownhillDirection(unitNormal)
	if downhill.Magnitude < ZERO_EPSILON then
		return 0
	end
	return slope * math.clamp(flatTravel.Unit:Dot(downhill), -1, 1)
end

-- Multiplier on walking/sprinting target speed for the slope currently being travelled. Uphill
-- costs more than downhill gives (the two per-degree terms are separate parameters), and the result
-- is floored so an extreme slope slows you without ever reversing or freezing you.
function ParkourMath.SlopeSpeedScale(
	signedSlopeDegrees: number,
	uphillPenaltyPerDegree: number,
	downhillBonusPerDegree: number
): number
	local scale = if signedSlopeDegrees >= 0
		then 1 + signedSlopeDegrees * downhillBonusPerDegree
		else 1 + signedSlopeDegrees * uphillPenaltyPerDegree
	return math.clamp(scale, 0.35, 1.6)
end

-- One frame of slide-speed evolution, modelled on the actual physics of a body on an incline rather
-- than on a linear per-degree approximation.
--
--   acceleration = gravity * sin(slope) * slopeGravityFraction   -- the pull along the surface
--                - frictionPerSecond * cos(slope) * surfaceScale -- resistance, scaled by normal force
--
-- Both terms are trigonometric for a reason, and the previous linear-in-degrees version was wrong in
-- the same direction on both, on exactly the slopes players notice. The pull along a slope grows as
-- sin, which accelerates far harder than linear past ~40 degrees; friction grows as cos, so it FALLS
-- AWAY as the slope steepens (less weight pressed into the surface) rather than staying constant. A
-- steep slope therefore compounds -- more pull AND less friction -- which is why a real steep descent
-- runs away from you where the linear model merely trickled.
--
-- `frictionPerSecond` is still expressed as flat-ground deceleration in studs/s^2: at zero slope cos
-- is 1 and this reduces exactly to the previous behavior, so the already-tuned flat-slide feel is
-- preserved unchanged. `slopeGravityFraction` is the single knob for how much of real gravity a slide
-- actually receives -- well under 1, since a sliding body has real drag and full gravity is
-- uncontrollable in a game.
--
-- Uphill multiplies the (already negative) slope term by `uphillScale`, so sliding up a ramp dies
-- quickly. Clamped to `maxSpeed`, which on a steep slope is the ONLY thing bounding the result: as
-- the pull grows the friction shrinks, so there is no natural terminal speed below the cap.
function ParkourMath.IntegrateSlideSpeed(
	currentSpeed: number,
	signedSlopeDegrees: number,
	frictionPerSecond: number,
	slopeGravityFraction: number,
	uphillScale: number,
	surfaceFrictionScale: number,
	gravity: number,
	maxSpeed: number,
	deltaTime: number
): number
	local slopeRadians = math.rad(signedSlopeDegrees)
	local alongSlope = gravity * math.sin(slopeRadians) * slopeGravityFraction
	if signedSlopeDegrees < 0 then
		alongSlope *= uphillScale
	end
	-- Absolute cosine: the normal force does not reverse past vertical, and a slope steep enough to
	-- produce a negative cosine would otherwise turn friction into acceleration.
	local friction = frictionPerSecond * math.abs(math.cos(slopeRadians)) * math.max(surfaceFrictionScale, 0)
	return math.clamp(currentSpeed + (alongSlope - friction) * math.max(deltaTime, 0), 0, maxSpeed)
end

-- The horizontal unit vector along a wall, oriented to agree with the direction the character is
-- already travelling -- a wall has two tangents and picking the wrong one turns a wall-run into an
-- instant reversal. Returns the zero vector when the wall is degenerate (a perfectly horizontal
-- "wall", i.e. a floor or ceiling) or when there is no travel direction to agree with, which every
-- caller treats as "no wall-run available."
function ParkourMath.WallTangent(wallNormal: Vector3, travelDirection: Vector3): Vector3
	local flatNormal = ParkourMath.Flatten(wallNormal)
	if flatNormal.Magnitude < ZERO_EPSILON then
		return Vector3.zero
	end
	local tangent = UP:Cross(flatNormal.Unit)
	if tangent.Magnitude < ZERO_EPSILON then
		return Vector3.zero
	end
	tangent = tangent.Unit
	local flatTravel = ParkourMath.Flatten(travelDirection)
	if flatTravel.Magnitude < ZERO_EPSILON then
		return Vector3.zero
	end
	return if tangent:Dot(flatTravel.Unit) >= 0 then tangent else -tangent
end

-- The horizontal unit vector along a wall, STABLE regardless of which way the character is travelling
-- -- the raw half of the cross product WallTangent above flips by travel agreement. Two different
-- questions want two different answers here: a wall-RUN needs "which way am I already going" (that's
-- WallTangent), where a ledge SHIMMY needs "which way is left and which is right, independent of
-- anything the character happens to be doing this frame" -- a player who reverses direction mid-shimmy
-- must not have left and right swap on them. Same degenerate-input contract as WallTangent (the zero
-- vector for a horizontal "wall", i.e. a floor or ceiling).
function ParkourMath.WallRight(wallNormal: Vector3): Vector3
	local flatNormal = ParkourMath.Flatten(wallNormal)
	if flatNormal.Magnitude < ZERO_EPSILON then
		return Vector3.zero
	end
	local tangent = UP:Cross(flatNormal.Unit)
	if tangent.Magnitude < ZERO_EPSILON then
		return Vector3.zero
	end
	return tangent.Unit
end

-- Angle (degrees, 0-180) between the direction of travel and a wall's tangent. Small means running
-- ALONG the wall (a legal wall-run entry); large means running INTO it (not a wall-run, possibly a
-- vault or a mantle). Returns 180 -- maximally disqualifying -- for a degenerate tangent, so a
-- caller comparing against a max-angle threshold reads the degenerate case as a refusal without
-- needing its own nil check.
function ParkourMath.ApproachAngle(travelDirection: Vector3, tangent: Vector3): number
	local flatTravel = ParkourMath.Flatten(travelDirection)
	if flatTravel.Magnitude < ZERO_EPSILON or tangent.Magnitude < ZERO_EPSILON then
		return 180
	end
	return math.deg(math.acos(math.clamp(flatTravel.Unit:Dot(tangent.Unit), -1, 1)))
end

-- Which side of the character a wall normal is on: -1 for the left, 1 for the right, 0 when it's
-- directly ahead/behind (no meaningful side). Drives wall-run animation/camera-tilt selection.
function ParkourMath.WallSide(facingDirection: Vector3, wallNormal: Vector3): number
	local flatFacing = ParkourMath.Flatten(facingDirection)
	local flatNormal = ParkourMath.Flatten(wallNormal)
	if flatFacing.Magnitude < ZERO_EPSILON or flatNormal.Magnitude < ZERO_EPSILON then
		return 0
	end
	-- The wall's normal points AWAY from the wall, back at the character -- so a wall on the
	-- character's right has a normal pointing left, hence the negation.
	local right = flatFacing.Unit:Cross(UP)
	local dot = right:Dot(flatNormal.Unit)
	if math.abs(dot) < 0.2 then
		return 0
	end
	return if dot < 0 then 1 else -1
end

-- Vertical speed for one frame of a wall-run: a fixed rise for the opening `riseSeconds`, then a
-- decaying descent under a fraction of normal gravity. Two phases rather than a single curve
-- because they say different things -- the rise is the reward for entering cleanly, the sink is the
-- legible warning that the run is expiring, and tuning them independently is the whole point.
function ParkourMath.WallRunVerticalSpeed(
	elapsedSeconds: number,
	currentVerticalSpeed: number,
	riseSeconds: number,
	riseSpeed: number,
	gravityFraction: number,
	gravity: number,
	deltaTime: number
): number
	if elapsedSeconds < riseSeconds then
		-- Ease the rise out across its own window so the transition into the sink phase has no
		-- visible discontinuity.
		local remaining = 1 - math.clamp(elapsedSeconds / math.max(riseSeconds, ZERO_EPSILON), 0, 1)
		return riseSpeed * remaining
	end
	return currentVerticalSpeed - gravity * math.max(gravityFraction, 0) * math.max(deltaTime, 0)
end

-- Composes a wall-jump's departure velocity from its three independent contributions: a push
-- straight out along the wall normal, an upward kick, and a retained fraction of whatever
-- along-wall momentum the character already had. `chainIndex` is how many wall-jumps have happened
-- since the last ground contact (0 for the first) -- each one past the first scales the push and
-- lift by `falloffMultiplier`, so a chain still works but pays diminishing returns rather than
-- letting a player ladder up one corner indefinitely.
function ParkourMath.WallJumpVelocity(
	wallNormal: Vector3,
	travelDirection: Vector3,
	momentum: number,
	pushSpeed: number,
	upSpeed: number,
	forwardRetainFraction: number,
	chainIndex: number,
	falloffMultiplier: number
): Vector3
	local falloff = falloffMultiplier ^ math.max(chainIndex, 0)
	local flatNormal = ParkourMath.Flatten(wallNormal)
	local push = if flatNormal.Magnitude < ZERO_EPSILON then Vector3.zero else flatNormal.Unit * pushSpeed * falloff
	local flatTravel = ParkourMath.Flatten(travelDirection)
	local carry = if flatTravel.Magnitude < ZERO_EPSILON
		then Vector3.zero
		else flatTravel.Unit * momentum * forwardRetainFraction
	return push + carry + Vector3.new(0, upSpeed * falloff, 0)
end

-- THE ASSISTED WALL-JUMP'S TRAJECTORY: the launch velocity that carries a body from `startPosition` to
-- `targetPosition` under gravity, with a deliberate surplus rather than the exact minimum.
--
-- Returns the velocity and whether the target is genuinely REACHABLE within the caps -- a caller that
-- gets false is being handed the best arc available toward the target, not a guarantee of arrival, and
-- may reasonably choose the plain fixed-push jump instead.
--
-- The solve, in the order the numbers depend on each other:
--   1. Pick the vertical speed. It must be at least enough to reach the target's height plus
--      `apexClearance` -- v = sqrt(2*g*h) -- so the arc passes OVER the lip of what is being jumped to
--      rather than into its front face. Floored at `minUpSpeed` so a level or downhill target still
--      leaves the ground like a jump, and capped at `maxUpSpeed`, which is the single number that stops
--      a well-placed pair of walls from being an elevator.
--   2. Solve the flight time from that vertical speed: dy = vy*t - g*t^2/2, a plain quadratic, taking
--      the LATE root -- the descending arrival. The discriminant cannot go negative, because step 1
--      chose vy to clear the height with room to spare. The early root (arriving while still rising) is
--      deliberately not used: it is a much shorter flight, so it demands a far higher horizontal speed
--      for the same distance, and for anything but a near-level target that speed runs straight into the
--      horizontal cap and reports an ordinary jump as unreachable. Arriving on the way DOWN is also what
--      the states downstream want -- States/LedgeHanging refuses a grab from a character still rising
--      faster than Ledge.MaxVerticalSpeedToGrab, so a rising arrival would land the assist's own target
--      in a state that then declines to catch it.
--   3. Horizontal speed is then simply the horizontal distance divided by that time, times
--      `reachMargin` -- the "a little more than enough" surplus. Landing on the mathematical minimum
--      means every frame of error is a miss, and on a chained traversal a miss is the whole chain.
--
-- Pure, and deliberately unaware of walls, characters and Instances: it takes two points and returns a
-- velocity, which is what makes the interesting half of the assist testable without a place file.
function ParkourMath.SolveLaunchVelocity(
	startPosition: Vector3,
	targetPosition: Vector3,
	gravity: number,
	apexClearance: number,
	reachMargin: number,
	minUpSpeed: number,
	maxUpSpeed: number,
	maxPlanarSpeed: number
): (Vector3, boolean)
	local safeGravity = math.max(gravity, ZERO_EPSILON)
	local delta = targetPosition - startPosition
	local rise = delta.Y
	local planar = ParkourMath.Flatten(delta)
	local planarDistance = planar.Magnitude

	local requiredApex = math.max(rise + math.max(apexClearance, 0), 0)
	local requiredUpSpeed = math.sqrt(2 * safeGravity * requiredApex)
	local upSpeed = math.clamp(math.max(requiredUpSpeed, minUpSpeed), math.min(minUpSpeed, maxUpSpeed), maxUpSpeed)

	-- Whether the cap above actually bit. Reported rather than silently swallowed: a target the vertical
	-- cap cannot reach is one the caller should know it is only approaching.
	local verticalReachable = upSpeed >= requiredUpSpeed - ZERO_EPSILON

	local discriminant = upSpeed * upSpeed - 2 * safeGravity * rise
	if discriminant <= 0 then
		-- Only reachable when the vertical cap refused the height outright. There is no flight time to
		-- solve for, so the best available answer is a straight-up-and-along launch at the caps.
		local direction = ParkourMath.SafeUnit(planar, Vector3.zero)
		return direction * math.min(maxPlanarSpeed, planarDistance) + Vector3.new(0, upSpeed, 0), false
	end

	-- The descending arrival -- see step 2 in the header for why the rising one is not an option.
	-- Always positive: the root exceeds upSpeed whenever `rise` is negative, and is smaller than it
	-- whenever `rise` is positive, so the sum is positive either way.
	local flightTime = (upSpeed + math.sqrt(discriminant)) / safeGravity
	local planarSpeed = (planarDistance / math.max(flightTime, ZERO_EPSILON)) * math.max(reachMargin, 1)
	local clampedPlanarSpeed = math.min(planarSpeed, maxPlanarSpeed)
	local direction = ParkourMath.SafeUnit(planar, Vector3.zero)
	local reachable = verticalReachable and clampedPlanarSpeed >= planarSpeed - ZERO_EPSILON

	return direction * clampedPlanarSpeed + Vector3.new(0, upSpeed, 0), reachable
end

-- THE CHIMNEY CLIMB'S HEIGHT BUDGET: how far ABOVE the launch a wall-jump across a corridor should aim,
-- given the gap it has to cross.
--
-- Why this is a separate question from SolveLaunchVelocity rather than a target handed to it: between
-- two facing walls there IS no target position to aim at. The opposite wall is a whole vertical face,
-- every point of which is a legal place to arrive, and the interesting question is not "how do I get to
-- that point" but "how high up that face can I get." Aiming level -- which is what a scan for a
-- concrete target produces, since a ray finds the face at the height it was cast from -- is what makes
-- a chimney climb impossible: every kick crosses the gap and gains almost nothing, and the player
-- ping-pongs sideways between two walls forever.
--
-- The answer is the APEX ARRIVAL. Spend everything on lift, and buy exactly enough horizontal speed to
-- be touching the far wall at the moment the climb runs out -- so the highest point of the arc and the
-- contact with the next wall are the same event. It is optimal (nothing is spent on horizontal speed
-- beyond what the crossing costs), and it arrives with near-zero vertical speed, which is what lets the
-- top of a climb become a ledge grab: States/LedgeHanging refuses a character still rising faster than
-- Ledge.MaxVerticalSpeedToGrab, so an arc that arrived still climbing would sail past the lip it was
-- trying to catch.
--
-- The apex gain is upSpeed^2 / 2g, and reaching the far wall at that moment costs gap*g/upSpeed of
-- horizontal speed -- INVERSELY proportional to lift, which is the part that is easy to get backwards:
-- a higher kick is a shorter flight, so a wide gap needs MORE lift to cross at apex, not less. When
-- that horizontal cost exceeds what the caps allow, the arc has to last longer than a rise-to-apex, so
-- the aim drops below the apex and the arrival happens on the way down. That is the case this function
-- solves for in closed form, from the flight time the horizontal cap implies.
function ParkourMath.CorridorKickHeight(
	gapDistance: number,
	gravity: number,
	upSpeed: number,
	maxPlanarSpeed: number,
	reachMargin: number
): number
	local safeGravity = math.max(gravity, ZERO_EPSILON)
	local apexGain = (upSpeed * upSpeed) / (2 * safeGravity)
	if maxPlanarSpeed <= ZERO_EPSILON or gapDistance <= ZERO_EPSILON then
		return apexGain
	end

	-- The shortest flight the horizontal cap can cross this gap in.
	local requiredFlightTime = (gapDistance * math.max(reachMargin, 1)) / maxPlanarSpeed
	-- How much longer than a straight rise-to-apex that is. Non-positive means the cap is not binding at
	-- all and the full apex arrival is affordable.
	local excess = safeGravity * requiredFlightTime - upSpeed
	if excess <= 0 then
		return apexGain
	end

	-- Flight time as a function of aim height h is (v + sqrt(v^2 - 2gh))/g, so requiring it to be at
	-- least requiredFlightTime rearranges to h <= (v^2 - excess^2) / 2g. Below zero means even a level
	-- crossing is past the horizontal cap -- the gap is simply too wide to jump -- and the caller reads
	-- the zero as "no climb available here."
	return math.clamp((upSpeed * upSpeed - excess * excess) / (2 * safeGravity), 0, apexGain)
end

-- How good a wall-jump target a candidate surface is, from 0 (unusable) upward. Three independent
-- questions, weighted rather than gated, because a target that wins on one and loses on another is a
-- real and common situation and a chain of hard gates would simply refuse both:
--   * ALIGNMENT  -- does it lie in the direction the player is asking to go? The dominant term. This is
--                   what makes the assist feel like it read the player's intent rather than like it
--                   picked for them.
--   * PROXIMITY  -- of two equally-aimed surfaces, prefer the nearer. The nearer one is the one the
--                   player can see themselves reaching, and a chain of short hops is more controllable
--                   than one long committed flight.
--   * SQUARENESS -- is the surface's face turned toward the character? A face angled away can be flown
--                   at but not USED: the arrival glances off instead of becoming the next wall-run.
--
-- Returns 0 for anything outside the distance band or under either minimum, so a caller can simply take
-- the highest score above zero.
function ParkourMath.WallJumpCandidateScore(
	fromPosition: Vector3,
	aimDirection: Vector3,
	candidatePosition: Vector3,
	candidateNormal: Vector3,
	minDistance: number,
	maxDistance: number,
	alignmentWeight: number,
	proximityWeight: number,
	squarenessWeight: number,
	minAlignmentDot: number,
	minSquarenessDot: number
): number
	local toCandidate = candidatePosition - fromPosition
	local distance = toCandidate.Magnitude
	if distance < minDistance or distance > maxDistance or maxDistance <= minDistance then
		return 0
	end

	local aim = ParkourMath.SafeUnit(ParkourMath.Flatten(aimDirection), Vector3.zero)
	local towardPlanar = ParkourMath.SafeUnit(ParkourMath.Flatten(toCandidate), Vector3.zero)
	if aim.Magnitude < ZERO_EPSILON or towardPlanar.Magnitude < ZERO_EPSILON then
		return 0
	end

	local alignment = aim:Dot(towardPlanar)
	if alignment < minAlignmentDot then
		return 0
	end

	-- The face has to look back at us. Measured against the direction of travel toward it rather than
	-- against the aim direction, because those diverge for an off-axis candidate and it is the ARRIVAL
	-- that has to be square, not the intent.
	local normal = ParkourMath.SafeUnit(ParkourMath.Flatten(candidateNormal), Vector3.zero)
	if normal.Magnitude < ZERO_EPSILON then
		return 0
	end
	local squareness = normal:Dot(-towardPlanar)
	if squareness < minSquarenessDot then
		return 0
	end

	local proximity = 1 - (distance - minDistance) / (maxDistance - minDistance)
	return alignment * alignmentWeight + proximity * proximityWeight + squareness * squarenessWeight
end

-- How severe a landing is, from the height fallen. Three bands rather than a continuous curve
-- because each band has a genuinely different CONSEQUENCE (nothing / a cosmetic beat / a real
-- recovery window), and a threshold the design can point at is easier to tune than a formula.
function ParkourMath.ClassifyLanding(
	fallHeight: number,
	softMaxHeight: number,
	mediumMaxHeight: number
): "Soft" | "Medium" | "Hard"
	if fallHeight <= softMaxHeight then
		return "Soft"
	end
	if fallHeight <= mediumMaxHeight then
		return "Medium"
	end
	return "Hard"
end

-- Steers an existing direction toward a desired one at a bounded angular rate -- mid-air turning.
-- Rate-limited rather than lerped so the turn is predictable regardless of how far apart the two
-- directions are: a 180-degree reversal takes exactly twice as long as a 90-degree one, which is
-- what makes air control learnable. Returns `current` unchanged when either vector is degenerate.
function ParkourMath.SteerDirection(
	currentDirection: Vector3,
	desiredDirection: Vector3,
	maxTurnDegreesPerSecond: number,
	deltaTime: number
): Vector3
	local current = ParkourMath.Flatten(currentDirection)
	local desired = ParkourMath.Flatten(desiredDirection)
	if current.Magnitude < ZERO_EPSILON then
		return if desired.Magnitude < ZERO_EPSILON then currentDirection else desired.Unit
	end
	if desired.Magnitude < ZERO_EPSILON then
		return current.Unit
	end
	current = current.Unit
	desired = desired.Unit

	local angle = math.deg(math.acos(math.clamp(current:Dot(desired), -1, 1)))
	local maxStep = math.max(maxTurnDegreesPerSecond, 0) * math.max(deltaTime, 0)
	if angle <= maxStep or angle < ZERO_EPSILON then
		return desired
	end

	-- Rotate `current` toward `desired` by exactly maxStep degrees, around the axis separating them.
	-- Falls back to the world up axis for the exact-180 case, where the cross product is degenerate
	-- and any axis is equally correct.
	local axis = current:Cross(desired)
	if axis.Magnitude < ZERO_EPSILON then
		axis = UP
	end
	local rotated = CFrame.fromAxisAngle(axis.Unit, math.rad(maxStep)) * current
	return ParkourMath.SafeUnit(ParkourMath.Flatten(rotated), desired)
end

-- Coyote time: whether a ground jump is still legal this many seconds after leaving the ground.
-- `enabled` is the player's own assist preference -- passed in rather than checked by the caller so
-- there is exactly one place the assist can be switched off, and the disabled path is impossible to
-- forget.
function ParkourMath.CoyoteAvailable(
	now: number,
	leftGroundAt: number,
	windowSeconds: number,
	enabled: boolean
): boolean
	if not enabled then
		return false
	end
	return leftGroundAt > 0 and (now - leftGroundAt) <= windowSeconds
end

-- Input buffering: whether an input pressed at `pressedAt` is still live. Same `enabled`-as-a-
-- parameter contract as CoyoteAvailable above, for the same reason. A `pressedAt` of 0 (never
-- pressed) is never live regardless of window.
function ParkourMath.BufferLive(now: number, pressedAt: number, windowSeconds: number, enabled: boolean): boolean
	if not enabled or pressedAt <= 0 then
		return false
	end
	return (now - pressedAt) <= windowSeconds
end

-- Animation playback rate scaled to actual speed, clamped so a very slow or very fast state never
-- produces a clip playing at an absurd rate. Reference speed is the speed the clip was authored at.
function ParkourMath.PlaybackSpeed(
	currentSpeed: number,
	referenceSpeed: number,
	minSpeed: number,
	maxSpeed: number
): number
	if referenceSpeed <= ZERO_EPSILON then
		return 1
	end
	return math.clamp(currentSpeed / referenceSpeed, minSpeed, maxSpeed)
end

-- Seconds between footfalls at a given speed -- the run system's step cadence (Client/Movement/
-- RunController.lua, tuned by Constants.Run.Footsteps).
--
-- The authored interval is the cadence the stage was written FOR, at referenceSpeed; the live
-- interval scales inversely with actual speed, so a player slowed to a crawl by hit-slow or a steep
-- climb takes slower steps and one riding a downhill momentum carry takes faster ones. Inverse
-- rather than PlaybackSpeed's ratio above because these are opposite quantities: a clip plays FASTER
-- at speed (bigger multiplier), while the gap BETWEEN steps gets shorter (smaller interval).
--
-- Clamped at both ends, and both bounds are load-bearing rather than defensive: without the floor a
-- momentum-carry burst turns the cadence into a buzz, and without the ceiling a near-stationary
-- player takes one step every several seconds, which reads as broken audio rather than as slow
-- walking. A non-positive speed or reference speed returns the ceiling, which is the honest answer
-- for "not moving" and never a division by zero.
function ParkourMath.StepInterval(
	currentSpeed: number,
	referenceSpeed: number,
	authoredInterval: number,
	minInterval: number,
	maxInterval: number
): number
	if currentSpeed <= ZERO_EPSILON or referenceSpeed <= ZERO_EPSILON then
		return maxInterval
	end
	return math.clamp(authoredInterval * (referenceSpeed / currentSpeed), minInterval, maxInterval)
end

-- Momentum handed from one state to the next: a retained fraction of what came in, floored so no
-- traversal ever dumps the player into a dead stop, and never above the incoming momentum unless
-- the caller's own fraction says so (a slide-jump legitimately retains more than 1).
function ParkourMath.ExitMomentum(entryMomentum: number, retainFraction: number, minimumSpeed: number): number
	return math.max(entryMomentum * math.max(retainFraction, 0), minimumSpeed)
end

-- Position along a traversal path (vault/mantle/ledge climb) at progress `alpha` in [0, 1]. A
-- quadratic Bezier through a single control point, which is what gives a vault its arc over the
-- obstacle instead of a straight-line slide through it -- the control point is placed above the
-- obstacle's top edge by the caller.
function ParkourMath.TraversalPoint(
	startPosition: Vector3,
	controlPoint: Vector3,
	endPosition: Vector3,
	alpha: number
): Vector3
	local t = math.clamp(alpha, 0, 1)
	local inverse = 1 - t
	return startPosition * (inverse * inverse) + controlPoint * (2 * inverse * t) + endPosition * (t * t)
end

-- Smoothstep-shaped progress for a traversal, so a vault eases in and out rather than starting and
-- stopping at full speed. Separate from TraversalPoint so the two can be tuned/tested apart.
function ParkourMath.TraversalEase(alpha: number): number
	local t = math.clamp(alpha, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Cubic ease-OUT: fastest at the start, settling at the end. Its own function rather than a second
-- caller of TraversalEase above because the two describe opposite events and the difference is
-- legible in play. A vault is a LAUNCH -- symmetric smoothstep, easing in, because a launch that
-- begins at full speed reads as being shoved. A ledge grab is a CATCH: the hands arrive at the lip
-- the instant contact is made and the body settles underneath them, and easing INTO that reads as a
-- hesitation before the character decides to grab. Used by States/LedgeHanging.lua for the pull into
-- the hang pose.
function ParkourMath.EaseOutCubic(alpha: number): number
	local inverse = 1 - math.clamp(alpha, 0, 1)
	return 1 - inverse * inverse * inverse
end

-- Re-exported so the parkour modules have one import for their easing needs rather than requiring
-- FlightMath directly alongside this module -- see the file header for why the implementation
-- itself is not duplicated.
function ParkourMath.EaseAlpha(ratePerSecond: number, deltaTime: number): number
	return FlightMath.EaseAlpha(ratePerSecond, deltaTime)
end

-- The direction an AUTOMATIC, no-button probe is allowed to reach in: genuine measured movement first,
-- a held direction second, and -- deliberately -- nothing beyond that. Every other direction fallback
-- chain in this framework (StateSupport.TravelDirection, EnvironmentProbe's own obstacle/wall probes)
-- ends at facing, and rightly so: those only matter once the player has already committed to something,
-- either by moving or by being about to enter a state through their own input. A ledge grab is
-- Committed the instant CanEnter agrees, with no input at all, so letting IT fall back to "wherever the
-- camera happens to be pointed" turns a pure vertical fall next to a wall the player is merely looking
-- at into an unrequested grab. Returns the zero vector when neither signal is present, which every
-- caller treats as "nothing to reach for right now."
function ParkourMath.PrimaryReachDirection(moveDirection: Vector3, moveIntent: Vector3): Vector3
	local travel = ParkourMath.SafeUnit(ParkourMath.Flatten(moveDirection), Vector3.zero)
	if travel.Magnitude > 0 then
		return travel
	end
	return ParkourMath.SafeUnit(ParkourMath.Flatten(moveIntent), Vector3.zero)
end

return ParkourMath
