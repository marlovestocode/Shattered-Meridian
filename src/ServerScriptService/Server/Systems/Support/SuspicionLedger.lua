--!strict
--[[
	SuspicionLedger.lua

	Owns: the one shape every AUTOMATED cheat detector shares -- count strikes against a player inside a sliding
	window, and the first time the count reaches a threshold, flag them ONCE per session through
	ModerationSystem.ReportAutomated for a human to look at. Never a punishment: a flag is a record an admin
	reviews, and nothing in the game reads it to act on its own.

	WHY ONE (2026-10-08 combat-state audit). ParkourSystem (implausible movement reports) and KnockbackAudit
	(launches not honoured) each hand-rolled the same list of timestamps, the same prune, the same once-per-session
	latch and the same FlagSuspectedCheater call, and a third detector (MovementGuard, speed and teleport checks
	while engaged) was about to be the third copy. Two of the copies also wrote their flag with no reason code,
	and either could overwrite a MANUAL flag an admin had already written; ReportAutomated refuses to.

	A STRIKE CAN WEIGH MORE THAN ONE. A detector that sees something unambiguous (a teleport across the map) can
	count it as several strikes, so it reaches the threshold sooner than a run of marginal speed readings does --
	without a second threshold or a second ledger.

	THE IDENTITY SEAM. Players cannot be fabricated in the headless harness, so a ledger keys by whatever it is
	handed (a stand-in table with UserId and Name works) and reports through an injectable function
	(Config.Report, defaulting to ModerationSystem.ReportAutomated). Everything else is plain arithmetic.

	Does not own: what counts as a strike (each detector), any consequence of a flag (an admin), or the store.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Logger = require(ReplicatedStorage.Shared.Logger)

local ModerationSystem = require(ServerScriptService.Server.Systems.ModerationSystem)

local logger = Logger.scope("SuspicionLedger")

local SuspicionLedger = {}
SuspicionLedger.__index = SuspicionLedger

-- Anything with a UserId and a Name: a Player at runtime, a stand-in table in a spec.
export type Subject = any

export type Config = {
	-- Shown first in the flag's reason ("Movement", "Knockback", "Parkour").
	Name: string,
	-- Machine-readable, stored as the record's ReasonCode ("MovementSpeed", ...).
	ReasonCode: string,
	-- What a strike is, plural, for the reason line ("implausible movement samples").
	Summary: string,
	Strikes: number,
	WindowSeconds: number,
	-- Spec seam: replaces ModerationSystem.ReportAutomated.
	Report: ((subject: Subject, reasonCode: string, reason: string) -> ())?,
}

export type Ledger = typeof(setmetatable(
	{} :: {
		Config: Config,
		Stamps: { [Subject]: { { At: number, Weight: number } } },
		Flagged: { [Subject]: boolean },
	},
	SuspicionLedger
))

function SuspicionLedger.New(config: Config): Ledger
	assert(config.Strikes >= 1, "SuspicionLedger needs a positive strike threshold")
	return setmetatable({ Config = config, Stamps = {}, Flagged = {} }, SuspicionLedger)
end

-- Drops strikes older than the window and returns the weighted count left.
local function prune(list: { { At: number, Weight: number } }, now: number, windowSeconds: number): number
	local write = 1
	local total = 0
	for read = 1, #list do
		local stamp = list[read]
		if now - stamp.At <= windowSeconds then
			list[write] = stamp
			write += 1
			total += stamp.Weight
		end
	end
	for index = #list, write, -1 do
		list[index] = nil
	end
	return total
end

-- The weighted strikes `subject` has inside the window at `now`.
function SuspicionLedger.Count(self: Ledger, subject: Subject, now: number): number
	local list = self.Stamps[subject]
	return if list then prune(list, now, self.Config.WindowSeconds) else 0
end

-- Counts one strike (of `weight`, default 1) against `subject`. Returns true exactly once per session: the moment
-- the weighted count first reaches the threshold -- and, at that moment, reports the flag. `detail` is the last
-- thing seen, carried into the reason line.
function SuspicionLedger.Strike(self: Ledger, subject: Subject, now: number, detail: string?, weight: number?): boolean
	local list = self.Stamps[subject]
	if list == nil then
		list = {}
		self.Stamps[subject] = list
	end
	table.insert(list :: { { At: number, Weight: number } }, { At = now, Weight = math.max(weight or 1, 0) })
	local count = prune(list :: { { At: number, Weight: number } }, now, self.Config.WindowSeconds)
	if self.Flagged[subject] or count < self.Config.Strikes then
		return false
	end
	self.Flagged[subject] = true

	local config = self.Config
	local reason = `{config.Name}: {count} {config.Summary} within {config.WindowSeconds}s`
	if detail then
		reason ..= ` (last: {detail})`
	end
	logger:warn("Flagging player for automated review", {
		detector = config.Name,
		player = subject.Name,
		userId = subject.UserId,
		strikes = count,
		detail = detail,
	})
	local report = config.Report
	if report then
		report(subject, config.ReasonCode, reason)
	else
		ModerationSystem.ReportAutomated(subject.UserId, config.ReasonCode, reason)
	end
	return true
end

function SuspicionLedger.IsFlagged(self: Ledger, subject: Subject): boolean
	return self.Flagged[subject] == true
end

-- Forgets `subject` entirely -- bound to PlayerRemoving by each detector.
function SuspicionLedger.Release(self: Ledger, subject: Subject): ()
	self.Stamps[subject] = nil
	self.Flagged[subject] = nil
end

function SuspicionLedger.Reset(self: Ledger): ()
	table.clear(self.Stamps)
	table.clear(self.Flagged)
end

return SuspicionLedger
