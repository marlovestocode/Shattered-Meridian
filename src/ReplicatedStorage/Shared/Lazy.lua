--!strict
--[[
	Lazy.lua

	Owns: "build this once, the first time anyone actually needs it, and hand back the same thing
	forever after." A three-line idea that exists as a module for one reason -- it is the seam that
	lets a caller be handed something expensive WITHOUT it having been built yet, and that seam has
	to be a type the handing-over code can name.

	Built for the admin UI. Client/UI/init.lua mounted the Dev Menu, Move Editor and Live Console
	screens on the synchronous boot path, for every player, including the overwhelming majority who
	will never pass the admin check -- roughly 257 Instances built and kept resident to be invisible.
	The obvious fix (don't mount them) collides with how those screens are handed out: UI.Mount()
	returns one handles table, and Main.client.lua passes each screen's handle to the client module
	that drives it. Making the handle itself optional would push a nil-check into every one of those
	modules; making Main.client.lua do the auth round-trip would move an admin concern into the boot
	sequence. A Lazy is the third option: the handles table still has an entry, the entry is still
	non-nil and still typed, and the screen is not built until the module that owns it decides the
	player has earned it.

	NOT A GENERAL MEMOIZE. It takes no arguments and caches no keyed results -- one thunk, one value.
	`build` MUST NOT YIELD: this is deliberately not thread-safe, because making it so would mean
	either a lock (and a caller that blocks on someone else's build) or a queue, and every real use
	here is a single thread deciding to force a value. Two threads racing a yielding `build` would
	both build. Reentrancy from inside `build` itself is caught and asserted rather than silently
	recursing forever.

	Does NOT own: whether forcing is the right thing to do (the caller's gate), teardown of whatever
	got built (Shared/Trove.lua), or any notion of invalidation -- a Lazy resolves exactly once and
	never goes back.
]]

local Lazy = {}

export type Lazy<T> = {
	-- Builds on first call, returns the identical value on every call after.
	Get: () -> T,
	-- Whether Get() has already run. Lets a caller ask "does this exist yet" WITHOUT bringing it into
	-- existence to find out -- which a plain thunk cannot express, and which the Live Console needs:
	-- a server log batch that arrives for a panel nobody has opened must be dropped, not answered by
	-- mounting the panel to append it to.
	IsResolved: () -> boolean,
}

-- `name` is only ever used in the reentrancy assertion -- a build that forces itself is a genuine
-- ordering bug, and "which one" is the entire useful content of that message.
function Lazy.new<T>(name: string, build: () -> T): Lazy<T>
	local resolved = false
	local building = false
	local value: T = nil :: any

	local function Get(): T
		if resolved then
			return value
		end
		assert(not building, `Lazy("{name}"):Get() called from inside its own build function`)
		building = true
		value = build()
		building = false
		resolved = true
		return value
	end

	local function IsResolved(): boolean
		return resolved
	end

	return { Get = Get, IsResolved = IsResolved }
end

return Lazy
