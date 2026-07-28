--!strict
--[[
	FeedbackPayload.lua

	Owns: the one pure struct-literal builder for Types.CombatFeedbackPayload -- extracted from
	CombatSystem.lua's own private buildFeedbackPayload once DummyCombat.lua/BotCombat.lua needed the
	exact same shape for their own resolveHit*/triggerPostureBreak-equivalent functions. No logic
	beyond assembling the table -- kept as its own tiny Server/Combat/ sibling (the same role
	HitResolution.lua/Movement.lua play for their own pure logic) purely so CombatSystem.lua,
	DummyCombat.lua, and BotCombat.lua all build an identically-shaped payload without three
	near-verbatim copies of the same field list drifting apart.

	Does not own: sending the payload anywhere -- CombatSystem.lua's own private sendFeedback (the
	Combat_FeedbackEvent RemoteEvent) is what actually dispatches it, injected into DummyCombat.lua/
	BotCombat.lua as a callback since that remote is this System's own private infrastructure.
]]

local Types = require(game:GetService("ReplicatedStorage").Shared.Types)

local FeedbackPayload = {}

function FeedbackPayload.Build(
	kind: Types.CombatFeedbackKind,
	attackerPlayer: Player?,
	targetPlayer: Player?,
	damageAmount: number?,
	postureAmount: number?,
	isHeavy: boolean?,
	targetPosition: Vector3?,
	attackDebugName: string?
): Types.CombatFeedbackPayload
	return {
		Kind = kind,
		AttackerUserId = if attackerPlayer then attackerPlayer.UserId else nil,
		TargetUserId = if targetPlayer then targetPlayer.UserId else nil,
		TargetPosition = targetPosition,
		DamageAmount = damageAmount,
		PostureAmount = postureAmount,
		IsHeavy = isHeavy,
		AttackDebugName = attackDebugName,
	}
end

return FeedbackPayload
