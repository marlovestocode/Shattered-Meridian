--!strict
--[[
	DomainClash.lua

	Owns: what happens when two realms meet -- which one wins, and what the winner does to the other.
	Pure: handed two participants, it answers with one Outcome; DomainSystem applies it. No clock, no
	Instances, so every matchup is a spec.

	THE RULE, in order:
	  1. A realm authored Interacts = false touches nothing and is touched by nothing: Coexist.
	  2. Higher Priority wins.
	  3. A tie is decided by the CHALLENGER's TieBreak -- the realm that opened later, the one walking into
	     a realm already standing. "Older" yields to the incumbent, "Newer" claims it, "Contest" refuses
	     to decide: neither wins, and both hold the overlap at their ContestScale (a partial cancel).
	  4. The winner's behaviour toward the loser -- its per-opponent override for the loser's MoveId if it
	     authored one (DomainTypes.BehaviorToward), its default otherwise:
	       Coexist   nothing happens; both realms' rules and effects apply to anyone in both.
	       Suppress  inside the overlap, only the winner's law holds; the loser runs on outside it.
	       Erode     Suppress, and the loser's remaining time drains ErodeRate seconds faster per second
	                 of overlap -- the weaker realm is worn away rather than broken.
	       Dominate  the loser collapses outright.
	       Shatter   both collapse -- a realm built to annihilate, at the price of itself.

	WHY THE WINNER DECIDES. A realm's identity is what it does to OTHERS -- one that crushes, one that
	tolerates, one that wears down. Letting the loser's own setting soften its defeat would make every
	matchup the gentlest of the two behaviours, and the authored identities would stop mattering exactly
	where they were meant to show.

	Does not own: detecting the overlap (DomainGeometry.Overlaps), applying an outcome, or the schema.
]]

local DomainClash = {}

export type Behavior = "Coexist" | "Suppress" | "Erode" | "Dominate" | "Shatter" | "Contest"

export type Participant = {
	Id: string,
	MoveId: string,
	Priority: number,
	-- The realm's default behaviour and its per-opponent overrides (opponent MoveId -> behaviour).
	Behavior: string,
	Overrides: { [string]: string },
	TieBreak: string,
	Interacts: boolean,
	-- When it opened, on any clock both participants share. Only compared to the other's.
	OpenedAt: number,
}

export type Outcome = {
	Behavior: Behavior,
	-- nil for Coexist and Contest (nobody won).
	Winner: string?,
	Loser: string?,
}

local function behaviorOf(winner: Participant, loser: Participant): Behavior
	local override = winner.Overrides[loser.MoveId]
	local chosen = override or winner.Behavior
	if
		chosen == "Coexist"
		or chosen == "Suppress"
		or chosen == "Erode"
		or chosen == "Dominate"
		or chosen == "Shatter"
	then
		return chosen :: Behavior
	end
	return "Suppress"
end

function DomainClash.Resolve(a: Participant, b: Participant): Outcome
	if not a.Interacts or not b.Interacts then
		return { Behavior = "Coexist" }
	end

	local winner: Participant? = nil
	local loser: Participant? = nil
	if a.Priority > b.Priority then
		winner, loser = a, b
	elseif b.Priority > a.Priority then
		winner, loser = b, a
	else
		-- The challenger is whichever opened later; an exact tie on the clock takes the lower id, only so
		-- the answer never depends on argument order.
		local challenger, incumbent = a, b
		if a.OpenedAt < b.OpenedAt or (a.OpenedAt == b.OpenedAt and a.Id < b.Id) then
			challenger, incumbent = b, a
		end
		if challenger.TieBreak == "Older" then
			winner, loser = incumbent, challenger
		elseif challenger.TieBreak == "Newer" then
			winner, loser = challenger, incumbent
		else
			return { Behavior = "Contest" }
		end
	end

	local resolvedWinner = winner :: Participant
	local resolvedLoser = loser :: Participant
	local behavior = behaviorOf(resolvedWinner, resolvedLoser)
	if behavior == "Coexist" then
		return { Behavior = "Coexist" }
	end
	return { Behavior = behavior, Winner = resolvedWinner.Id, Loser = resolvedLoser.Id }
end

-- Whether an outcome takes the loser's law out of the overlap for the people standing in it.
function DomainClash.SuppressesLoser(behavior: Behavior): boolean
	return behavior == "Suppress" or behavior == "Erode"
end

-- Whether an outcome ends a realm outright: the loser, or (Shatter) both.
function DomainClash.Collapses(behavior: Behavior): boolean
	return behavior == "Dominate" or behavior == "Shatter"
end

return DomainClash
