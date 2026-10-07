--!strict
--[[
	CallbackList.lua

	Owns: one synchronous subscriber list -- Connect hands back a disconnect function, Fire calls every
	live subscriber in connection order, each inside its own pcall, and an error is logged rather than
	thrown. The shape every combat extension point already had (DamageSystem.OnApplied,
	DefenseSystem.OnResolved, HitboxEngine.OnHit/OnProjectileEvents, DomainSystem.OnPhaseChanged, the
	attack layer's three signals, AttackInputClient's three, LocalCombatState's two and LockOnController's one), written out by hand at each one: an
	array, a table.insert, a table.find + table.remove disconnect, and a pcall-and-log loop.

	WHY IT EXISTS: the hand-written copies shared one latent bug. A disconnect is a table.remove from
	the array being iterated, so a subscriber that unsubscribed itself (or another) from inside a
	dispatch made that dispatch SKIP the subscriber after it -- one consumer silently missing one
	outcome, with no error anywhere. Here the array is copy-on-write: Connect and a disconnect build a
	new array, Fire walks whichever array was current when it started, and a subscriber disconnected
	mid-dispatch is skipped by its own Connected flag. So Fire allocates nothing (HitboxEngine fires
	once per contact, inside the Heartbeat) and no mutation during a dispatch can change who hears it.

	SYNCHRONOUS ON PURPOSE, and that is why it is not a BindableEvent (ChangeNotifier's and
	GameplayEvents' primitive). Every combat layer depends on its subscribers having run before the
	next line: DamageSystem announces a hit BEFORE the health write so kill credit can be attributed
	(see applyOutcome), and the engine's OnHit stream must stay in SampleTime order. A BindableEvent's
	deferred handlers give neither.

	Does not own: what a subscriber is allowed to do, ordering between two lists, or any lifetime --
	the owning module calls Clear from its spec-only Reset, exactly as it used to table.clear its
	array.
]]

local Logger = require(script.Parent.Logger)

export type CallbackList<A...> = {
	-- Subscribes `callback`. The returned function unsubscribes it, and is safe to call more than once.
	Connect: (self: CallbackList<A...>, callback: (A...) -> ()) -> () -> (),
	-- Calls every live subscriber with these arguments, in connection order.
	Fire: (self: CallbackList<A...>, A...) -> (),
	-- How many subscribers are connected. For a spec, and for skipping work nobody would hear.
	Count: (self: CallbackList<A...>) -> number,
	-- Drops every subscriber. Spec-only Resets call this.
	Clear: (self: CallbackList<A...>) -> (),
}

local CallbackList = {}

-- `logger` is the owning module's scope; `label` names the extension point in the error line
-- ("DamageSystem.OnApplied"), which is what tells a reader which list the failing consumer was on.
function CallbackList.New<A...>(logger: Logger.LoggerScope, label: string): CallbackList<A...>
	type Record = { Callback: (A...) -> (), Connected: boolean }

	local records: { Record } = {}
	local message = `A {label} consumer errored`

	local list = {} :: CallbackList<A...>

	function list.Connect(_self: CallbackList<A...>, callback: (A...) -> ()): () -> ()
		local record: Record = { Callback = callback, Connected = true }
		local nextRecords = table.clone(records)
		table.insert(nextRecords, record)
		records = nextRecords
		return function()
			if not record.Connected then
				return
			end
			record.Connected = false
			local remaining = table.clone(records)
			local index = table.find(remaining, record)
			if index then
				table.remove(remaining, index)
			end
			records = remaining
		end
	end

	function list.Fire(_self: CallbackList<A...>, ...: A...): ()
		-- The array current at the start of this dispatch. Connect and disconnect replace `records`
		-- rather than editing it, so nothing done during the loop can shift what this walks.
		for _, record in records do
			if not record.Connected then
				continue
			end
			-- Cast for pcall's sake: the solver cannot thread a generic pack through it.
			local ok, err = pcall(record.Callback :: (...any) -> (), ...)
			if not ok then
				logger:error(message, { errorMessage = tostring(err) })
			end
		end
	end

	function list.Count(_self: CallbackList<A...>): number
		return #records
	end

	function list.Clear(_self: CallbackList<A...>): ()
		for _, record in records do
			record.Connected = false
		end
		records = {}
	end

	return list
end

return CallbackList
