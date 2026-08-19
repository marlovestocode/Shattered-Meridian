--!strict
--[[
	Trove.lua

	Owns: one job -- "hold everything one scope created, so ending that scope is a single call."
	A Trove tracks RBXScriptConnections, Instances, teardown functions and nested Troves, and
	releases them in reverse order of acquisition on Clean().

	Why this exists. Before it, per-scope teardown was hand-rolled in ~25 modules in two shapes that
	never converged: a bare `local connection: RBXScriptConnection? = nil` field nil-checked and
	disconnected by hand (the majority, and the shape that leaks the moment a second connection is
	added next to it and someone forgets the matching Disconnect), and Client/Movement/
	RunController.lua's own `sessionConnections`/`lifeConnections` pair with a local
	`releaseConnections` helper -- which is the right idea and is this module's direct ancestor, but
	was one module's private detail rather than something the next module could reach for. This is
	that helper, promoted, given the three non-connection kinds those call sites also needed
	(Instances to Destroy, plain teardown closures, and nested scopes), and specced.

	SEPARATE TROVES ARE THE POINT, not one big one. RunController's own comment names the property
	this module is built to preserve: "keeping them in separate lists is what makes 'rebind without
	leaking' a property of the structure rather than of remembering to nil one specific field." A
	module with a session-long scope and a per-life scope holds two Troves -- Clean() the life one on
	every respawn, the session one only on Stop() -- and cannot accidentally take the session's
	connections down with the character's.

	REVERSE ORDER on Clean, matching RunController's own `for index = #list, 1, -1`. Teardown that
	runs in acquisition order can hand a later object a dependency that has already been released;
	reverse order is the only ordering that is correct by construction.

	Does NOT own: what any tracked object means, whether cleaning is the right thing to do right now,
	or any lifecycle event that would trigger it -- Shared/PlayerLifecycle.lua owns the two
	player/character-shaped triggers this codebase actually uses, and is this module's main consumer.
	Deliberately not a general resource pool or a DI container: it releases, it never acquires.
]]

local Trove = {}
Trove.__index = Trove

-- The four kinds a Trove knows how to release. A nested Trove is deliberately one of them -- the
-- alternative (a caller holding a list of child Troves and cleaning each by hand) is exactly the
-- bookkeeping this module exists to delete.
export type Trackable = RBXScriptConnection | Instance | (() -> ()) | TroveInstance

export type TroveInstance = typeof(setmetatable(
	{} :: {
		objects: { Trackable },
		-- Guards the one reentrancy that silently loses work: Add() called from inside a teardown
		-- function that Clean() is currently running would append to a list Clean has already walked
		-- past, and the object would never be released. Asserted rather than handled, because every
		-- legitimate version of that pattern (a teardown that needs its own scope) is a nested Trove.
		cleaning: boolean,
	},
	Trove
))

local function release(object: Trackable): ()
	if typeof(object) == "RBXScriptConnection" then
		object:Disconnect()
	elseif typeof(object) == "function" then
		object()
	elseif typeof(object) == "Instance" then
		object:Destroy()
	elseif typeof(object) == "table" and getmetatable(object :: any) == Trove then
		(object :: TroveInstance):Clean()
	end
end

-- Drains the tracked list, newest first. Split out of Clean below purely so the pcall there needs no
-- closure -- see that function's own comment for why the pcall is there at all.
local function releaseAll(self: TroveInstance): ()
	for index = #self.objects, 1, -1 do
		local object = self.objects[index]
		self.objects[index] = nil
		release(object)
	end
end

-- One independent teardown scope -- the same "one instance per category" shape
-- Shared/RateLimiter.lua and Shared/ChangeNotifier.lua already establish.
function Trove.New(): TroveInstance
	return setmetatable({
		objects = {},
		cleaning = false,
	}, Trove) :: any
end

-- Tracks `object` and RETURNS IT UNCHANGED, so acquisition and tracking are one expression:
-- `local humanoid = trove:Add(Instance.new("Humanoid"))`. Returning the object is what keeps this
-- from being a second line every call site has to remember, which is the failure mode of every
-- hand-rolled version of this it replaces.
function Trove.Add<T>(self: TroveInstance, object: T & Trackable): T
	assert(not self.cleaning, "Trove:Add() called from inside its own Clean() -- use a nested Trove instead")
	table.insert(self.objects, object)
	return object
end

-- Connects `signal` and tracks the connection in one call -- the single most common thing a Trove
-- is handed, and the one where forgetting the Add is easiest.
function Trove.Connect<A...>(self: TroveInstance, signal: RBXScriptSignal<A...>, handler: (A...) -> ()): RBXScriptConnection
	return self:Add(signal:Connect(handler))
end

-- A child Trove, cleaned when this one is. The shape a per-life scope inside a per-session scope
-- wants: the caller keeps the child to Clean() it on its own schedule (every respawn), and never has
-- to remember it exists on the session's own teardown path.
function Trove.Extend(self: TroveInstance): TroveInstance
	return self:Add(Trove.New())
end

-- Releases one tracked object early and stops tracking it. Returns whether it was actually being
-- tracked, so a caller can tell "released it" from "it was already gone" rather than assuming.
function Trove.Remove(self: TroveInstance, object: Trackable): boolean
	local index = table.find(self.objects, object)
	if not index then
		return false
	end
	table.remove(self.objects, index)
	release(object)
	return true
end

-- Releases everything, newest first, and leaves the Trove EMPTY AND REUSABLE -- a per-life Trove is
-- Cleaned and refilled on every respawn for the whole session, so a one-shot "destroy" would be the
-- wrong contract. Cleaning an already-empty Trove is a no-op, which is what makes it safe to call
-- from every teardown path (respawn, death, Stop) without first asking whether anything is bound --
-- the property RunController.unbind's own comment relies on.
function Trove.Clean(self: TroveInstance): ()
	if self.cleaning then
		return
	end
	self.cleaning = true
	-- pcall, and a hoisted function rather than a closure so this allocates nothing: a teardown that
	-- throws (or the Add-during-Clean assertion above) must not leave `cleaning` stuck true, which
	-- would silently turn every LATER Clean on this Trove into a no-op -- a leak that only shows up
	-- several respawns after the actual mistake. The error is re-raised unchanged once the flag is
	-- restored, so nothing is swallowed.
	local ok, err = pcall(releaseAll, self)
	self.cleaning = false
	if not ok then
		error(err, 0)
	end
end

-- How many objects are currently tracked. Spec-facing and diagnostics-facing: "did this rebind leak"
-- is otherwise unobservable from outside, which is precisely how the hand-rolled versions of this
-- module went wrong without anything failing.
function Trove.Count(self: TroveInstance): number
	return #self.objects
end

return Trove
