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
	attackDebugName: string?,
	-- Additive, appended last so every existing positional call site stays valid untouched -- see
	-- Types.CombatFeedbackPayload.AirComboPriorityShift's own header for what this flags (Kind ==
	-- "Parried" only).
	airComboPriorityShift: boolean?,
	-- Additive, appended last (same "existing positional call site stays valid untouched" reasoning as
	-- airComboPriorityShift above) -- see Types.CombatFeedbackPayload.FinisherVariant's own header for
	-- what this flags (Kind == "Hit" only, and only once a caller has already confirmed the finisher's
	-- knockback actually applied).
	finisherVariant: Types.FinisherVariant?,
	-- Additive, appended last (same reasoning again) -- see Types.CombatFeedbackPayload.
	-- ImmediateGroundImpact's own header for what this flags (Kind == "GroundSlam" only).
	immediateGroundImpact: boolean?,
	-- Additive, appended last (same reasoning again). A whole sub-table rather than another run of
	-- positional scalars -- an Object Stun carries nine presentation values, and appending nine more
	-- parameters to a builder eleven call sites already pass positionally is exactly how a call site
	-- ends up silently off by one. See Types.ObjectStunFeedback (Kind == "ObjectStun" only).
	objectStun: Types.ObjectStunFeedback?
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
		AirComboPriorityShift = airComboPriorityShift,
		FinisherVariant = finisherVariant,
		ImmediateGroundImpact = immediateGroundImpact,
		ObjectStun = objectStun,
	}
end

return FeedbackPayload
