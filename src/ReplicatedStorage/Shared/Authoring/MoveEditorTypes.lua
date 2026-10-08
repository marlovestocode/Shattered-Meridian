--!strict
--[[
	MoveEditorTypes.lua

	Owns: the Move Editor's wire contract -- what Server/Systems/MoveEditorSystem.lua answers with and
	what Client/DevTools/MoveEditor/MoveEditorClient.lua reads. The move itself is MoveTypes'; this file
	is only the envelope the editor needs around it.

	AN ENTRY IS THE SERVER'S WHOLE ANSWER ABOUT ONE MOVE, not just the move. The old editor fetched moves
	and then reconstructed, client-side, everything it did not know -- which half of the list a move lived
	in (by string-matching a reserved Category), whether it was saved (by remembering what it had last
	sent), and what it would actually do in a fight (it could not: the timeline AttackCatalog rebuilds
	from the clip was never shown anywhere). Each of those was a guess that could disagree with the
	server. An entry carries all three as facts, computed where they are true.

	Does not own: the move schema (MoveTypes), the remote names (Constants.MoveEditor.RemoteNames), or any
	behaviour.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

-- "Custom": authored in the editor, owned by MoveRegistryManager, deletable.
-- "Default": a weapon stage or standalone attack from CombatConstants, projected by DefaultMoveRegistry;
-- editable through an override layer, never deletable -- Discard reverts it to its built self.
export type MoveSource = "Custom" | "Default"

-- What the swing will ACTUALLY do once AttackCatalog has synced it to its clip -- the numbers a player
-- feels, which differ from the authored ones whenever the clip carries a strike marker or a length.
export type EffectiveTiming = {
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	Cooldown: number,
	-- The clip's playback rate (weapon speed x string tempo, or a borrowed clip's retime).
	PlaybackSpeed: number,
	-- The clip the swing plays: the move's own, or the one Shared/Attack/AttackAnimations resolves.
	AnimationId: string,
	-- The clip's length in swing time, or nil while it is unknown (not authored, or not read yet).
	ClipSeconds: number?,
	-- Where the clip's strike marker (Hit / AttackM<n>) lands in swing time, spawn delay included -- the
	-- instant the hitbox opens when the marker times it. nil when the clip carries none or is unread.
	StrikeSeconds: number?,
}

-- Fighting-game frame data and the balance numbers an author tunes against, computed on the server
-- (Server/Systems/Support/MoveBalance.lua) from the EFFECTIVE timeline and the live damage/defence
-- constants. Typed here because the client renders it; the module that fills it is server-only.
--
-- Every "hits to" count is nil when the answer is "never" (zero damage, zero posture, a weight class
-- that drains nothing) -- nil rather than math.huge so the value survives the remote unambiguously.
export type FrameRange = { Min: number, Max: number }

export type Balance = {
	FrameRate: number,
	StartupFrames: number,
	ActiveFrames: number,
	RecoveryFrames: number,
	TotalFrames: number,
	CooldownFrames: number,
	-- Attacker's advantage once the defender can act again. Min assumes contact on the FIRST active
	-- frame, Max on the LAST (a "meaty" hit).
	OnHitFrames: FrameRange,
	-- There is no blockstun: a blocked defender acts at once, so this is only ever minus -- how long the
	-- attacker is still committed after the block, i.e. the blocker's punish window.
	OnBlockFrames: FrameRange,
	-- Against the player health pool, at combo stage 1 / climbing one stage per hit.
	HitsToKill: number?,
	StringHitsToKill: number?,
	BlockedHitsToBreakGuard: number?,
	StaggeredBlocksToBreakGuard: number?,
	CleanHitsToBreakGuard: number?,
	DamagePerSecond: number,
}

-- The authored numbers that make the authored timeline equal the clip-synced one (Timing tab's "Match
-- timing to clip"). Windup is the marker's when the clip has one, else the authored windup unchanged.
export type ClipMatch = {
	WindupSeconds: number,
	RecoverySeconds: number,
}

export type MoveEntry = {
	Move: MoveTypes.MoveDefinition,
	Source: MoveSource,
	-- The browser section this move files under: "Arts", a custom Category (or "Custom"), a weapon id,
	-- or "Standalone".
	Group: string,
	-- The fingerprint (MoveTypes.Fingerprint) of the move as it is PERSISTED -- what a restart would load.
	-- A draft whose own fingerprint differs has unsaved work. nil for a custom move that was previewed
	-- into existence but never saved.
	SavedFingerprint: string?,
	-- The move as it is persisted, sent ONLY while it differs from Move (an unsaved edit is live) -- what the
	-- editor's changed-field dots compare against. nil while the two agree (Move is then the saved move) and
	-- for a never-saved move.
	Saved: MoveTypes.MoveDefinition?,
	-- Default moves only: an override is live, so the move differs from its CombatConstants self.
	Overridden: boolean,
	-- A file under Server/Combat/AuthoredMoves ships this move (or, for a Default move, its retune) in the
	-- game's source -- see Server/Combat/AuthoredMoveLibrary.lua.
	Shipped: boolean,
	-- Default weapon moves only: the stage of the string (Basic, Heavy, Finisher, Launcher, Air,
	-- AirFinisher) -- what bulk edit filters a weapon group by. nil for custom and standalone moves.
	Stage: string?,
	-- nil when the catalogue could not resolve the move (which is itself worth showing).
	Effective: EffectiveTiming?,
	-- Frame data and balance numbers. nil exactly when Effective is.
	Balance: Balance?,
	-- nil when the clip's length is unknown (no clip, unread, or a borrowed clip -- which is retimed to
	-- the move, not the reverse).
	ClipMatch: ClipMatch?,
	-- Plain-language facts an author should know before trusting the numbers: a Box whose size the blade
	-- replaces, a hitbox that outlasts its clip, a prerequisite that does not exist. Never errors -- a
	-- move with notes still validates, saves and swings.
	Notes: { string },
}

-- The art trees are not sent: they are Shared/ArtConstants.ArtTrees, which the client already has.
export type OpenResult = {
	Success: boolean,
	Reason: string?,
	Entries: { MoveEntry }?,
}

export type EntryResult = {
	Success: boolean,
	Reason: string?,
	Entry: MoveEntry?,
}

-- Discard's answer: a custom move is simply gone (Entry nil); a Default move comes back as its reverted
-- self.
export type DiscardResult = {
	Success: boolean,
	Reason: string?,
	Entry: MoveEntry?,
}

-- Bulk edit's request: which fields to multiply, by how much (1 = unchanged; absent = untouched).
export type BulkScaleFactors = {
	WindupSeconds: number?,
	ActiveSeconds: number?,
	RecoverySeconds: number?,
	Cooldown: number?,
	Damage: number?,
	PostureDamage: number?,
}

export type BulkScaleRequest = {
	Group: string,
	-- A Default group's stage; ignored for a custom group. nil = every stage.
	Stage: string?,
	Scale: BulkScaleFactors,
	-- true persists each scaled move through the Save path; false leaves them live and unsaved.
	Save: boolean,
}

export type BulkScaleResult = {
	Success: boolean,
	Reason: string?,
	-- Every scaled move's new entry.
	Entries: { MoveEntry }?,
}

-- One saved version as the Tools tab lists it. The stored record itself stays on the server.
export type HistoryVersion = {
	Version: number,
	-- os.time() of the save.
	SavedAt: number,
	AdminName: string,
	-- The authored fields that differ from the version before it ("WindupSeconds 0.30->0.26, ...").
	Summary: string,
}

export type HistoryResult = {
	Success: boolean,
	Reason: string?,
	-- Newest first. Empty for a move that was never saved since history began.
	Versions: { HistoryVersion }?,
}

-- The Studio source remotes' answer.
export type SourceResult = {
	Success: boolean,
	Reason: string?,
	-- The file written or removed, repo-relative.
	Path: string?,
	-- The move's entry afterwards (Write/Remove).
	Entry: MoveEntry?,
	-- The generated module text (Export).
	Source: string?,
}

export type ActionResult = {
	Success: boolean,
	Reason: string?,
}

return {}
