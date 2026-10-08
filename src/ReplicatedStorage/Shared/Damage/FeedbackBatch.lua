--!strict
--[[
	FeedbackBatch.lua

	Owns: the wire shape of Combat_Feedback, both ends of it. DamageSystem queues every resolved contact's
	feedback per player and sends each player ONE batch per frame; a client unpacks that batch here and
	handles its entries in order, exactly as it would have handled the separate events.

	WHY (2026-10-08). Feedback used to be one FireClient per contact per participant. A swing that reaches
	several bodies (MaxTargetsPerSwing up to 8), a projectile volley, or a realm pulse resolved several
	contacts in a single frame and sent the attacker that many remote events at once -- against the ~4
	calls/sec/player budget in the studio bible's performance-optimization.md. They all leave in the same
	frame regardless, so batching them changes no timing a player can see, only the per-event overhead.

	ORDER IS PRESERVED: entries are appended in resolution order and unpacked in that order, so a stun and
	the launch that follows it arrive the way they were applied.

	Unpack also accepts a lone CombatFeedback table (the pre-batch shape), so a client never drops a hit
	during a deploy where the two ends briefly disagree.

	Does not own: what any entry means (CombatFeedbackClient), or when the batch is flushed (DamageSystem).
]]

local DamageTypes = require(script.Parent.DamageTypes)

type CombatFeedback = DamageTypes.CombatFeedback

export type Batch = { CombatFeedback }

local FeedbackBatch = {}

-- The entries in `raw`, in order: a batch's entries, a lone pre-batch payload as a batch of one, or an
-- empty list for anything else. Entries that are not tables are skipped; validating their fields is the
-- consumer's job, as it always was.
function FeedbackBatch.Unpack(raw: unknown): Batch
	if typeof(raw) ~= "table" then
		return {}
	end
	local tableRaw = raw :: { [any]: any }
	if typeof(tableRaw.Kind) == "string" then
		return { tableRaw :: CombatFeedback }
	end
	local out: Batch = {}
	for _, entry in ipairs(tableRaw) do
		if typeof(entry) == "table" then
			table.insert(out, entry :: CombatFeedback)
		end
	end
	return out
end

return FeedbackBatch
