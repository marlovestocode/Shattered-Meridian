--!strict
--[[
	DomainInstance.lua

	Owns: one live realm's RECORD and its LIFECYCLE -- the phase machine, the clock it runs on, where its
	boundary is, and the bookkeeping DomainSystem keeps per realm (members, effect timers, clash state).
	Pure apart from reading its owner's root for a FollowOwner centre: no services, no remotes, no Heartbeat,
	so the whole lifecycle is a spec driven on a synthetic clock.

	THE LIFECYCLE, and it is a strict line -- nothing ever goes backwards:

	    Idle --Begin--> Activating --(ActivationSeconds)--> Active --(ActiveSeconds)--> Ending
	                                                                                      |
	                                                  Finished <--(EndSeconds)------------+

	  * Idle        constructed, not yet opened. The only state DomainSystem never holds a realm in for
	                longer than the call that creates it; it exists so "a realm that was never begun" is a
	                real, inspectable state rather than a nil.
	  * Activating  the owner's swing is unfurling the realm. The boundary exists (clients draw it growing)
	                but nobody is a member, no rule holds and no effect fires. The owner is exposed: a
	                CancelOnOwnerHit realm collapses if they are struck now.
	  * Active      established. Members, rules, effects, clashes, the boundary's enforcement.
	  * Ending      folding away. Rules and effects stopped the instant this began; only the visual remains.
	  * Finished    gone. DomainSystem cleans the record up on the frame it gets here.

	PHASES END AT THEIR SCHEDULED TIME, NOT THE FRAME THAT NOTICED. Advance steps the machine through every
	boundary `now` has passed, each new phase starting at the previous one's scheduled end -- so a hitched
	frame does not stretch a realm, and a 60s realm is 60s on any server. Collapse is the one early exit,
	and it goes to Ending (or straight to Finished for a realm that never became Active), never skipping the
	fold a player needs to see to know the law has lifted.

	EROSION (a clash's Erode, DomainClash) shortens only the Active phase's scheduled end, and never below
	`now`: a realm worn away still ends through Ending like any other.

	Does not own: deciding when to collapse (DomainSystem), who is a member (DomainSystem fills Members), or
	what anything does to a body.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DomainGeometry = require(ReplicatedStorage.Shared.Domain.DomainGeometry)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)

local DomainInstance = {}

export type Phase = "Idle" | "Activating" | "Active" | "Ending" | "Finished"

export type Transition = {
	From: Phase,
	To: Phase,
	-- The scheduled moment it happened, on the instance's clock (not necessarily the frame's `now`).
	At: number,
	-- Set for a Collapse-driven transition: why.
	Reason: string?,
}

-- One body's standing in this realm.
export type Member = {
	-- When it was admitted, on the instance's clock.
	EnteredAt: number,
	-- Admitted when the realm was established (no entry grace), rather than walking in later.
	Founding: boolean,
	-- Set once it has stepped outside (an Open exit): it keeps the realm's rules until then, and no effect
	-- targets it. nil while inside.
	LingerUntil: number?,
}

export type ClashState = "None" | "Dominant" | "Suppressed" | "Eroding" | "Contested"

export type DomainInstance = {
	Id: string,
	Owner: Model,
	MoveId: string,
	Spec: DomainTypes.DomainSpec,

	Phase: Phase,
	-- Instance clock (the caller's; DomainSystem runs it on os.clock like every combat layer).
	OpenedAt: number,
	PhaseStartedAt: number,
	-- When the current phase is scheduled to end. math.huge while Idle and once Finished.
	PhaseEndsAt: number,
	CollapseReason: string?,

	-- The boundary. Center moves with the owner for a FollowOwner anchor (Offset stays fixed in world
	-- space from the moment the realm opened); Yaw is fixed at open.
	Center: Vector3,
	Offset: Vector3,
	Yaw: number,

	Members: { [Model]: Member },
	MemberCount: number,
	-- Bodies that were inside when the realm was established but past MaxTargets: never governed, and never
	-- repelled by a Barred entry (they did not walk in; they were already there).
	Present: { [Model]: boolean },
	-- Per effect index: when it next fires, on the instance clock.
	EffectNextAt: { number },

	ClashState: ClashState,
	-- Other realms this one currently overlaps, by id.
	ClashingWith: { [string]: boolean },
	-- Seconds of Active time erosion has taken, for reporting.
	Eroded: number,
}

local PHASE_ORDER: { [Phase]: Phase? } = {
	Idle = "Activating",
	Activating = "Active",
	Active = "Ending",
	Ending = "Finished",
	Finished = nil,
}

local function durationOf(spec: DomainTypes.DomainSpec, phase: Phase): number
	if phase == "Activating" then
		return spec.ActivationSeconds
	elseif phase == "Active" then
		return spec.ActiveSeconds
	elseif phase == "Ending" then
		return spec.EndSeconds
	end
	return math.huge
end

export type NewArgs = {
	Id: string,
	Owner: Model,
	MoveId: string,
	Spec: DomainTypes.DomainSpec,
	-- The owner's root CFrame at the moment of casting: the centre is CenterForward along its facing.
	OwnerPose: CFrame,
}

function DomainInstance.new(args: NewArgs): DomainInstance
	local spec = args.Spec
	local look = args.OwnerPose.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	local forward = if flat.Magnitude > 1e-4 then flat.Unit else Vector3.new(0, 0, -1)
	local offset = forward * spec.CenterForward
	local instance: DomainInstance = {
		Id = args.Id,
		Owner = args.Owner,
		MoveId = args.MoveId,
		Spec = spec,

		Phase = "Idle",
		OpenedAt = 0,
		PhaseStartedAt = 0,
		PhaseEndsAt = math.huge,
		CollapseReason = nil,

		Center = args.OwnerPose.Position + offset,
		Offset = offset,
		-- The yaw a Box's faces are square to: the owner's facing, so a box realm opens "in front of" them.
		Yaw = math.atan2(-forward.X, -forward.Z),

		Members = {},
		MemberCount = 0,
		Present = {},
		EffectNextAt = {},

		ClashState = "None",
		ClashingWith = {},
		Eroded = 0,
	}
	return instance
end

local function enter(instance: DomainInstance, phase: Phase, at: number): ()
	instance.Phase = phase
	instance.PhaseStartedAt = at
	instance.PhaseEndsAt = if phase == "Finished" then math.huge else at + durationOf(instance.Spec, phase)
end

-- Idle -> Activating. Returns the transition, or nil if the realm was already begun.
function DomainInstance.Begin(instance: DomainInstance, now: number): Transition?
	if instance.Phase ~= "Idle" then
		return nil
	end
	instance.OpenedAt = now
	enter(instance, "Activating", now)
	return { From = "Idle", To = "Activating", At = now }
end

-- Steps through every phase boundary `now` has passed. Returns the transitions in order (usually none,
-- occasionally one, several only after a long hitch or a zero-length phase).
function DomainInstance.Advance(instance: DomainInstance, now: number): { Transition }
	local transitions: { Transition } = {}
	-- Bounded: four real phases, so a runaway can never spin here.
	for _ = 1, 4 do
		if instance.Phase == "Idle" or instance.Phase == "Finished" or now < instance.PhaseEndsAt then
			break
		end
		local from = instance.Phase
		local to = PHASE_ORDER[from] :: Phase
		local at = instance.PhaseEndsAt
		enter(instance, to, at)
		table.insert(transitions, { From = from, To = to, At = at })
	end
	return transitions
end

-- Ends the realm early. An Active realm goes to Ending now; an Activating one -- which never established a
-- law to lift -- goes to Ending as well, so its half-unfurled boundary folds visibly rather than blinking
-- out. Idle goes straight to Finished. Returns the transition, or nil if it was already ending.
function DomainInstance.Collapse(instance: DomainInstance, now: number, reason: string): Transition?
	local from = instance.Phase
	if from == "Ending" or from == "Finished" then
		return nil
	end
	instance.CollapseReason = reason
	if from == "Idle" then
		enter(instance, "Finished", now)
		return { From = from, To = "Finished", At = now, Reason = reason }
	end
	enter(instance, "Ending", now)
	return { From = from, To = "Ending", At = now, Reason = reason }
end

-- Takes `seconds` off the Active phase's remaining time (a clash's Erode). Never past `now`.
function DomainInstance.Erode(instance: DomainInstance, seconds: number, now: number): ()
	if instance.Phase ~= "Active" or seconds <= 0 then
		return
	end
	local before = instance.PhaseEndsAt
	instance.PhaseEndsAt = math.max(before - seconds, now)
	instance.Eroded += before - instance.PhaseEndsAt
end

-- When the realm's law lifts, on the instance clock: the Active phase's end while Activating/Active, or
-- `now` once it has already lifted. What a member's rule lease is stamped with.
function DomainInstance.LawEndsAt(instance: DomainInstance, now: number): number
	if instance.Phase == "Activating" then
		return instance.PhaseEndsAt + instance.Spec.ActiveSeconds
	elseif instance.Phase == "Active" then
		return instance.PhaseEndsAt
	end
	return now
end

-- When the whole realm is gone (the end of Ending), on the instance clock -- the owner's one-realm lease.
function DomainInstance.GoneAt(instance: DomainInstance, now: number): number
	local phase = instance.Phase
	if phase == "Activating" then
		return instance.PhaseEndsAt + instance.Spec.ActiveSeconds + instance.Spec.EndSeconds
	elseif phase == "Active" then
		return instance.PhaseEndsAt + instance.Spec.EndSeconds
	elseif phase == "Ending" then
		return instance.PhaseEndsAt
	end
	return now
end

function DomainInstance.IsLive(instance: DomainInstance): boolean
	return instance.Phase == "Activating" or instance.Phase == "Active"
end

-- Recentres a FollowOwner realm on its owner. A Fixed realm, or an owner with no root, is left where it is.
function DomainInstance.Follow(instance: DomainInstance, ownerRoot: BasePart?): ()
	if instance.Spec.Anchor ~= "FollowOwner" or ownerRoot == nil then
		return
	end
	instance.Center = ownerRoot.Position + instance.Offset
end

function DomainInstance.Boundary(instance: DomainInstance): DomainGeometry.Boundary
	local spec = instance.Spec
	return {
		Shape = spec.Shape,
		Center = instance.Center,
		Yaw = instance.Yaw,
		Radius = spec.Radius,
		-- A sphere ignores Height; handing it the diameter keeps anything that reads it (the wall) honest.
		Height = if spec.Shape == "Sphere" then spec.Radius * 2 else spec.Height,
	}
end

-- Membership bookkeeping ---------------------------------------------------------------------------------

function DomainInstance.Admit(instance: DomainInstance, body: Model, now: number, founding: boolean): ()
	local existing = instance.Members[body]
	if existing then
		existing.LingerUntil = nil
		return
	end
	instance.Members[body] = { EnteredAt = now, Founding = founding, LingerUntil = nil }
	instance.MemberCount += 1
end

function DomainInstance.Release(instance: DomainInstance, body: Model): ()
	if instance.Members[body] then
		instance.Members[body] = nil
		instance.MemberCount -= 1
	end
end

-- Whether an effect may target this member yet: inside (not lingering), and past its entry grace unless it
-- was there when the realm was established.
function DomainInstance.IsTargetable(instance: DomainInstance, member: Member, now: number): boolean
	if member.LingerUntil ~= nil then
		return false
	end
	return member.Founding or now - member.EnteredAt >= instance.Spec.EntryGraceSeconds
end

return DomainInstance
