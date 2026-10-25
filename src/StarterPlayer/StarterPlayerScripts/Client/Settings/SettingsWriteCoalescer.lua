--!strict
--[[
	SettingsWriteCoalescer.lua

	Owns: turning a burst of settings writes into one write per field. `Queue(remote, field, value)` keeps only
	the latest value for that (remote, field) and sends it once nothing has changed for `delaySeconds` (a
	trailing debounce), so five Stepper clicks in a second send the final value, not five calls the server's
	4/s bucket would drop the tail of.

	WHY THE CLIENT. SettingsSystem drops a limited call with no reply, and the client has already applied the
	change locally, so the screen showed the last click while the profile held an earlier one -- the setting
	"reverted" on rejoin. Only the client knows a burst is in progress, so it is the side that can wait for it
	to end.

	Does not own: applying a change locally (SettingsClient applies first, then queues), validating a value (the
	server re-validates and clamps), or writes that are not "set this field to the latest value" -- a rebind or
	a reset is a discrete event and still goes straight out.

	The clock is injected (`schedule`) so a spec drives it without sleeping; the default is task.delay.
]]

local SettingsWriteCoalescer = {}
SettingsWriteCoalescer.__index = SettingsWriteCoalescer

export type Flush = (remote: string, field: string, value: unknown) -> ()
export type Schedule = (seconds: number, callback: () -> ()) -> ()

type Pending = { Remote: string, Field: string, Value: unknown }

export type Coalescer = typeof(setmetatable(
	{} :: {
		flush: Flush,
		delaySeconds: number,
		schedule: Schedule,
		pending: { [string]: Pending },
		order: { string },
		-- Bumped on every Queue: a timer that fires for an older generation has been superseded and does nothing.
		generation: number,
	},
	SettingsWriteCoalescer
))

local function defaultSchedule(seconds: number, callback: () -> ()): ()
	task.delay(seconds, callback)
end

function SettingsWriteCoalescer.New(flush: Flush, delaySeconds: number, schedule: Schedule?): Coalescer
	return setmetatable({
		flush = flush,
		delaySeconds = delaySeconds,
		schedule = schedule or defaultSchedule,
		pending = {},
		order = {},
		generation = 0,
	}, SettingsWriteCoalescer)
end

-- Records `value` as the latest for (remote, field) and restarts the wait.
function SettingsWriteCoalescer.Queue(self: Coalescer, remote: string, field: string, value: unknown): ()
	local key = remote .. "\0" .. field
	if self.pending[key] == nil then
		table.insert(self.order, key)
	end
	self.pending[key] = { Remote = remote, Field = field, Value = value }

	self.generation += 1
	local mine = self.generation
	self.schedule(self.delaySeconds, function()
		if self.generation == mine then
			self:Flush()
		end
	end)
end

-- Sends everything pending now, oldest field first. Safe to call with nothing pending.
function SettingsWriteCoalescer.Flush(self: Coalescer): ()
	local order = self.order
	local pending = self.pending
	self.order = {}
	self.pending = {}
	for _, key in order do
		local entry = pending[key]
		self.flush(entry.Remote, entry.Field, entry.Value)
	end
end

function SettingsWriteCoalescer.HasPending(self: Coalescer): boolean
	return #self.order > 0
end

return SettingsWriteCoalescer
