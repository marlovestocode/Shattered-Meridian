--!strict
--[[
	ChangeNotifier.lua

	Owns: one narrow job -- "compare a per-player value to its last-known state, and fire a
	BindableEvent only when it actually changed." Extracted (2026-07, Chief Architect's CombatState
	decomposition follow-up) from three hand-rolled copies of exactly this check that used to live
	inline in CombatSystem.lua's onHeartbeat (syncFinisherReady/syncRootControlLocked/syncInCombat),
	each independently doing "compute the live value, compare it against a stored `*Synced` flag,
	only act on a transition." Infra-layer, not gameplay -- belongs in ReplicatedStorage/Shared
	alongside RateLimiter.lua (a per-player-per-second call budget, the same "one instance per
	category, keyed by Player" shape this module copies) rather than inside any System, per this
	project's dependency-direction rule that gameplay depends on infrastructure, never the reverse.

	Uses a BindableEvent as the underlying fire mechanism -- this project's own established
	server-internal signal/pub-sub primitive (see Server/Events/GameplayEvents.lua, which wraps the
	same primitive for cross-System gameplay signals, for the existing convention this matches) -- rather than
	inventing a second notification shape. A caller subscribes once (Instance.Changed.Event:Connect(
	...)), typically at Init time, and calls Update(player, liveValue) every tick thereafter; Update
	only fires Changed on an actual transition, mirroring the exact "write only on change" contract
	each of the three original call sites already implemented by hand.

	The FIRST Update() call for a given player never fires Changed, regardless of the value passed --
	there is no "previous" value to have transitioned away from yet, so recording a baseline isn't
	itself a change. This matches every one of the three original use cases, whose real starting
	condition (finisher not ready, root control not locked, not in combat) is always the same
	"nothing to report yet" state a fresh client already assumes -- see Update's own comment.

	Does NOT own: what the value means, what side effect firing should have (remote/Attribute/log --
	entirely the connected callback's job), or the value itself as authoritative state (the CALLER's
	own field -- e.g. a live per-player state record -- remains the single source of truth; this
	module only remembers what was LAST reported, to decide whether to report again). This is
	explicitly NOT a general Signal/Store/reactive-state class -- the Chief Architect's own review
	rejected wrapping the combat state record itself in change-notification (a per-Heartbeat WalkSpeed
	resolver's hot path always wants the CURRENT value, not a subscription, so wrapping every field
	would be pure overhead with no benefit) -- this stays scoped to the handful of per-player
	PRESENTATION flags that already re-derive a boolean every tick and only care about edges, never
	applied preemptively to the timing fields a resolver reads, which stay plain field reads.

	WHAT THIS IS NOT FOR, written down because a duplication sweep flagged five "hand-rolled copies"
	of it and every one of them turned out to be a different shape. This module is specifically
	`{[Player]: T}`, compared with `==`, fanning out through a BindableEvent, with a Clear(player) that
	exists so PlayerRemoving cannot leak an entry. Those three properties are what it is; a comparison
	against a previous value is not, on its own, this.

	  * BlimpSystem's LastFuelPush and LastHelmPush compare compound RECORDS (three and four fields)
	    keyed by BLIMP. A table never compares `==` equal to another table, so migrating them would
	    mean flattening every push to a string or regeneralising this module -- widening it to fit
	    call sites whose inline answer is already two correct lines.
	  * DefenseSystem's PublishedState is keyed by Model, and HitboxEngine's HoldsMovementLock by
	    combatant Model. Both live on a per-registration record that already has its own lifecycle, so
	    the record IS the storage and there is nothing for Clear to protect against.
	  * QiSystem's lastSyncedCurrent is not an edge at all: it fires on "the interval has elapsed AND
	    the value changed", with a companion lastSyncAt this module has no concept of.
	  * RunSystem's stage compare reads a number off the per-player state record it already holds.
	    Routing it through here would add a SECOND {[Player]: number} table holding the same number.

	The one genuine adopter is EngagementSystem, and it is genuine for the reason above rather than by
	coincidence: per-player, scalar, edge-driven, and cleared on leave.
]]

local ChangeNotifier = {}
ChangeNotifier.__index = ChangeNotifier

export type ChangeNotifierInstance<T> = typeof(setmetatable(
	{} :: {
		lastKnown: { [Player]: T },
		Changed: BindableEvent,
	},
	ChangeNotifier
))

-- One independent per-player "last reported value" set, plus the BindableEvent fired (player:
-- Player, newValue: T) on a transition -- the same "one instance per category" shape RateLimiter.New
-- already establishes, just tracking a comparable value instead of a call budget.
function ChangeNotifier.New<T>(): ChangeNotifierInstance<T>
	return setmetatable({
		lastKnown = {},
		Changed = Instance.new("BindableEvent"),
	}, ChangeNotifier) :: any
end

-- Records `newValue` as the current value for `player` and fires Changed(player, newValue) only if
-- it differs from whatever was last recorded. Returns whether it fired, purely as a convenience for
-- a caller that wants to react inline instead of (or in addition to) connecting to Changed -- none
-- of this module's own three call sites in CombatSystem.lua need the return value, they all connect
-- to Changed instead, but a future caller with a single inline reaction shouldn't be forced to wire
-- up a whole Connect just to get it.
--
-- No previously-recorded value (this player's first Update call, or any call after Clear) never
-- fires -- see this file's own header for why "establishing a baseline" must not itself count as a
-- change.
function ChangeNotifier.Update<T>(self: ChangeNotifierInstance<T>, player: Player, newValue: T): boolean
	local previous = self.lastKnown[player]
	self.lastKnown[player] = newValue
	if previous == nil or previous == newValue then
		return false
	end
	self.Changed:Fire(player, newValue)
	return true
end

-- Drops `player`'s last-known value -- call on PlayerRemoving, same reason RateLimiter.Clear exists:
-- without it, a per-player table here accumulates an entry for every player who has ever connected,
-- for the lifetime of the server.
function ChangeNotifier.Clear<T>(self: ChangeNotifierInstance<T>, player: Player): ()
	self.lastKnown[player] = nil
end

return ChangeNotifier
