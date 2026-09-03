--!strict
--[[
	VesselSafety.lua

	Owns: the arithmetic behind "something touching this hull must not leave faster than this" -- the
	pure half of the fix for a player who gains speed by holding a movement key into a driven hull. Each
	vehicle's own System owns the other half: which parts make up a hull, which players are currently
	touching one (Touched/TouchEnded wiring at registration), and when to apply this to a live character
	(its Heartbeat tick).

	LIFTED OUT OF Server/Blimp/BlimpSafety.lua when the Boat layer arrived, and MOVED FROM Server/ TO
	Shared/ in the same step. That move is not incidental: the file was under Server/ only because its
	one caller was, and it touches nothing a client may not see. Everything else in Shared/Vessel is
	read by both sides, and a lone server-side member of the same layer is a thing every future reader
	has to work out the reason for. There is no reason; it is arithmetic on a Vector3.

	TOUCHES NO INSTANCE, for the same reason a Drive module does not: ClampSpeed is arithmetic on a
	Vector3, not a read of a live body, which is what makes "does the clamp preserve direction, does it
	leave an already-legal velocity untouched" answerable in the TestEZ suite without a physics-live
	place.

	WHY THIS EXISTS SEPARATELY FROM A DRIVE'S OWN ClampLead AND ITS MaxDriveVelocity: those two bound
	the HULL's own behaviour -- how far its chase target may lead its actual position, and how fast its
	own AlignPosition constraint may move it. Neither touches a PLAYER's velocity at all, because a
	character standing on the deck or pressed against a wall panel is a SEPARATE physics body, joined to
	the hull only by ordinary collision, never by either constraint. Roblox's own collision solver can
	inject velocity into a character that keeps re-asserting movement input into a body driven by a
	strong, unanchored constraint (a hull under many times its own weight of force) for as long as
	contact is sustained -- a well-documented behaviour around AlignPosition/BodyMover-driven parts
	generally, not a bug anywhere in this codebase's own movement code. ClampSpeed is the backstop for
	THAT: it does not try to prevent the push, it only stops the pushed body from leaving faster than
	any legitimate player velocity plausibly is.

	Does not own: WHO counts as touching the hull or WHEN to apply this (each vehicle's System), the
	ceiling itself (each vehicle's Constants.Safety), or the hull's own speed.
]]

local VesselSafety = {}

-- Bounds `velocity`'s MAGNITUDE to `maxSpeed`, preserving direction exactly -- scaled down, never
-- zeroed, so a clamp reads as hitting an invisible speed limiter rather than a dead stop. A hard zero
-- would also be a worse anti-exploit measure, not just a worse feel: it would erase legitimate momentum
-- a player was carrying (a dash that happened to graze the hull) rather than just trimming the
-- implausible excess, which is the one thing this function actually needs to defend against.
--
-- Returns `velocity` UNCHANGED (the same value, not an equal copy) when it is already within the bound,
-- which is every legitimate tick -- the caller relies on that to know whether it has anything to write
-- back onto a live character's AssemblyLinearVelocity at all.
function VesselSafety.ClampSpeed(velocity: Vector3, maxSpeed: number): Vector3
	local speed = velocity.Magnitude
	if speed <= maxSpeed then
		return velocity
	end
	-- speed > maxSpeed >= 0 here (maxSpeed is always non-negative in every real caller), so `velocity`
	-- cannot be the zero vector and dividing by `speed` is safe.
	return (velocity / speed) * maxSpeed
end

return VesselSafety
