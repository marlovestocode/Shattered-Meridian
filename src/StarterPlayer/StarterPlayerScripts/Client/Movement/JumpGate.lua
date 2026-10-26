--!strict
--[[
	JumpGate.lua

	Owns: the local Humanoid's Jumping state switch (Humanoid:SetStateEnabled(Jumping, ...)) -- the one
	writer of it. Every reason to stand the jump down is a named claim; the jump is off while any claim is
	held and back on when the last one goes. The client-side twin of Server/Combat/RootControl.lua, for the
	same reason that module exists.

	WHY. Three modules wrote the switch directly, each with its own idea of when to put it back:
	  * AttackInputClient, while Space is the launcher modifier (docs/design/air-combat-and-evade.md B2),
	    on a task.delay that wrote `true` when the string lapsed;
	  * GrabInputClient, for a grab throw's clip (GrabThrowing), writing `true` when the throw ended;
	  * SwingRootClient, for a locked swing (SwingRooted), writing `true` unless GrabThrowing was up.
	None knew about the launcher window, so a locked swing that ended inside the launcher window handed
	Space its hop back, and the launcher window lapsing during a locked swing let the attacker jump out of
	a lock that was meant to hold them. Adding a realm's Rooted rule as a fourth writer would have added
	two more such pairs. With one writer and a claim per owner, no owner can release another's hold.

	Claims are keyed by Humanoid with weak keys, so a life that ends takes its claims with it and a fresh
	Humanoid starts with none -- the engine's default (jump enabled) is then the right answer.

	Does not own: when any owner holds (each owner decides), or the jump's physics (Roblox / parkour).
]]

local JumpGate = {}

-- Every owner. A new reason to stand the jump down is a new entry here, never a direct SetStateEnabled.
JumpGate.Owners = {
	-- Space is the launcher modifier while the Basic string is live (AttackInputClient).
	LauncherWindow = "LauncherWindow",
	-- A grab thrower rooted for their throw clip (GrabInputClient, off GrabThrowing).
	GrabThrow = "GrabThrow",
	-- A move that Locks movement holds its attacker (SwingRootClient, off SwingRooted).
	SwingRoot = "SwingRoot",
	-- A realm's Rooted rule holds the body where it is (SwingRootClient, off DomainRules).
	RealmRoot = "RealmRoot",
}

-- Humanoid -> owner -> true.
local claims: { [Humanoid]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

local function publish(humanoid: Humanoid): ()
	local held = claims[humanoid]
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, held == nil)
end

-- Takes (`held` true) or drops (`held` false) `owner`'s claim. Idempotent, and it re-publishes every call,
-- so an owner restating its answer also repairs a switch something outside this module flipped.
function JumpGate.Set(humanoid: Humanoid, owner: string, held: boolean): ()
	local current = claims[humanoid]
	if held then
		if current == nil then
			current = {}
			claims[humanoid] = current
		end
		current[owner] = true
	elseif current ~= nil then
		current[owner] = nil
		if next(current) == nil then
			claims[humanoid] = nil
		end
	end
	publish(humanoid)
end

-- Whether `owner` (or, with no owner, anybody) is holding this Humanoid's jump down.
function JumpGate.IsHeld(humanoid: Humanoid, owner: string?): boolean
	local current = claims[humanoid]
	if current == nil then
		return false
	end
	if owner == nil then
		return true
	end
	return current[owner] == true
end

return JumpGate
