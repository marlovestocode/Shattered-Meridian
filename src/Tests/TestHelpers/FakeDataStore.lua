--!strict
--[[
	FakeDataStore.lua

	An in-memory stand-in for the four DataStore methods a System uses (GetAsync, SetAsync, UpdateAsync, RemoveAsync),
	for specs of code that takes its store as an argument (Server/WorldArchitect/WorldPersistence and
	WorldArchitectSystem.ConfigureForTesting). The harness cannot reach real DataStores.

	Values are deep-copied through JSON on the way in and out, so a spec sees exactly what a real store would hand back
	(no Vector3s, no shared tables). `FailWhen(predicate)` makes matching calls throw, for partial-failure cases; a
	`NoRetry` runner goes with it so a spec does not sit through DataStoreRetry's backoff waits.
]]

local HttpService = game:GetService("HttpService")

local FakeDataStore = {}

export type Store = {
	Data: { [string]: string },
	Calls: { { Method: string, Key: string } },
	FailWhen: (predicate: ((method: string, key: string) -> boolean)?) -> (),
	GetAsync: (self: any, key: string) -> any,
	SetAsync: (self: any, key: string, value: any) -> any,
	UpdateAsync: (self: any, key: string, transform: (any) -> any) -> any,
	RemoveAsync: (self: any, key: string) -> any,
}

function FakeDataStore.New(): Store
	local failing: ((string, string) -> boolean)? = nil
	local store = {} :: Store
	store.Data = {}
	store.Calls = {}

	local function check(method: string, key: string)
		table.insert(store.Calls, { Method = method, Key = key })
		if failing and (failing :: (string, string) -> boolean)(method, key) then
			error(`FakeDataStore: scripted failure of {method}({key})`)
		end
	end
	local function read(key: string): any
		local raw = store.Data[key]
		return if raw == nil then nil else HttpService:JSONDecode(raw)
	end

	function store.FailWhen(predicate: ((string, string) -> boolean)?)
		failing = predicate
	end
	function store.GetAsync(_self: any, key: string): any
		check("GetAsync", key)
		return read(key)
	end
	function store.SetAsync(_self: any, key: string, value: any): any
		check("SetAsync", key)
		store.Data[key] = HttpService:JSONEncode(value)
		return nil
	end
	function store.UpdateAsync(_self: any, key: string, transform: (any) -> any): any
		check("UpdateAsync", key)
		local updated = transform(read(key))
		if updated ~= nil then
			store.Data[key] = HttpService:JSONEncode(updated)
		end
		return updated
	end
	function store.RemoveAsync(_self: any, key: string): any
		check("RemoveAsync", key)
		local old = read(key)
		store.Data[key] = nil
		return old
	end
	return store
end

-- A retry runner that tries once and never waits.
function FakeDataStore.NoRetry(_name: string, attempt: () -> any): (boolean, any, string?)
	local ok, result = pcall(attempt)
	if ok then
		return true, result, nil
	end
	return false, nil, "StorageError"
end

function FakeDataStore.KeyCount(store: Store, prefix: string): number
	local count = 0
	for key in store.Data do
		if string.sub(key, 1, #prefix) == prefix then
			count += 1
		end
	end
	return count
end

return FakeDataStore
