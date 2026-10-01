--!strict
--[[
	ProjectileRelevance.lua

	Owns: which clients hear about which shot on Attack_Projectile. A Router takes one engine frame's
	batch of shot events (HitboxEngine.OnProjectileEvents) plus where every player is, and returns each
	player's own share of it; AttackRequestSystem sends each share with FireClient.

	WHY (2026-09-30). The batch used to go out with FireAllClients: every shot anywhere in the server was
	sent to, flown by and drawn on every client, with a homing re-sync per shot four times a second on top.
	A realm's strikes -- one homing shot per body per pulse -- then cost a player on the far side of the map
	nearly what it cost the bodies being struck.

	THE DECISION IS MADE AT LAUNCH, AND KEPT. A client is sent a shot's Launch if it could see it:
	  * the player threw it, or is its homing target, or has no character to measure from (a spawning or
	    dead player's camera is somewhere this cannot know -- sending too much there is the safe error);
	  * or the shot's straight path -- from where it launched, as far as it can fly (its speed, or its
	    MaxSpeed if it accelerates, over its remaining lifetime; ProjectileTypes' MaxRange ceiling) --
	    passes within the radius of the player's body, widened by how far gravity can drop it;
	  * or its homing target stands within the radius (a pinned shot curves toward that body, so whoever is
	    near the body sees it arrive);
	  * or it homes with no target yet (a seeker can turn anywhere its range reaches): the launch point
	    within radius + reach.
	Those players become the shot's RECIPIENTS, and its Updates and End go to exactly them: a client that
	never drew a shot has nothing to update, and an End it had not drawn would still burst world sparks on
	it. A re-launch (a parry turning the shot) re-tests and ADDS to the set -- the old recipients are still
	drawing it and must see it turn. A shot is not added mid-flight to a client it later flies toward: its
	path was already tested whole at launch, which is what the path test is for.

	A shot's record is dropped on its End, or past its lifetime plus a grace if the End never comes, so the
	table is bounded by the engine's own live-shot ceiling.

	Does not own: the events (ProjectileSimulator), the remote (AttackRequestSystem), or drawing
	(Client/FX/ProjectileFX.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)

type Event = AttackTypes.ProjectileWireEvent

-- Where one player could see from: their character, and its root's position (nil = unknown).
export type Viewer = {
	Player: Player,
	Character: Model?,
	Position: Vector3?,
}

type Record = {
	Recipients: { [Player]: boolean },
	ExpiresAt: number,
}

export type Router = {
	Radius: number,
	Records: { [number]: Record },
	NextPruneAt: number,
	Route: (self: Router, events: { Event }, viewers: { Viewer }, now: number) -> { [Player]: { Event } },
	TrackedCount: (self: Router) -> number,
	Reset: (self: Router) -> (),
}

-- No shot flies further than the schema lets it (its MaxRange ceiling), whatever speed x lifetime says.
local MAX_REACH = ProjectileTypes.Limits.MaxRange.Max
-- A record whose End never came is forgotten this long past the shot's own lifetime.
local EXPIRY_GRACE_SECONDS = 1
-- Records are swept for expiry at most this often -- the sweep is a walk of every live shot.
local PRUNE_INTERVAL_SECONDS = 1

local ProjectileRelevance = {}

local function distanceToSegment(point: Vector3, from: Vector3, to: Vector3): number
	local segment = to - from
	local lengthSquared = segment:Dot(segment)
	if lengthSquared < 1e-6 then
		return (point - from).Magnitude
	end
	local along = math.clamp((point - from):Dot(segment) / lengthSquared, 0, 1)
	return (point - (from + segment * along)).Magnitude
end

-- How far the shot can fly from its launch, and how far gravity can pull it off its straight line.
local function reachOf(event: Event): (number, number)
	local lifetime = math.max(event.LifetimeSeconds or 0, 0)
	local motion = event.Motion
	local speed = event.Velocity.Magnitude
	if motion and motion.Acceleration > 0 then
		speed = math.max(speed, motion.MaxSpeed)
	end
	local reach = math.min(speed * lifetime, MAX_REACH)
	local drop = if motion then math.min(0.5 * math.abs(motion.Gravity) * lifetime * lifetime, MAX_REACH) else 0
	return reach, drop
end

local function rootPositionOf(model: Model?): Vector3?
	local root = if model then model.PrimaryPart else nil
	return if root then root.Position else nil
end

-- Whether `viewer` could see the shot `event` launches (this file's header).
local function sees(radius: number, viewer: Viewer, event: Event): boolean
	local position = viewer.Position
	local character = viewer.Character
	if position == nil then
		return true
	end
	if character ~= nil and (event.Owner == character or event.Target == character) then
		return true
	end
	local reach, drop = reachOf(event)
	local motion = event.Motion
	local homes = motion ~= nil and motion.HomingStrength > 0
	if homes and event.Target == nil then
		return (position - event.Position).Magnitude <= radius + reach + drop
	end
	local speed = event.Velocity.Magnitude
	local direction = if speed > 1e-4 then event.Velocity / speed else Vector3.zero
	if distanceToSegment(position, event.Position, event.Position + direction * reach) <= radius + drop then
		return true
	end
	local targetPosition = if homes then rootPositionOf(event.Target) else nil
	return targetPosition ~= nil and (targetPosition - position).Magnitude <= radius
end

local function append(routed: { [Player]: { Event } }, player: Player, event: Event): ()
	local list = routed[player]
	if list == nil then
		list = {}
		routed[player] = list
	end
	table.insert(list, event)
end

local function route(self: Router, events: { Event }, viewers: { Viewer }, now: number): { [Player]: { Event } }
	local routed: { [Player]: { Event } } = {}
	local present: { [Player]: boolean } = {}
	for _, viewer in viewers do
		present[viewer.Player] = true
	end

	for _, event in events do
		local record = self.Records[event.Id]
		if event.Kind == "Launch" then
			if record == nil then
				record = { Recipients = {}, ExpiresAt = 0 }
				self.Records[event.Id] = record
			end
			local held = record :: Record
			held.ExpiresAt = now + math.max(event.LifetimeSeconds or 0, 0) + EXPIRY_GRACE_SECONDS
			for _, viewer in viewers do
				if held.Recipients[viewer.Player] or sees(self.Radius, viewer, event) then
					held.Recipients[viewer.Player] = true
					append(routed, viewer.Player, event)
				end
			end
		elseif record ~= nil then
			for player in record.Recipients do
				if present[player] then
					append(routed, player, event)
				end
			end
			if event.Kind == "End" then
				self.Records[event.Id] = nil
			end
		end
	end

	if now >= self.NextPruneAt then
		self.NextPruneAt = now + PRUNE_INTERVAL_SECONDS
		for id, record in self.Records do
			if now >= record.ExpiresAt then
				self.Records[id] = nil
			end
		end
	end
	return routed
end

local function trackedCount(self: Router): number
	local count = 0
	for _ in self.Records do
		count += 1
	end
	return count
end

local function reset(self: Router): ()
	table.clear(self.Records)
	self.NextPruneAt = 0
end

-- A router with its own shot records, relevant within `radius` studs
-- (AttackConstants.Network.ProjectileRelevanceStuds).
function ProjectileRelevance.New(radius: number): Router
	return {
		Radius = radius,
		Records = {},
		NextPruneAt = 0,
		Route = route,
		TrackedCount = trackedCount,
		Reset = reset,
	}
end

return ProjectileRelevance
