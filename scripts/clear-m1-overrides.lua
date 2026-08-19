-- One-off admin script: clears the Move Editor's saved DataStore overrides for the six M1 (Basic)
-- stages so the live game falls back to Constants.lua's 6.5 Damage instead of a stale saved value.
--
-- Run this from Roblox Studio's Command Bar (View > Command Bar) while the place you want fixed is
-- open, with "Enable Studio Access to API Services" turned on (Game Settings > Security) -- that's
-- what lets DataStoreService work from Studio at all. Paste the whole file in and hit Enter.
--
-- Mirrors MoveEditorSystem.lua's own key scheme exactly (defaultOverrideKey/mainStore):
--   DataStore name: StorageConfig.CustomMoveDataStoreName ("CustomMoves_v1")
--   Key format:      "DefaultOverride_" .. moveId

local DataStoreService = game:GetService("DataStoreService")
local store = DataStoreService:GetDataStore("CustomMoves_v1")

local moveIds = {
	"default:Primary:Basic:1",
	"default:Primary:Basic:2",
	"default:Primary:Basic:3",
	"default:Secondary:Basic:1",
	"default:Secondary:Basic:2",
	"default:Secondary:Basic:3",
}

for _, moveId in ipairs(moveIds) do
	local key = "DefaultOverride_" .. moveId
	local ok, err = pcall(function()
		store:RemoveAsync(key)
	end)
	if ok then
		print("Cleared override:", key)
	else
		warn("FAILED to clear override:", key, err)
	end
end

print("Done. Restart the server (or wait for the next boot) for DefaultMoveRegistry to read Constants.lua's 6.5 with nothing left to override it.")
