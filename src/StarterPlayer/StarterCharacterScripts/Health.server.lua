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
	reimplement that, and doesn't.

	DO NOT ADD REGEN LOGIC HERE -- and note that this instruction has survived the game GAINING passive
	health regen, because the two were never the same question.

	This game now does have passive health regen: Constants.Combat.HealthRegen tunes it,
	Server/Combat/HealthRegen.lua holds its arithmetic, and CombatSystem's Heartbeat is its one writer.
	That reverses the original design (which cited a Sekiro-grade reference point with no passive
	health recovery) at the repo owner's request. What has NOT changed is why this file is empty:
	Roblox's default script is an untracked writer of Humanoid.Health that runs outside the server's
	combat pipeline entirely, so it would heal through damage the server had just applied and race the
	one system that is supposed to own that value. Suppressing it matters MORE now, not less -- with a
	real regen model in place, a second uncoordinated one would be nearly invisible in testing and
	would show up only as combat math that quietly doesn't add up.
]]
