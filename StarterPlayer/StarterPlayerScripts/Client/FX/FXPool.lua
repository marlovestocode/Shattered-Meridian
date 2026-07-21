--!strict
--[[
	FXPool.lua

	Owns: a generic acquire/release object pool -- the reusable "never instance-and-destroy per use"
	primitive performance-optimization.md and animation-systems.md's VFX conventions mandate ("all
	VFX are object-pooled, never instanced-and-destroyed per use"). This is the first realization of
	that pattern in the repo (SoundManager already pools Sounds ad hoc; this generalizes it for the
	visual-effect work starting with HitFlash.lua). Deliberately Instance-AGNOSTIC: it manages a free
	list and a hard size cap over items produced by a caller-supplied factory, and knows nothing about
	Highlights, particles, or Roblox at all -- which is exactly what makes its logic unit-testable
	(Tests/Combat/FXPool.spec.lua) without a DataModel, the same extraction reasoning as
	PredictionMirror/Movement.

	Semantics: Acquire reuses a freed item if one exists, else creates a new one via the factory
	until MaxSize items exist, then returns nil (at cap, none free) -- the caller drops the effect,
	which for a brief cosmetic flash is a non-issue. Release runs the optional reset on the item and
	returns it to the free list. Items are never destroyed by the pool (they idle in the free list
	for reuse); a process-lifetime pool like HitFlash's never needs teardown.

	Does not own: what the pooled item IS or how it's shown/hidden (the factory/reset callbacks and
	the caller own that), or any lifetime timer deciding WHEN to release (the caller's job -- e.g.
	HitFlash releases after its fade completes).

	Also owns (bolted onto this same module rather than a new file, since it's a small, unrelated-
	but-adjacent pooling concern): GetHolder, a shared lazy create-or-reuse persistent Folder getter.
	HitFlash.lua/FlightVFX.lua/MovementVFX.lua each used to hand-roll their own private
	getHolder() doing the identical "if existing and existing.Parent then reuse else make a fresh one"
	check to get a stable, unreplicated parent Folder for their pooled instances to live under while
	active -- see GetHolder's own comment below for why this is centralized here instead.
]]

local FXPool = {}
FXPool.__index = FXPool

export type Pool<T> = {
	-- Reuse a freed item, or make a new one up to MaxSize; nil once at cap with none free.
	Acquire: (self: Pool<T>) -> T?,
	-- Reset (if a reset callback was given) and return an item to the free list.
	Release: (self: Pool<T>, item: T) -> (),
	-- Diagnostics/tests: how many items are currently checked out, and how many idle.
	CountActive: (self: Pool<T>) -> number,
	CountFree: (self: Pool<T>) -> number,
}

type Internal<T> = {
	factory: () -> T,
	reset: ((T) -> ())?,
	maxSize: number,
	free: { T },
	created: number,
	active: number,
}

-- factory builds a fresh item (called at most MaxSize times over the pool's life). reset, if given,
-- is run on each Release to return the item to a clean idle state before it can be reused. maxSize
-- caps the TOTAL items the pool will ever create.
function FXPool.New<T>(factory: () -> T, reset: ((T) -> ())?, maxSize: number): Pool<T>
	local self: Internal<T> = {
		factory = factory,
		reset = reset,
		maxSize = maxSize,
		free = {},
		created = 0,
		active = 0,
	}
	return setmetatable(self, FXPool) :: any
end

function FXPool.Acquire<T>(self: Internal<T>): T?
	local reused = table.remove(self.free)
	if reused ~= nil then
		self.active += 1
		return reused
	end
	if self.created >= self.maxSize then
		return nil
	end
	self.created += 1
	self.active += 1
	return self.factory()
end

function FXPool.Release<T>(self: Internal<T>, item: T): ()
	if self.reset then
		self.reset(item)
	end
	self.active -= 1
	table.insert(self.free, item)
end

function FXPool.CountActive<T>(self: Internal<T>): number
	return self.active
end

function FXPool.CountFree<T>(self: Internal<T>): number
	return #self.free
end

-- Keyed by holder name so unrelated callers (HitFlash's "HitFlashHolder", FlightVFX's
-- "FlightVFXHolder", MovementVFX's "MovementVFXHolder") each get their own independent slot without
-- colliding, while still sharing the one lazy-create-or-reuse implementation below.
local holders: { [string]: Folder } = {}

-- Lazily create-or-reuse a persistent, unreplicated Folder to parent pooled effect instances under --
-- the identical shape HitFlash.lua/FlightVFX.lua/MovementVFX.lua each used to duplicate as their own
-- private getHolder(): "if the folder we made last time is still parented, it's still alive, reuse
-- it; otherwise make a fresh one." A holder Folder exists at all so pooled instances stay off any
-- world Model/Camera that can be destroyed out from under them mid-effect (see those modules' own
-- headers) -- destroying a Model doesn't touch a Folder living elsewhere.
--
-- parentProvider is a FUNCTION, not a plain Instance, and is only ever invoked at the moment a NEW
-- folder must be created (never cached/re-invoked while the existing folder is still alive). This
-- matters for HitFlash specifically: its holder wants to live under Workspace.CurrentCamera, which
-- Roblox itself destroys and replaces on some camera-mode transitions -- destroying the old camera
-- destroys the old holder Folder parented under it too, so the next GetHolder call's `existing.Parent`
-- check correctly reads "gone" and re-resolves parentProvider() to whatever CurrentCamera is NOW,
-- rather than latching onto the Instance CurrentCamera happened to be the first time this ever ran.
-- FlightVFX/MovementVFX have no such reparenting need -- their provider is just `function() return
-- Workspace end` -- but they take the same shape rather than a special-cased plain-Instance overload.
function FXPool.GetHolder(name: string, parentProvider: () -> Instance): Folder
	local existing = holders[name]
	if existing and existing.Parent then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parentProvider()
	holders[name] = folder
	return folder
end

return FXPool
