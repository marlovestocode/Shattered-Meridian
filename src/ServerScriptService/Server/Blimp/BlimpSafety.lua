--!strict
--[[
	BlimpSafety.lua

	Owns: the arithmetic behind "something touching this hull must not leave faster than this" --
	the pure half of the fix for a player who gains speed by holding a movement key into a Blimp
	hull. Server/Systems/BlimpSystem.lua owns the other half: which parts make up a hull
	(BlimpAssembly.Build's HullParts), which players are currently touching one (Touched/TouchEnded
	wiring in registerBlimp), and when to apply this to a live character (onHeartbeatTick).

	TOUCHES NO INSTANCE, for the same reason Server/Blimp/BlimpDrive.lua does not: ClampSpeed is
	arithmetic on a Vector3, not a read of a live body, which is what makes "does the clamp preserve
	direction, does it leave an already-legal velocity untouched" answerable in the TestEZ suite
	without a physics-live place.

	WHY THIS EXISTS SEPARATELY FROM BlimpDrive.ClampLead AND BlimpConstants.Physics.MaxDriveVelocity:
	those two bound the HULL's own behaviour -- how far its chase target may lead its actual
	position, and how fast its own AlignPosition constraint may move it. Neither touches a PLAYER's
	velocity at all, because a character standing on the deck or pressed against a wall panel is a
	SEPARATE physics body, joined to the hull only by ordinary collision, never by either constraint.
	Roblox's own collision solver can inject velocity into a character that keeps re-asserting
	movement input into a body driven by a strong, unanchored constraint (this hull, under up to 14x
	its own weight of force -- see BlimpConstants.Physics.ForceGravityMultiple) for as long as contact
	is sustained -- a well-documented behaviour around AlignPosition/BodyMover-driven parts generally,
	not a bug anywhere in this codebase's own movement code. ClampSpeed is the backstop for THAT: it
	does not try to prevent the push, it only stops the pushed body from leaving faster than any
	legitimate player velocity plausibly is -- see BlimpConstants.Safety.MaxContactSpeed's own header
	for where that ceiling comes from.

	Does not own: WHO counts as touching the hull or WHEN to apply this (both Server/Systems/
	BlimpSystem.lua), or the hull's own speed (BlimpDrive.lua / BlimpConstants.Physics).
]]

local BlimpSafety = {}

-- Bounds `velocity`'s MAGNITUDE to `maxSpeed`, preserving direction exactly -- scaled down, never
-- zeroed, so a clamp reads as hitting an invisible speed limiter rather than a dead stop. A hard
-- zero would also be a worse anti-exploit measure, not just a worse feel: it would erase legitimate
-- momentum a player was carrying (a dash that happened to graze the hull) rather than just trimming
-- the implausible excess, which is the one thing this function actually needs to defend against.
--
-- Returns `velocity` UNCHANGED (the same value, not an equal copy) when it is already within the
-- bound, which is every legitimate tick -- the caller relies on that to know whether it has
-- anything to write back onto a live character's AssemblyLinearVelocity at all.
function BlimpSafety.ClampSpeed(velocity: Vector3, maxSpeed: number): Vector3
	local speed = velocity.Magnitude
	if speed <= maxSpeed then
		return velocity
	end
	-- speed > maxSpeed >= 0 here (maxSpeed is always non-negative in every real caller), so
	-- `velocity` cannot be the zero vector and dividing by `speed` is safe.
	return (velocity / speed) * maxSpeed
end

return BlimpSafety
