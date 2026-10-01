--!strict
--[[
	DomainConstants.lua

	Owns: the domain runtime's tuning -- how often membership is re-evaluated, how many realms may be live,
	how the boundary is enforced, the network surface, and the debug switches. Nothing authorable lives
	here: every per-domain number is in the domain's own block (DomainTypes), bounded by DomainTypes.Limits.

	Does not own: the schema (DomainTypes), the attribute names (AttributeConstants), or what a domain does.
]]

local DomainConstants = {
	-- MEMBERSHIP IS SAMPLED, NOT PER FRAME. Who is inside, the rules they carry, clash detection, boundary
	-- enforcement and Qi upkeep all run at this rate on DomainSystem's one Heartbeat -- effect pulses are
	-- checked every frame against their own deadlines, so a 0.25s interval still fires on time. 10Hz is
	-- far finer than any rule needs (a slow that starts 0.1s late is invisible) and keeps the membership
	-- pass a fixed, small cost: live realms x registered combatants, a distance test each.
	MembershipHz = 10,

	-- QI UPKEEP IS SETTLED IN CHUNKS, not on every membership tick (2026-09-30). A realm's upkeep accrues at
	-- UpkeepQiPerSecond on the 10Hz pass, but is SPENT once this many seconds of it have built up. Every
	-- QiSystem.Spend is a whole chain -- a QiSpent event into Qi Deviation (a profile copy, a Transform, a
	-- character-sheet rebuild and push), a Qi push to the client, and the client's handlers for both -- and
	-- ten of those a second, for as long as a realm held, was a ~60ms server burst every 100ms in the
	-- profile that found it. The total drained is unchanged; only how often it is booked. A realm whose
	-- owner cannot cover the next chunk collapses as it always did, up to one chunk's worth sooner.
	UpkeepChunkSeconds = 1,

	-- Hard ceiling on concurrent realms server-wide. A realm is an ultimate on a long cooldown, so this is
	-- a runaway guard (a bot loop, an admin test), never a gameplay limit anyone should meet.
	MaxLiveDomains = 8,

	-- BOUNDARY ENFORCEMENT, for a Barred edge. A body on the wrong side is set back this far inside (or
	-- outside) the line, so the next sample does not see it straddling the edge and correct it again.
	ContainmentMarginStuds = 1.5,
	-- How far past the line a body may be before the server corrects it. The owning client predicts the
	-- same wall (Client/FX/DomainFX.lua) and never gets this far on an honest connection; this slack is for
	-- the ones that do, so a single late packet is not a teleport.
	ContainmentToleranceStuds = 2.5,
	-- A corrected player is stamped Attributes.KnockbackUntil this far ahead, the allowance the knockback
	-- path already grants an honest displacement, so ParkourSystem does not count a boundary correction
	-- toward its cheater flag.
	ContainmentAllowanceSeconds = 0.6,

	-- The physical wall BoundaryCollision raises: vertical segments around a Sphere/Cylinder (a Sphere is
	-- walled as the cylinder that circumscribes it), four walls for a Box.
	Wall = {
		Segments = 24,
		ThicknessStuds = 2,
		FolderName = "DomainBoundaries",
	},

	-- A strike's shot is homing on exactly one body; these are the engine-facing numbers that make it land.
	Strike = {
		-- Degrees per second. High enough to track a dodging body from any origin inside the realm.
		HomingStrength = 1080,
		-- Extra lifetime past the authored travel, so a strike whose target sidestepped still arrives.
		LifetimeSlackSeconds = 0.6,
		-- MaxRange is this multiple of the origin distance.
		RangeMultiplier = 3,
		-- THE SHOT BUDGET, per realm, across all of its Strike and Volley effects (2026-09-30: an authored
		-- realm at the schema's own ceilings -- MaxPerPulse 32, a 0.25s interval, a Volley whose move fires
		-- 32 shots -- is thousands of shots a second, every one of them sent to every client in the server
		-- and drawn by each). A token bucket: a realm holds up to BurstShots, refilled at MaxShotsPerSecond,
		-- and a pulse with less than one shot in hand is skipped. Targets are taken nearest-first, so a
		-- pulse the budget cuts short spares the farthest bodies. A Volley may overdraw by the rest of its
		-- own volley; the debt is paid out of the next pulses, so the average rate still holds.
		MaxShotsPerSecond = 12,
		BurstShots = 16,
	},

	-- Where an "Above" origin is measured from: the target's root, plus OriginDistance straight up.
	-- A "Ring" origin is OriginDistance out from the target at this height.
	RingHeightStuds = 3,

	-- The longest stun one Hitstun pulse may hand out, whatever its Magnitude says: past this a realm is a
	-- lockdown, not a pressure, and "legible danger, real agency" stops holding. The editor's range too.
	MaxHitstunSeconds = 1.5,

	-- Pull/Push: a server-owned body is set to this velocity; a player's own client is handed it as a
	-- knockback push (Client/Combat/KnockbackClient.Push), the same owner split DamageSystem uses.
	ImpulseMaxSpeed = 120,

	Network = {
		RemoteNames = {
			-- Server -> clients: Open / Phase / Clash / Snapshot messages, and a player's own Impulse.
			State = "Domain_State",
			-- Client -> server: "send me every live realm" (a client's first ask, at start).
			Request = "Domain_Request",
		},
		MaxRequestsPerSecond = 2,
	},

	Debug = {
		Enabled = false,
		LogLifecycle = true,
		LogClashes = true,
	},
}

return DomainConstants
