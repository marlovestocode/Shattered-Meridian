--!strict
--[[
	AssetPreloader.lua

	Owns: the boot-time "block until every known client asset is ready" gate. Aggregates the
	instances each domain module already builds for its own purposes (Client/FX/SoundManager.lua's
	pooled Sound instances, Client/FX/CombatAnimator.lua's, Client/FX/FlightAnimator.lua's and
	Client/FX/EmoteAnimator.lua's Animation templates), plus a throwaway Instance wrapped around each
	raw content id from the categories that have no instance to borrow (Client/Parkour/
	ParkourAnimator.lua's twenty lazily-built clips, Client/Defense/DefenseClient.lua's defensive
	pair, the per-weapon clip and SFX overrides, Constants.Intro.AnimationIds,
	Constants.UI.VitalIconIds, Constants.FX.MovementDust.Texture) -- see animationFor/soundFor/
	imageFor below for why a BARE ID CANNOT GO IN THE LIST. Dedupes them by underlying asset id, and
	runs ONE ContentProvider:PreloadAsync call across the combined list -- one real progress count
	across every asset category, not a separate fire-and-forget preload per module.

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
local WeaponIdleAnimations = require(ReplicatedStorage.Shared.Combat.WeaponIdleAnimations)
local WeaponDefenseAnimations = require(ReplicatedStorage.Shared.Defense.WeaponDefenseAnimations)
local WeaponSounds = require(ReplicatedStorage.Shared.Combat.WeaponSounds)
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
-- Register()ed into it, and these six modules are the ones who do that (FlightAudio at load,
-- RunAudio at load, CombatAudio at load, ParkourAudio at load -- the last of those covering the
-- dash/slide/mantle sounds that used to be three separate modules).
-- None is required above for its return value; each is required for the side effect of its own
-- top-level Register() calls. CombatAudio.lua was removed alongside the rest of the combat system and
-- has since been rebuilt -- see that module's own header.
--
-- Requiring them HERE rather than relying on someone else having already done so is the point. That
-- used to hold only by accident: Client/Main.client.lua requires FlightController/RunController at
-- the top of its own body, each of which requires one of these, and all of that happens to run before
-- LoadingClient.Run() reaches this module. Main's own comment asserts that ordering -- but nothing
-- enforced it. Any of those modules switching to a lazy require would have silently emptied
-- its sounds out of the manifest: no error, no warning, just a cold-load hitch on the first
-- takeoff/footstep/swing of every session, and no test anywhere to catch it.
--
-- Luau caches module results, so requiring them a second time here is free -- it cannot double-
-- register.
require(script.Parent.Parent.FX.FlightAudio)
require(script.Parent.Parent.FX.RunAudio)
require(script.Parent.Parent.FX.CombatAudio)
require(script.Parent.Parent.FX.ParkourAudio)

local logger = Logger.scope("AssetPreloader")

local AssetPreloader = {}

-- CONTENTPROVIDER:PRELOADASYNC TAKES INSTANCES, NOT CONTENT IDS. That is the entire reason these
-- three constructors exist instead of the id strings going into the manifest directly.
--
-- A bare "rbxassetid://..." string in the list warms nothing. The engine hands it straight back
-- through the callback as Enum.AssetFetchStatus.Failure, whatever the asset actually is -- this was
-- observed failing across all three asset types at once (animations AND audio AND images) in a pass
-- where those same kinds of asset succeeded whenever a domain module happened to hand over a real
-- Instance carrying the id. The cleanest pair in that log: a weapon's BLOCK clip failed as a bare id
-- in the same run that DefenseConstants' baseline clips succeeded as Animation instances -- same
-- asset type, same uploader, same session, so nothing about the assets themselves explains it.
--
-- It fails silently in the way that actually costs something. Preloading is a pure optimization, so
-- the game still played correctly and every asset still loaded -- just cold, at first use, mid-fight
-- or mid-vault. Precisely the hitch this whole module exists to have already paid for. The only
-- symptom was a wall of "Asset failed to preload" warnings that read like broken ids or a Studio
-- API-access problem, which is exactly what Run()'s own summary below used to (wrongly) blame.
--
-- So every id-shaped source gets wrapped here in a throwaway Instance of the matching class. It is
-- never parented, never played and never rendered; it exists only to give PreloadAsync a typed
-- handle on the id, and is collected once the manifest goes out of scope. DO NOT "tidy up" by
-- Destroy()ing manifest entries after the preload: the manifest also holds SoundManager's live
-- pooled Sound instances and three animators' shared Animation templates, which every later Play()
-- in the session depends on.
local function animationFor(assetId: string): Instance
	local animation = Instance.new("Animation")
	animation.AnimationId = assetId
	return animation
end

local function soundFor(assetId: string): Instance
	local sound = Instance.new("Sound")
	sound.SoundId = assetId
	return sound
end

local function imageFor(assetId: string): Instance
	local decal = Instance.new("Decal")
	decal.Texture = assetId
	return decal
end

-- Sound/Animation/Decal instances each carry their own asset id as a property -- either because a
-- domain module built the instance for its own purposes, or because one of the three constructors
-- above wrapped a raw id in one. Anything else shouldn't reach this function given the known
-- sources, but falls back to GetFullName() rather than erroring -- a display-only preload pass
-- degrading gracefully, per this codebase's own error-handling philosophy, beats hard-failing boot
-- over an unrecognized instance type.
local function assetKey(item: Instance): string
	if item:IsA("Sound") then
		return item.SoundId
	elseif item:IsA("Animation") then
		return item.AnimationId
	elseif item:IsA("Decal") then
		return item.Texture
	end
	return item:GetFullName()
end

-- Builds the deduplicated preload manifest -- exposed separately from Run() so a caller (or a
-- future test) can inspect the manifest (e.g. its count) without triggering a real
-- ContentProvider:PreloadAsync call.
function AssetPreloader.BuildManifest(): { Instance }
	local raw: { Instance } = {}
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
	-- Raw animation ids despite the name, exactly like ParkourAnimator just below -- both resolve
	-- through Shared/Animation/AnimationManager, which pools its own templates internally and hands
	-- none out. Wrapped rather than inserted bare, per animationFor's header.
	for _, assetId in DefenseClient.GetPreloadInstances() do
		table.insert(raw, animationFor(assetId))
	end
	-- Raw id strings rather than instances -- see ParkourAnimator.GetPreloadInstances' own header for
	-- why it, like DefenseClient above, keeps no templates to hand back.
	for _, assetId in ParkourAnimator.GetPreloadInstances() do
		table.insert(raw, animationFor(assetId))
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
		table.insert(raw, animationFor(assetId))
	end
	-- Per-weapon standing-idle clips, same raw-id shape and same reasoning as the swing clips just
	-- above -- Client/FX/CombatAnimator.lua loads these dynamically as the drawn weapon changes rather
	-- than keeping fixed templates, so this is the only source that can hand the preloader their ids.
	-- Shared/Combat/WeaponIdleAnimations.lua resolves "" for any weapon with no Animation instance
	-- authored in its own Animations/IDLE folder yet, so an unposed weapon contributes nothing and
	-- costs nothing either.
	for _, assetId in WeaponIdleAnimations.GetPreloadIds() do
		table.insert(raw, animationFor(assetId))
	end
	-- Per-weapon PARRY/BLOCK clips, same raw-id shape and same reasoning as the two sources above --
	-- Client/Defense/DefenseClient.lua registers a weapon's defensive pair on its manager the first
	-- time that weapon is drawn, so at boot its own GetPreloadInstances() below holds only the shared
	-- baseline pair and cannot see these.
	--
	-- WORTH MORE HERE THAN IN EITHER SOURCE ABOVE: a cold-loading idle pose is a late pose, but the
	-- parry clip is on the input path of a timing mechanic. A first press that stalls loading the clip
	-- is a parry the player will read as dropped, and it happens exactly once per weapon per session,
	-- which is the hardest kind of bug to catch a second time.
	--
	-- Only per-weapon OVERRIDES -- Shared/Defense/WeaponDefenseAnimations.GetPreloadIds deliberately
	-- omits the baseline pair, which DefenseClient.GetPreloadInstances already contributes below.
	for _, assetId in WeaponDefenseAnimations.GetPreloadIds() do
		table.insert(raw, animationFor(assetId))
	end
	-- Per-weapon SOUND effects (SFX/Swing, SFX/Block, SFX/Parry, SFX/Equip, SFX/Sheathe on each model
	-- in Workspace.Weapons), same raw-id shape as the two clip sources above. These are the one
	-- audio category SoundManager.GetPreloadInstances cannot cover on its own: Client/FX/CombatAudio.lua
	-- registers a weapon's sounds LAZILY, the first time that weapon actually swings or blocks (see its
	-- ensureWeaponSound), so at boot the registry holds none of them and the first clang of a fight
	-- would stream mid-fight -- precisely the hitch this manifest exists to prevent. Reading them
	-- straight off the models instead needs no registration to have happened first.
	for _, assetId in WeaponSounds.GetPreloadIds() do
		table.insert(raw, soundFor(assetId))
	end
	-- The one standalone texture id not owned by a domain module with its own instance-pooling
	-- concern -- Constants.FX.MovementDust.lua's own header note on why nothing else instances this
	-- eagerly. Skipped like every other still-unauthored placeholder if ever set back to "".
	if Constants.FX.MovementDust.Texture ~= "" then
		table.insert(raw, imageFor(Constants.FX.MovementDust.Texture))
	end

	-- The two intro animation ids (Client/Intro/IntroClient.lua's lying-down/get-up clips) -- raw
	-- content-id strings, same as MovementDust.Texture above, rather than pre-built Animation
	-- instances: unlike CombatAnimator/FlightAnimator/EmoteAnimator, IntroClient.lua plays each of
	-- these exactly once per session and has no ongoing pool to be the "one source of truth" for.
	for _, animationId in pairs(Constants.Intro.AnimationIds) do
		table.insert(raw, animationFor(animationId))
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
			table.insert(raw, imageFor(textureId))
		end
	end

	-- Dedupe by underlying asset id -- Constants.Flight.AnimationIds' six entries currently share one
	-- placeholder id, and preloading the same real asset six times would inflate the progress total
	-- without covering anything new.
	local seen: { [string]: boolean } = {}
	local manifest: { Instance } = {}
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
	for assetId, label in WeaponIdleAnimations.GetPreloadLabels() do
		labels[assetId] = `WeaponIdle.{label}`
	end
	for assetId, label in WeaponDefenseAnimations.GetPreloadLabels() do
		labels[assetId] = `WeaponDefense.{label}`
	end
	for assetId, label in WeaponSounds.GetPreloadLabels() do
		labels[assetId] = `WeaponSound.{label}`
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
	-- something failing every fetch the same way. This summary is what turns a wall of
	-- individually-uninformative warnings into a diagnosis.
	--
	-- THE FIRST SUSPECT IS THIS MODULE, NOT THE ENVIRONMENT, and that ordering is the whole point of
	-- the wording below. This exact log once fired at 72% with every asset valid, owned by the signed-
	-- in user, and Studio API access already on: the manifest was handing PreloadAsync bare content-id
	-- strings, which it always rejects (see animationFor's header above). The message named the Studio
	-- setting first, so the setting is where the time went. A bad manifest entry is silent, local, and
	-- far likelier than a whole environment going wrong at once -- so it is named first now, and the
	-- environment second.
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
				then "Most/all assets failed together, so suspect the manifest before the assets. FIRST: every entry must be an Instance carrying the id (Animation/Sound/Decal) -- PreloadAsync reports Failure for a bare 'rbxassetid://' string, whatever the asset is. THEN: Studio Settings > Security > Enable Studio Access to API Services, and your network connection."
				else "Only some assets failed -- check those specific ids are valid, published, and owned/public rather than a systemic access issue.",
		})
	end

	logger:debug("Preload end", { total = total, failed = failed })
end

return AssetPreloader
