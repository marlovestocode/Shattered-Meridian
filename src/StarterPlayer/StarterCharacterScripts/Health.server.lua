--!strict
--[[
	Health.server.lua

	Owns: nothing. This script is deliberately empty.

	When a character has no script named "Health" under StarterCharacterScripts, Roblox inserts its
	own built-in default health-regen script into every spawned character -- a passive per-second
	heal completely outside CombatSystem's control. CombatSystem.lua treats `Humanoid.Health` as
	authoritative (engineering-standards.md's server-authoritative rule; see that file's header for
	why Health isn't double-tracked as a separate number), so an untracked passive regen would
	silently undo combat damage between hits.

	Roblox's default-script insertion is per name, not all-or-nothing: providing a script literally
	named "Health" here fills that slot so Roblox doesn't insert its own, while leaving "Animate"
	unmanaged so Roblox still inserts its own default animation script -- this repo has no reason to
	reimplement that, and doesn't. Do not add regen logic here; Constants.Combat's PostureRegenPerSecond
	is the only passive-regen model this game uses (Stamina, the game's other regenerating resource,
	was removed), and Health is intentionally excluded from it (combat-philosophy.md's Sekiro-grade
	reference point has no passive health regen).
]]
