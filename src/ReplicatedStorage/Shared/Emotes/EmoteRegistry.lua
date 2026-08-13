--!strict
--[[
	EmoteRegistry.lua

	Owns: pure, read-only query/validation functions over EmoteDefinitions.lua's static content
	table. No Instance/Player coupling at all -- every function here is requirable and testable from
	a plain TestEZ spec with no game services, the same "pure logic gets its own module" precedent
	Server/Combat/MoveRegistryManager.lua establishes for the Move Creation System (see that module's
	header for the Manager/System split this mirrors: this file is the "pure" half, Server/Systems/
	EmoteUnlockService.lua is the per-player "wraps it with Player-keyed state" half).

	Validate is the one gate a MoveRegistryManager-style future authoring tool (there is no admin
	editor for emotes today -- EmoteDefinitions.lua is hand-authored, not live-editable) would run an
	untrusted candidate through before it could reach the live roster; kept here now, ahead of that
	tool existing, so EmoteDefinitions.lua's own hand-authored entries have somewhere to be checked
	against by this module's own regression tests.

	Does not own: granting/tracking which player has unlocked which entry (EmoteUnlockService.lua),
	or deciding whether a request to play one is currently legal given a player's live combat/
	movement state (EmoteSystem.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local EmoteDefinitions = require(script.Parent.EmoteDefinitions)

local EmoteRegistry = {}

local function toLookupSet(list: { string }): { [string]: true }
	local set: { [string]: true } = {}
	for _, value in list do
		set[value] = true
	end
	return set
end

-- Built once at module load from EmoteConstants.Categories/UnlockTypes -- see that file's own header
-- for why a runtime allow-list has to live alongside the compile-time-only Types.EmoteCategory/
-- EmoteUnlockType unions.
local KNOWN_CATEGORIES = toLookupSet(EmoteConstants.Categories)
local KNOWN_UNLOCK_TYPES = toLookupSet(EmoteConstants.UnlockTypes)

function EmoteRegistry.Exists(emoteId: string): boolean
	return EmoteDefinitions[emoteId] ~= nil
end

function EmoteRegistry.Get(emoteId: string): Types.EmoteDefinition?
	return EmoteDefinitions[emoteId]
end

-- Returns the live table directly, not a copy -- EmoteDefinitions.lua is static, hand-authored
-- content with no mutating API (unlike MoveRegistryManager.List's deep-copy contract, which exists
-- specifically to protect a LIVE, Upsert-able registry from an external caller corrupting it).
-- Callers must not mutate the result.
function EmoteRegistry.GetAll(): { [Types.EmoteId]: Types.EmoteDefinition }
	return EmoteDefinitions
end

function EmoteRegistry.GetByCategory(category: Types.EmoteCategory): { Types.EmoteDefinition }
	local result: { Types.EmoteDefinition } = {}
	for _, definition in EmoteDefinitions do
		if definition.Category == category then
			table.insert(result, definition)
		end
	end
	return result
end

-- Every EmoteId whose Unlock.Type == "Default" -- a fresh SET (not an array), matching Types.
-- PlayerProfile.unlockedEmoteIds' own shape exactly. Shared by two callers that both need "every
-- emote granted from the start" without either one owning a hardcoded list of ids: PlayerDataSystem.
-- CreateDefaultProfile (a brand-new profile starts with this whole set already unlocked) and
-- EmoteUnlockService's own join-time backfill (an OLDER save that predates a newly-authored Default
-- emote still ends up with it). Deliberately lives here rather than on EmoteUnlockService itself --
-- PlayerDataSystem cannot depend on EmoteUnlockService (that System depends on PlayerDataSystem, and
-- a dependency cycle isn't an option), but both may freely depend on this pure Shared module.
function EmoteRegistry.GetDefaultUnlockedIds(): { [Types.EmoteId]: true }
	local result: { [Types.EmoteId]: true } = {}
	for id, definition in EmoteDefinitions do
		if definition.Unlock.Type == "Default" then
			result[id] = true
		end
	end
	return result
end

-- The one strict gate a candidate EmoteDefinition-shaped table passes through -- mirrors
-- MoveRegistryManager.Validate's error-message style ("InvalidXxx"/"MissingXxx" strings) but returns
-- (boolean, string?) rather than (definition?, string?), per this module's own public API: there is
-- no live registry here for a validated candidate to be Upserted into, so there is nothing useful to
-- hand back beyond "did it pass."
function EmoteRegistry.Validate(definition: unknown): (boolean, string?)
	if typeof(definition) ~= "table" then
		return false, "InvalidShape"
	end
	local raw = definition :: { [string]: unknown }

	if typeof(raw.Id) ~= "string" or (raw.Id :: string) == "" then
		return false, "InvalidId"
	end
	if typeof(raw.DisplayName) ~= "string" or (raw.DisplayName :: string) == "" then
		return false, "InvalidDisplayName"
	end
	if raw.Description ~= nil and typeof(raw.Description) ~= "string" then
		return false, "InvalidDescription"
	end
	if typeof(raw.AnimationId) ~= "string" then
		return false, "InvalidAnimationId"
	end
	if typeof(raw.Icon) ~= "string" then
		return false, "InvalidIcon"
	end
	if typeof(raw.Category) ~= "string" or not KNOWN_CATEGORIES[raw.Category :: string] then
		return false, "InvalidCategory"
	end
	if typeof(raw.Loop) ~= "boolean" then
		return false, "InvalidLoop"
	end
	if raw.Duration ~= nil and typeof(raw.Duration) ~= "number" then
		return false, "InvalidDuration"
	end
	if typeof(raw.MovementLocked) ~= "boolean" then
		return false, "InvalidMovementLocked"
	end
	if typeof(raw.CombatAllowed) ~= "boolean" then
		return false, "InvalidCombatAllowed"
	end
	if typeof(raw.CancelOnDamage) ~= "boolean" then
		return false, "InvalidCancelOnDamage"
	end

	if typeof(raw.Unlock) ~= "table" then
		return false, "InvalidUnlock"
	end
	local rawUnlock = raw.Unlock :: { [string]: unknown }
	if typeof(rawUnlock.Type) ~= "string" or not KNOWN_UNLOCK_TYPES[rawUnlock.Type :: string] then
		return false, "InvalidUnlockType"
	end
	if rawUnlock.Id ~= nil and typeof(rawUnlock.Id) ~= "string" then
		return false, "InvalidUnlockId"
	end
	if rawUnlock.Pool ~= nil and typeof(rawUnlock.Pool) ~= "string" then
		return false, "InvalidUnlockPool"
	end
	if rawUnlock.Type == "Roll" and (rawUnlock.Pool == nil or (rawUnlock.Pool :: string) == "") then
		return false, "MissingUnlockPool"
	end

	return true, nil
end

return EmoteRegistry
