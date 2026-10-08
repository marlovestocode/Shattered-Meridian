--!strict
--[[
	RootControl.lua

	Owns: AttributeConstants.RootControlLocked -- "the server owns this body right now; client movement must
	stand down" -- as a set of CLAIMS rather than a boolean anyone may write. The Attribute is true while ANY
	claim is held on a Humanoid and cleared when the last one is released.

	WHY (2026-10-08 combat-state audit). Six systems wrote that one boolean independently: the hitbox engine
	(a swing that locks movement), DefenseSystem (a stagger or a guard break), GrabSystem (twice: the victim,
	and the thrower through the clip), AirComboSystem (a held body) and VesselMount (a mounted body). Each set
	true and cleared to nil on its own exit, so whenever two overlapped, the first to finish cleared the other's
	lock. The body then belonged to the client's parkour framework while the server was still simulating it --
	a held air-combo victim staggered out of a parry, a locked-swing attacker grabbed mid-swing -- and two
	headers had to argue the race away by ordering ("the gap is one frame"). A claim set has no ordering to get
	right: releasing your claim can only ever clear the Attribute if nobody else holds one.

	CLAIMS ARE KEYED BY (Humanoid, owner name). The owner is a short fixed string per writer (RootControl.Owners),
	so a claim is idempotent -- claiming twice holds one claim -- and a writer can only release its own. Keyed
	by the Humanoid, not the Model, because the Attribute lives on the Humanoid; a respawn is a new Humanoid
	with no claims, and the old one's table entry is collected with it (weak keys).

	A WRITER THAT USED TO TEST "AM I THE HOLDER" before clearing (DefenseSystem's HoldsMovementLock, the
	engine's own) keeps that bookkeeping only to avoid redundant calls; correctness no longer depends on it.

	Server-only by placement (Server/Combat). VesselMount (Server/Vessel) requires it too: a mount is the same
	question -- "who is driving this body" -- and a second copy of the claim logic would bring the bug back.

	Does not own: what a locked body does (RunSystem pins its WalkSpeed off SwingRooted/Grabbed/Mounted; the
	client's ParkourController stands down off this Attribute), PlatformStand, or network ownership -- each
	writer still sets those itself, because they are not shared the way this Attribute is.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)

local RootControl = {}

-- The writers, by name. A new writer adds its own name here rather than reusing another's.
RootControl.Owners = {
	Swing = "Swing",
	Defense = "Defense",
	GrabVictim = "GrabVictim",
	GrabThrower = "GrabThrower",
	AirCombo = "AirCombo",
	Vessel = "Vessel",
}

-- Humanoid -> owner -> true. Weak keys: a destroyed Humanoid takes its claims with it.
local claims: { [Humanoid]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

local function publish(humanoid: Humanoid, locked: boolean): ()
	if humanoid.Parent == nil then
		return
	end
	-- nil rather than false, the convention every reader of this Attribute uses (`== true`).
	humanoid:SetAttribute(AttributeConstants.RootControlLocked, if locked then true else nil)
end

-- Takes `owner`'s claim on `humanoid`. Idempotent.
function RootControl.Claim(humanoid: Humanoid, owner: string): ()
	local held = claims[humanoid]
	if held == nil then
		held = {}
		claims[humanoid] = held
	end
	local set = held :: { [string]: boolean }
	if set[owner] then
		return
	end
	local wasLocked = next(set) ~= nil
	set[owner] = true
	if not wasLocked then
		publish(humanoid, true)
	end
end

-- Drops `owner`'s claim on `humanoid`; the Attribute clears only when no claim is left. Idempotent.
function RootControl.Release(humanoid: Humanoid, owner: string): ()
	local set = claims[humanoid]
	if set == nil or not set[owner] then
		return
	end
	set[owner] = nil
	if next(set) == nil then
		claims[humanoid] = nil
		publish(humanoid, false)
	end
end

-- Sets or drops `owner`'s claim -- for a writer whose state is a boolean it re-evaluates.
function RootControl.Set(humanoid: Humanoid, owner: string, held: boolean): ()
	if held then
		RootControl.Claim(humanoid, owner)
	else
		RootControl.Release(humanoid, owner)
	end
end

-- Whether `owner` (or, with no owner, anyone) holds a claim on `humanoid`.
function RootControl.IsClaimed(humanoid: Humanoid, owner: string?): boolean
	local set = claims[humanoid]
	if set == nil then
		return false
	end
	if owner then
		return set[owner] == true
	end
	return next(set) ~= nil
end

-- Who holds `humanoid`, sorted -- for the debug readout and specs.
function RootControl.Holders(humanoid: Humanoid): { string }
	local names: { string } = {}
	for owner in claims[humanoid] or {} do
		table.insert(names, owner)
	end
	table.sort(names)
	return names
end

-- Spec-only: forgets every claim without touching any Attribute.
function RootControl.ResetForTesting(): ()
	table.clear(claims)
end

return RootControl
