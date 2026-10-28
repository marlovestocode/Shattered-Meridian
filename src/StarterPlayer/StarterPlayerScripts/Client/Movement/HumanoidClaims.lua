--!strict
--[[
	HumanoidClaims.lua

	Owns: the claim bookkeeping behind a client-side single-writer gate on one Humanoid switch -- who is
	holding it, per Humanoid. JumpGate (the Jumping state) and TurnGate (AutoRotate) are each one of these
	plus the one line that publishes the switch. Not used directly by gameplay: an owner talks to the gate,
	so every owner of a switch is listed in that gate's own `Owners` table.

	Claims are keyed by Humanoid with weak keys, so a life that ends takes its claims with it and a fresh
	Humanoid starts with none -- the engine's default is then the right answer.

	Does not own: what "held" means for the switch (the gate's `publish`), or when any owner holds.
]]

local HumanoidClaims = {}

export type Gate = {
	-- Takes (`held` true) or drops (`held` false) `owner`'s claim. Idempotent, and it re-publishes every
	-- call, so an owner restating its answer also repairs a switch something outside the gate flipped.
	Set: (humanoid: Humanoid, owner: string, held: boolean) -> (),
	-- Whether `owner` (or, with no owner, anybody) holds this Humanoid's switch.
	IsHeld: (humanoid: Humanoid, owner: string?) -> boolean,
	-- Whether anybody OTHER than `owner` holds it.
	IsHeldExcept: (humanoid: Humanoid, owner: string) -> boolean,
}

-- `publish(humanoid, held)` writes the switch; `held` is true while any claim is held.
function HumanoidClaims.New(publish: (humanoid: Humanoid, held: boolean) -> ()): Gate
	-- Humanoid -> owner -> true.
	local claims: { [Humanoid]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

	local function set(humanoid: Humanoid, owner: string, held: boolean): ()
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
		publish(humanoid, claims[humanoid] ~= nil)
	end

	local function isHeld(humanoid: Humanoid, owner: string?): boolean
		local current = claims[humanoid]
		if current == nil then
			return false
		end
		if owner == nil then
			return true
		end
		return current[owner] == true
	end

	local function isHeldExcept(humanoid: Humanoid, owner: string): boolean
		local current = claims[humanoid]
		if current == nil then
			return false
		end
		for holder in current do
			if holder ~= owner then
				return true
			end
		end
		return false
	end

	return {
		Set = set,
		IsHeld = isHeld,
		IsHeldExcept = isHeldExcept,
	}
end

return HumanoidClaims
