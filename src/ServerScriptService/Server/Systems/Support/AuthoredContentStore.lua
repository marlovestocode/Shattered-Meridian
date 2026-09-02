--!strict
--[[
	Systems/Support/AuthoredContentStore.lua

	Owns: the index record every admin-authored content type keeps alongside its per-item DataStore
	keys -- the small `{ <field> = { id, id, ... } }` document maintained through UpdateAsync, because
	DataStore has no native "list all keys" and an author-written content count is small (tens, not
	thousands).

	MoveEditorSystem and KitEditorSystem each held both halves of this, byte-identical apart from two
	things: the field name inside the record, and the prefix on the log line. Everything else -- the
	defensive decode of whatever the old document turned out to be, the already-present scan, the
	rebuild-and-return -- was the same twenty lines twice.

	THE FIELD NAME IS A PARAMETER, AND THAT IS THE WHOLE RISK OF THIS MODULE. It is not a detail: it
	is the key inside a PERSISTED record, so `Ids` and `MoveIds` are not interchangeable and never
	will be. Passing it explicitly at the call site is deliberately louder than the two copies were,
	where it was buried mid-function and a careless merge of the two would have silently renamed one
	System's index -- orphaning it, so every authored move or bloodline vanished from the editor's
	list on the next boot while the records themselves sat there untouched. The literal at each call
	site must match that System's own hydration reader; there are exactly two, and they are named in
	each caller's comment.

	Takes `withRetry` rather than opening its own: each System already binds one through
	Shared/DataStoreRetry.Scoped against its own logger, and the retry/exhaustion lines must keep
	attributing to the System that owns the store, not to this helper.

	NOT A MERGE OF THE TWO SYSTEMS, and deliberately only the storage/index layer. Their schemas,
	their validation, their remotes and their hydration genuinely differ -- MoveEditorSystem
	reconstructs Roblox value types out of a stored record and KitEditorSystem's schema has none to
	reconstruct, which is a real difference in kind, not duplication waiting to be collapsed.

	Does not own: the per-item records (each System's own encode/decode), the store handles, when an
	index is rebuilt, or what a failed index update MEANS -- both callers log it and carry on,
	because a saved item that fails to list is recoverable and a refused save is not.
]]

local AuthoredContentStore = {}

-- The shape Shared/DataStoreRetry.Scoped hands back. Named here so the parameter below reads as one
-- thing rather than a bare function type inline.
export type RetryRunner = (operationName: string, attempt: () -> ()) -> (boolean, any, string?)

-- Reads whatever is currently under `field` in `old`, keeping only the strings and dropping anything
-- else. Defensive rather than trusting: this document has been written by an older build of this
-- codebase and, on a shared DataStore, potentially by a build that is still running.
local function existingIds(old: unknown, field: string, exclude: string?): { string }
	local ids: { string } = {}
	if typeof(old) ~= "table" then
		return ids
	end
	local raw = (old :: { [string]: any })[field]
	if typeof(raw) ~= "table" then
		return ids
	end
	for _, existingId in ipairs(raw) do
		if typeof(existingId) == "string" and existingId ~= exclude then
			table.insert(ids, existingId)
		end
	end
	return ids
end

-- Adds `id` to the index document at `indexKey`, if it is not already there.
--
-- UpdateAsync rather than Get-then-Set for atomicity: two admins saving different items at once
-- would otherwise race, and the loser's id would be dropped from the index while its record stayed
-- on disk.
function AuthoredContentStore.AddToIndex(
	withRetry: RetryRunner,
	label: string,
	store: DataStore,
	indexKey: string,
	field: string,
	id: string
): boolean
	local ok = withRetry(`{label} AddToIndex UpdateAsync ({indexKey})`, function()
		store:UpdateAsync(indexKey, function(old: unknown)
			local ids = existingIds(old, field)
			local alreadyPresent = false
			for _, existingId in ipairs(ids) do
				if existingId == id then
					alreadyPresent = true
					break
				end
			end
			if not alreadyPresent then
				table.insert(ids, id)
			end
			return { [field] = ids }
		end)
	end)
	return ok
end

-- Drops `id` from the index document at `indexKey`. Rebuilds the list without it rather than
-- searching for a position, so an index that somehow held the id twice comes back clean.
function AuthoredContentStore.RemoveFromIndex(
	withRetry: RetryRunner,
	label: string,
	store: DataStore,
	indexKey: string,
	field: string,
	id: string
): boolean
	local ok = withRetry(`{label} RemoveFromIndex UpdateAsync ({indexKey})`, function()
		store:UpdateAsync(indexKey, function(old: unknown)
			return { [field] = existingIds(old, field, id) }
		end)
	end)
	return ok
end

return AuthoredContentStore
