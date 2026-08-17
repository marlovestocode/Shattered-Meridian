--!strict
--[[
	AssetPreloader.lua

	Owns: the boot-time "block until every known client asset is ready" gate. Aggregates the
	instances each domain module already builds for its own purposes (Client/FX/SoundManager.lua's
	pooled Sound instances, Client/FX/CombatAnimator.lua's, Client/FX/FlightAnimator.lua's and
	Client/FX/EmoteAnimator.lua's Animation templates), plus the raw content ids for the categories
	that have no instance to borrow (Client/Parkour/ParkourAnimator.lua's twenty lazily-built clips,
	Constants.Intro.AnimationIds, Constants.UI.VitalIconIds, Constants.FX.MovementDust.Texture),
	dedupes them by underlying asset id, and runs ONE ContentProvider:PreloadAsync call across the
	combined list -- one real progress count across every asset category, not a separate fire-and-
	forget preload per module.

	MANIFEST COMPLETENESS IS THE WHOLE POINT, and it is what Tests/Loading/AssetPreloader.spec.lua
	guards. An asset missing from here doesn't fail loudly -- it just cold-loads at first use, which
	is precisely the hitch the loading screen exists to have already paid. So a new asset category
	MUST be added here, and the spec asserts the categories that exist today still arrive.

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
local AttackAnimations = require(ReplicatedStorage.Shared.Attack.AttackAnimations)
local Constants = require(ReplicatedStorage.Shared.Constants)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local SoundManager = require(script.Parent.Parent.FX.SoundManager)
local CombatAnimator = require(script.Parent.Parent.FX.CombatAnimator)
local FlightAnimator = require(script.Parent.Parent.FX.FlightAnimator)
local EmoteAnimator = require(script.Parent.Parent.FX.EmoteAnimator)
local ParkourAnimator = require(script.Parent.Parent.Parkour.ParkourAnimator)
local DefenseClient = require(script.Parent.Parent.Defense.DefenseClient)

-- SoundManager holds a REGISTRY, not a fixed set -- it only knows about the sounds someone has
-- Register()ed into it, and these two modules are the ones who do that (FlightAudio at load, RunAudio
-- at load). Neither is required above for its return value; they are required for the side effect of
-- their top-level Register() calls. CombatAudio.lua (a third former registrant) was removed alongside
-- the rest of the combat system.
--
-- Requiring them HERE rather than relying on someone else having already done so is the point. That
-- used to hold only by accident: Client/Main.client.lua requires FlightController/RunController at
-- the top of its own body, each of which requires one of these, and all of that happens to run before
-- LoadingClient.Run() reaches this module. Main's own comment asserts that ordering -- but nothing
-- enforced it. Either of those two modules switching to a lazy require would have silently emptied
-- its sounds out of the manifest: no error, no warning, just a cold-load hitch on the first
-- takeoff/footstep of every session, and no test anywhere to catch it.
--
-- Luau caches module results, so requiring them a second time here is free -- it cannot double-
-- register.
require(script.Parent.Parent.FX.FlightAudio)
require(script.Parent.Parent.FX.RunAudio)

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
	for _, instance in EmoteAnimator.GetPreloadInstances() do
		table.insert(raw, instance)
	end
	for _, instance in DefenseClient.GetPreloadInstances() do
		table.insert(raw, instance)
	end
	-- Raw id strings rather than instances -- see ParkourAnimator.GetPreloadInstances' own header for
	-- why that module is the one provider that doesn't keep templates to hand back.
	for _, assetId in ParkourAnimator.GetPreloadInstances() do
		table.insert(raw, assetId)
	end
	-- Attack swing clips, also as raw ids (same reason as ParkourAnimator above -- these are claimed
	-- through AnimationManager, which pools its own templates internally and hands none out).
	--
	-- The config this reads (Shared/Attack/AttackAnimations.lua) ships with every slot blank, and
	-- GetPreloadIds already filters those out -- so today this contributes nothing to the manifest and
	-- costs nothing. It is wired now rather than later so that pasting an id into that one file is
	-- genuinely the ONLY step: without this line, a newly authored swing clip would cold-load on its
	-- first use mid-fight instead of during the loading screen, which is precisely the silent-hitch
	-- failure this whole manifest exists to prevent.
	for _, assetId in AttackAnimations.GetPreloadIds() do
		table.insert(raw, assetId)
	end
	-- The one standalone texture id not owned by a domain module with its own instance-pooling
	-- concern -- Constants.FX.MovementDust.lua's own header note on why nothing else instances this
	-- eagerly. Skipped like every other still-unauthored placeholder if ever set back to "".
	if Constants.FX.MovementDust.Texture ~= "" then
		table.insert(raw, Constants.FX.MovementDust.Texture)
	end

	-- The two intro animation ids (Client/Intro/IntroClient.lua's lying-down/get-up clips) -- raw
	-- content-id strings, same as MovementDust.Texture above, rather than pre-built Animation
	-- instances: unlike CombatAnimator/FlightAnimator/EmoteAnimator, IntroClient.lua plays each of
	-- these exactly once per session and has no ongoing pool to be the "one source of truth" for.
	for _, animationId in pairs(Constants.Intro.AnimationIds) do
		table.insert(raw, animationId)
	end

	-- The HUD's three vital icons (Constants.UI.VitalIconIds -- health/qi/posture). These are the
	-- most player-visible textures in the game and were the worst-timed gap in this manifest: they
	-- render the instant the loading screen clears, so an unpreloaded icon pops in blank on the very
	-- first frame of gameplay.
	--
	-- Raw ids rather than a Screens/HUD provider on purpose. This module is deliberately Fusion-free
	-- (see the header) so it stays requireable without a DataModel; reaching into the UI tree for an
	-- id would drag Fusion, Tokens and the whole component graph into the preloader's require chain
	-- to fetch three strings. It also wouldn't work: HUD builds its icons inside HUD.new, which
	-- UI.Mount() doesn't call until after this gate has already run.
	for _, textureId in pairs(Constants.UI.VitalIconIds) do
		if textureId ~= "" then
			table.insert(raw, textureId)
		end
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

-- contentId -> a readable "Category.Key" label, for the failure log below. Built from every id-keyed
-- constants table this module already knows the shape of (Parkour, Intro, UI icons) plus
-- AttackAnimations' own deliberate label export -- see that function's header for why it exists at
-- all. NOT exhaustive: the Sound/Animation-instance categories (SoundManager, CombatAnimator,
-- FlightAnimator, EmoteAnimator, DefenseClient) have no equivalent id->name table to invert without a
-- new export from each of them, so those fall back to the bare content id, same as before this
-- existed. Rebuilt on every Run() call rather than cached at module scope -- this is a boot-time,
-- once-per-life operation, and a cached index would be one more thing to invalidate if any of these
-- tables ever became mutable.
--
-- Exposed on the module (not left local) for the same reason BuildManifest is: so a test can inspect
-- it directly rather than triggering a real ContentProvider:PreloadAsync call to observe it indirectly.
function AssetPreloader.BuildLabelIndex(): { [string]: string }
	local labels: { [string]: string } = {}
	for key, assetId in ParkourConstants.AnimationIds do
		if assetId ~= "" then
			labels[assetId] = `Parkour.{key}`
		end
	end
	for key, assetId in Constants.Intro.AnimationIds do
		if assetId ~= "" then
			labels[assetId] = `Intro.{key}`
		end
	end
	for key, assetId in Constants.UI.VitalIconIds do
		if assetId ~= "" then
			labels[assetId] = `UI.{key}`
		end
	end
	for assetId, moveId in AttackAnimations.GetPreloadLabels() do
		labels[assetId] = `Attack.{moveId}`
	end
	return labels
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

	local labels = AssetPreloader.BuildLabelIndex()
	local completed = 0
	local failed = 0
	logger:debug("Preload start", { total = total })

	ContentProvider:PreloadAsync(manifest, function(contentId: string, status: Enum.AssetFetchStatus)
		completed += 1
		if status ~= Enum.AssetFetchStatus.Success then
			failed += 1
			logger:warn("Asset failed to preload", {
				contentId = contentId,
				-- Falls back to the bare id when nothing in buildLabelIndex claims it -- see that
				-- function's own "NOT exhaustive" note.
				asset = labels[contentId] or contentId,
				status = status.Name,
			})
		end
		if onProgress then
			onProgress(completed, total)
		end
	end)

	-- THE ACTUAL ANSWER TO "WHY," most of the time. ContentProvider:PreloadAsync's callback gives
	-- Success/Failure and nothing else -- Roblox exposes no richer reason (not a 404 vs. a permissions
	-- error vs. a timeout), so a per-asset log can only ever say THAT one failed, never why THAT ONE
	-- did. But when many or all of them fail together, across categories that share no asset, no
	-- owner and no upload date, the common cause is never "20 coincidentally broken ids" -- it is
	-- something failing every fetch the same way: Studio's own "Enable Studio Access to API Services"
	-- setting (Game Settings -> Security) being off blocks ALL asset fetches from a local Studio
	-- session, and no network connection does the same from anywhere. This summary is what turns a
	-- wall of individually-uninformative warnings into that diagnosis.
	if failed > 0 then
		local rate = failed / total
		logger:warn("Preload finished with failures", {
			failed = failed,
			total = total,
			failedPercent = math.floor(rate * 100 + 0.5),
			-- Half the manifest is a deliberately loose threshold: a handful of individually-broken
			-- ids (deleted, unpublished, not owned) is a real and different failure mode from
			-- everything failing together, and this line should not fire for the former.
			likelyCause = if rate >= 0.5
				then "Most/all assets failed together -- check Studio Settings > Security > Enable Studio Access to API Services, and your network connection, before assuming individual assets are broken."
				else "Only some assets failed -- check those specific ids are valid, published, and owned/public rather than a systemic access issue.",
		})
	end

	logger:debug("Preload end", { total = total, failed = failed })
end

return AssetPreloader
