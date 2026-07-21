--!strict
--[[
	AnimatorUtil.lua

	Owns: the single "find this Model's Humanoid, find-or-create an Animator under it" bit of
	Instance plumbing every animation-playing module needs before it can LoadAnimation anything.
	Pure Instance manipulation with no client/server-authoritative distinction -- an Animator is
	just a replicated Instance, not player-authoritative state, so this is safe for both client
	modules (Client/FX/CombatAnimator.lua, Client/FX/FlightAnimator.lua, each binding the LOCAL
	player's own character) and a server module (ServerScriptService/Server/Combat/BotAnimator.lua,
	binding a training bot's Model, which has no owning client to run a client module for it) to
	share verbatim, rather than three byte-identical private copies of the same four lines.

	Does not own: loading/playing any actual AnimationTrack, or deciding which Humanoid/Model to
	bind -- callers own their own BindCharacter/BindBot entry points and just ask this for the
	Animator to LoadAnimation against.
]]

local AnimatorUtil = {}

-- Returns `character`'s Animator, creating one under its Humanoid if it doesn't already have one.
-- Returns nil (nothing to return) if `character` has no Humanoid at all -- callers treat that as
-- "nothing to bind" and log their own warning; this module doesn't decide what a missing Humanoid
-- means for any specific caller.
function AnimatorUtil.GetOrCreateAnimator(character: Model): Animator?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator
end

return AnimatorUtil
