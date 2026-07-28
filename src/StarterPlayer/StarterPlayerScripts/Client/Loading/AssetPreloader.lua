--!strict
--[[
	AssetPreloader.lua

	Owns: the boot-time "block until every known client asset is ready" gate. Aggregates the
	instances each domain module already builds for its own purposes (Client/FX/SoundManager.lua's
	pooled Sound instances, Client/FX/CombatAnimator.lua's and Client/FX/FlightAnimator.lua's
	Animation templates) plus the one standalone VFX texture id (Constants.FX.MovementDust.Texture),
	dedupes them by underlying asset id, and runs ONE ContentProvider:PreloadAsync call across the
	combined list -- one real progress count across every asset category, not a separate fire-and-
	forget preload per module.

	Deliberately does NOT rebuild Sound/Animation instances from Constants.lua ids itself -- each
	domain module is already the one source of truth for how its own instances get constructed
	(pooling, naming, etc.); a second construction path here would just duplicate that and risk
	drifting out of sync with it. This module only knows how to ask for, combine, and preload.

	Fusion-free by design (same "Instance-agnostic, testable without a DataModel" reasoning as
	Client/FX/FXPool.lua) -- Client/Loading/LoadingClient.lua is the Fusion-aware layer that turns
	this module's onProgress callback into reactive state a screen can bind to.

	Does not own: what happens while loading (LoadingClient.lua owns mounting/tearing down the
	Loading screen), or any server-side readiness signal (there isn't one -- every asset preloaded
	here is purely client-rendered; see this session's own planning notes for why a client/server
	readiness handshake is explicitly out of scope).
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local SoundManager = require(script.Parent.Parent.FX.SoundManager)
local CombatAnimator = require(script.Parent.Parent.FX.CombatAnimator)
local FlightAnimator = require(script.Parent.Parent.FX.FlightAnimator)

local logger = Logger.scope("AssetPreloader")

local AssetPreloader = {}

-- Sound/Animation instances carry their own asset id as a property; a raw content-id string (the
-- one MovementDust.Texture entry) IS its own key. Anything else shouldn't reach this function given
-- the three known sources above, but falls back to GetFullName() rather than erroring -- a display-
-- only preload pass degrading gracefully, per this codebase's own error-handling philosophy, beats
-- hard-failing boot over an unrecognized instance type.
local function assetKey(item: Instance | string): string
	if typeof(item) == "string" then
		return item
	elseif item:IsA("Sound") then
		return item.SoundId
	elseif item:IsA("Animation") then
		return item.AnimationId
	end
	return item:GetFullName()
end

-- Builds the deduplicated preload manifest -- exposed separately from Run() so a caller (or a
-- future test) can inspect the manifest (e.g. its count) without triggering a real
-- ContentProvider:PreloadAsync call.
function AssetPreloader.BuildManifest(): { Instance | string }
	local raw: { Instance | string } = {}
	for _, instance in SoundManager.GetPreloadInstances() do
		table.insert(raw, instance)
	end
	for _, instance in CombatAnimator.GetPreloadInstances() do
		table.insert(raw, instance)
	end
	for _, instance in FlightAnimator.GetPreloadInstances() do
		table.insert(raw, instance)
	end
	-- The one standalone texture id not owned by a domain module with its own instance-pooling
	-- concern -- Constants.FX.MovementDust.lua's own header note on why nothing else instances this
	-- eagerly. Skipped like every other still-unauthored placeholder if ever set back to "".
	if Constants.FX.MovementDust.Texture ~= "" then
		table.insert(raw, Constants.FX.MovementDust.Texture)
	end

	-- Dedupe by underlying asset id -- Constants.Flight.AnimationIds' six entries currently share one
	-- placeholder id, and preloading the same real asset six times would inflate the progress total
	-- without covering anything new.
	local seen: { [string]: boolean } = {}
	local manifest: { Instance | string } = {}
	for _, item in raw do
		local key = assetKey(item)
		if not seen[key] then
			seen[key] = true
			table.insert(manifest, item)
		end
	end

	return manifest
end

-- Blocks the calling thread until every asset in the manifest has been fetched (success or
-- failure) -- this IS the point: Client/Loading/LoadingClient.lua calls this to gate a real loading
-- screen on, not a best-effort background warm-up. onProgress, if given, fires once per asset with
-- (completed, total) -- LoadingClient.lua uses it to drive a Fusion.Value the screen reads.
--
-- No artificial timeout: ContentProvider:PreloadAsync itself already resolves once every asset is
-- settled one way or the other, so there's nothing this function needs to add on top of that.
function AssetPreloader.Run(onProgress: ((completed: number, total: number) -> ())?): ()
	local manifest = AssetPreloader.BuildManifest()
	local total = #manifest

	if total == 0 then
		return
	end

	local completed = 0
	logger:debug("Preload start", { total = total })

	ContentProvider:PreloadAsync(manifest, function(contentId: string, status: Enum.AssetFetchStatus)
		completed += 1
		if status ~= Enum.AssetFetchStatus.Success then
			logger:warn("Asset failed to preload", { contentId = contentId, status = status.Name })
		end
		if onProgress then
			onProgress(completed, total)
		end
	end)

	logger:debug("Preload end", { total = total })
end

return AssetPreloader
