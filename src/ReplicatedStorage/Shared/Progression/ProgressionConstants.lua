--!strict
--[[
	ProgressionConstants.lua

	Owns: the fight-to-grow gate's tunables -- today, the repeat-victim rule ProgressionSystem uses to
	decide how much of a PvP kill is legitimate progression.

	These are LEGITIMACY numbers, not reward numbers. They answer "how much of this kill counts", as a
	0..1 weight; what a fully counted kill is worth stays Constants.Meridian.BaseXPPerKill, owned by
	MeridianSystem. Changing a weight here changes how fast a farming pair stops earning, never what an
	honest kill pays.

	STARTING VALUES, chosen to be obviously protective and then tuned against playtest data -- they
	were not derived. Changing them moves how many kills the tier ladder (TierConstants.Tiers, priced
	in kills of BaseXPPerKill) effectively costs a player who keeps meeting the same opponent, so
	review the two together.
]]

local ProgressionConstants = {}

ProgressionConstants.RepeatVictim = {
	-- How long a killer->victim run stays open after that pair's latest kill. A kill inside it extends
	-- the run; only a full window with NO kill of that victim closes it. Every kill counts, including
	-- one already weighted to zero, so a pair that keeps farming stays at zero rather than earning
	-- again by spacing kills just inside the window.
	WindowSeconds = 600,
	-- The weight of the 1st, 2nd, 3rd... kill of one victim within a run. Past the end of this
	-- list a kill is worth 0 and progresses nobody. Must be non-increasing, each in (0, 1] --
	-- Tests/Progression/KillFarming.spec.lua asserts it.
	--
	-- Three steps rather than a hard cap at one: two players who genuinely fight each other twice in a
	-- session (a rematch, a contested zone) should both still be rewarded for it; the third and fourth
	-- time in ten minutes is a pattern, not a rivalry.
	Weights = table.freeze({ 1, 0.5, 0.25 }),
}

return ProgressionConstants
