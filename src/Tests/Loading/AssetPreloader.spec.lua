--!strict
--[[
	AssetPreloader.spec.lua

	Guards MANIFEST COMPLETENESS -- the one property of Client/Loading/AssetPreloader.lua that
	nothing else can catch.

	A missing asset here has no failure signal. Preloading is a pure optimization: the game plays
	correctly whether or not an id was in the manifest, so a dropped category produces no error, no
	warning, and no visible defect in Studio -- just a CDN fetch paid at first use instead of behind
	the loading screen. Which means it surfaces as "the first vault of the session stutters" in a
	playtest weeks later, if anyone connects the two at all. That is exactly the class of regression a
	test has to hold, because a human reviewer reading the diff won't.

	This spec asserts the CATEGORIES that reach BuildManifest, not an exact manifest count -- a count
	assertion would fail every time someone authors a new animation, training everyone to update the
	number without reading why it moved. Each describe block below fails only when a whole source of
	assets has stopped arriving.

	BuildManifest was already split out from Run for exactly this (see that module's own header):
	it builds the list without triggering a real ContentProvider:PreloadAsync, so this runs headless.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Constants = require(ReplicatedStorage.Shared.Constants)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local FlightConstants = require(ReplicatedStorage.Shared.Flight.FlightConstants)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

local Client = StarterPlayer.StarterPlayerScripts.Client
local AssetPreloader = require(Client.Loading.AssetPreloader)
local MovePresentationCatalog = require(Client.FX.MovePresentationCatalog)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)

-- Installed once, at file scope, never removed -- the same convention every WeaponFixture consumer in
-- this suite keeps (see Tests/Combat/Attack/AttackAnimations.spec.lua's own header for why a per-test
-- Install()/Remove() cycle would tear the shared fixture down out from under another spec file).
local WEAPON_ROSTER = WeaponFixture.Install()
local WEAPON_ID = WEAPON_ROSTER[1]

-- Mirrors AssetPreloader's own assetKey(): every manifest entry is an Instance carrying its asset id
-- as a property -- either one a domain module already owned, or a throwaway the preloader wrapped a
-- raw id in. Returns nil for anything else, which is what the "preloadable Instance" case below
-- asserts never happens.
local function entryKey(item: any): string?
	if typeof(item) ~= "Instance" then
		return nil
	elseif item:IsA("Sound") then
		return item.SoundId
	elseif item:IsA("Animation") then
		return item.AnimationId
	elseif item:IsA("Decal") then
		return item.Texture
	end
	return nil
end

-- Building the key set once per test lets each assertion ask the single question that matters -- "is
-- this authored id actually in there?" -- without caring which shape it arrived as (that is an
-- implementation detail of the owning module, and ParkourAnimator deliberately differs from
-- CombatAnimator here).
local function manifestKeys(): { [string]: boolean }
	local keys: { [string]: boolean } = {}
	for _, item in AssetPreloader.BuildManifest() do
		local key = entryKey(item)
		if key ~= nil then
			keys[key] = true
		end
	end
	return keys
end

-- Asserts every non-empty id in an authored table reaches the manifest. "" is the codebase-wide
-- placeholder convention for a wired-but-unauthored slot (see Constants.lua/EmoteDefinitions.lua
-- headers) and is skipped by every provider, so it must be skipped here too.
local function expectAllAuthoredIdsPresent(keys: { [string]: boolean }, ids: { [string]: string }, label: string): ()
	for name, assetId in pairs(ids) do
		if assetId ~= "" then
			if not keys[assetId] then
				error(`{label}.{name} ({assetId}) is authored but missing from the preload manifest`, 0)
			end
		end
	end
end

return function()
	describe("AssetPreloader.BuildManifest", function()
		it("returns a non-empty manifest", function()
			expect(#AssetPreloader.BuildManifest() > 0).to.equal(true)
		end)

		it("never includes an empty or placeholder-prefix id", function()
			for _, item in AssetPreloader.BuildManifest() do
				local key = entryKey(item)
				if key ~= nil then
					-- "" is the unauthored convention; the BARE prefix is the anti-pattern
					-- EmoteDefinitions.lua records having shipped once -- it passes every ~= ""
					-- guard and still reaches a real load attempt.
					expect(key).never.to.equal("")
					expect(key).never.to.equal("rbxassetid://")
				end
			end
		end)

		it("hands ContentProvider a preloadable Instance, never a bare content id", function()
			-- THE REGRESSION THIS FILE EXISTS FOR SECOND-MOST, after completeness -- and the one that
			-- actually shipped. ContentProvider:PreloadAsync reports Enum.AssetFetchStatus.Failure for
			-- a raw "rbxassetid://..." string whatever the underlying asset is, so a manifest carrying
			-- ids directly warms NOTHING while looking entirely healthy: the loading bar still fills,
			-- the game still plays, and every asset simply cold-loads at first use instead -- the exact
			-- hitch the manifest exists to have already paid. It surfaced only as a wall of
			-- "Asset failed to preload" warnings that read like broken ids.
			--
			-- Several providers legitimately return { string } (ParkourAnimator, DefenseClient,
			-- AttackAnimations, WeaponIdleAnimations, WeaponDefenseAnimations, WeaponSounds), so a new
			-- source dropped into BuildManifest unwrapped is a one-line, plausible-looking mistake.
			-- This is what makes it loud.
			for _, item in AssetPreloader.BuildManifest() do
				if typeof(item) ~= "Instance" then
					error(
						`manifest entry {tostring(item)} is a {typeof(item)}, not an Instance -- PreloadAsync will report Failure for it`,
						0
					)
				end
				if entryKey(item) == nil then
					error(
						`manifest entry {item:GetFullName()} is a {item.ClassName}, which carries no preloadable asset id`,
						0
					)
				end
			end
		end)

		it("deduplicates by underlying asset id", function()
			-- Several slots deliberately share one placeholder clip (Constants.Flight's six entries,
			-- and several ParkourConstants entries reuse the same id), so without dedupe the same
			-- fetch would be counted many times and inflate the loading bar's total against work
			-- that isn't real.
			local seen: { [string]: boolean } = {}
			for _, item in AssetPreloader.BuildManifest() do
				local key = entryKey(item)
				if key ~= nil then
					expect(seen[key]).to.equal(nil)
					seen[key] = true
				end
			end
		end)
	end)

	describe("manifest coverage by category", function()
		it("covers every authored combat animation", function()
			expectAllAuthoredIdsPresent(manifestKeys(), CombatConstants.AnimationIds, "CombatConstants.AnimationIds")
		end)

		it("covers every authored parkour animation", function()
			-- The gap this whole spec was written after: ParkourAnimator builds its clips lazily, so
			-- it had no templates for the preloader to borrow and twenty slots went unpreloaded --
			-- every one of them cold-loading mid-traversal, which is the worst moment to pay a fetch.
			expectAllAuthoredIdsPresent(manifestKeys(), ParkourConstants.AnimationIds, "ParkourConstants.AnimationIds")
		end)

		it("covers every authored intro animation", function()
			expectAllAuthoredIdsPresent(manifestKeys(), Constants.Intro.AnimationIds, "Constants.Intro.AnimationIds")
		end)

		it("covers every authored flight animation", function()
			expectAllAuthoredIdsPresent(manifestKeys(), FlightConstants.AnimationIds, "FlightConstants.AnimationIds")
		end)

		it("covers the HUD vital icons", function()
			-- The most player-visible textures in the game: they render the frame the loading screen
			-- clears, so an unpreloaded one pops in blank on the first frame of actual gameplay.
			expectAllAuthoredIdsPresent(manifestKeys(), Constants.UI.VitalIconIds, "Constants.UI.VitalIconIds")
		end)

		it("covers every asset a move's presentation references, wrapped by kind", function()
			-- The catalogue usually arrives after boot (its later ids go through PreloadLabelled), but
			-- whatever it already holds when the manifest is built must be in it, sounds as Sounds and
			-- textures as Decals -- a bare id would be refused by PreloadAsync.
			MovePresentationCatalog.ResetForTesting()
			local block = MovePresentationTypes.Validate({
				HitClean = { SoundId = "70000001", SparkTexture = "70000002" },
			})
			MovePresentationCatalog.Apply({ Kind = "Snapshot", Version = 1, Entries = { ["spec-move"] = block :: any } })
			local soundFound, imageFound = false, false
			for _, item in AssetPreloader.BuildManifest() do
				if item:IsA("Sound") and item.SoundId == "rbxassetid://70000001" then
					soundFound = true
				elseif item:IsA("Decal") and item.Texture == "rbxassetid://70000002" then
					imageFound = true
				end
			end
			MovePresentationCatalog.ResetForTesting()
			expect(soundFound).to.equal(true)
			expect(imageFound).to.equal(true)
		end)

		it("covers the movement dust texture", function()
			if Constants.FX.MovementDust.Texture ~= "" then
				expect(manifestKeys()[Constants.FX.MovementDust.Texture]).to.equal(true)
			end
		end)

		it("covers the defense/parry animation", function()
			-- DefenseClient.GetPreloadInstances (via Shared/Animation/AnimationManager.GetPreloadIds)
			-- hands back raw content ids, not Animation instances -- same shape as ParkourConstants'
			-- own category above -- so this also covers AssetPreloader having wrapped them, which is
			-- what makes them preloadable at all.
			if DefenseConstants.ParryAnimationId ~= "" then
				expect(manifestKeys()[DefenseConstants.ParryAnimationId]).to.equal(true)
			end
		end)

		describe("covers per-weapon animation Attributes", function()
			-- Own afterEach, scoped to this describe block only, clearing just the two clips these
			-- cases set -- the fixture itself (WEAPON_ROSTER above) is shared VM-wide and stays
			-- installed, per this file's own header note.
			afterEach(function()
				(WeaponFixture.AnimationSlot(WEAPON_ID, "M1") :: Animation).AnimationId = ""
				(WeaponFixture.AnimationSlot(WEAPON_ID, "IDLE") :: Animation).AnimationId = ""
			end)

			it("covers a weapon's own swing-clip override (Shared/Attack/AttackAnimations.lua)", function()
				(WeaponFixture.AnimationSlot(WEAPON_ID, "M1") :: Animation).AnimationId = "rbxassetid://111111"
				expect(manifestKeys()["rbxassetid://111111"]).to.equal(true)
			end)

			it("covers a weapon's own idle-clip override (Shared/Combat/WeaponIdleAnimations.lua)", function()
				(WeaponFixture.AnimationSlot(WEAPON_ID, "IDLE") :: Animation).AnimationId = "rbxassetid://222222"
				expect(manifestKeys()["rbxassetid://222222"]).to.equal(true)
			end)
		end)

		it("covers combat sounds without depending on Main.client.lua's require order", function()
			-- CombatAudio.lua registers as its own require() side effect
			-- (AssetPreloader.lua's own require(CombatAudio) above BuildManifest, next to
			-- FlightAudio/RunAudio) rather than as a consequence of Main.client.lua's boot order --
			-- see CombatAudio.lua's own header. This has to hold regardless of where
			-- Main.client.lua's own CombatAudio.Start() call ends up.
			local keys = manifestKeys()
			for _, config in CombatConstants.Sound.Swing do
				if config.SoundId ~= "" then
					expect(keys[config.SoundId]).to.equal(true)
				end
			end
			for _, config in CombatConstants.Sound.Impact do
				if config.SoundId ~= "" then
					expect(keys[config.SoundId]).to.equal(true)
				end
			end
		end)

		it("covers the run footstep sound without depending on Main.client.lua's require order", function()
			-- Same reasoning as combat sounds above, for the newest registrar (RunAudio) -- the one
			-- most likely to be missed, since it arrived after the preloader was written.
			-- The normal run has one footstep sound, so this checks its asset directly rather than
			-- depending on a registrar's module-load order.
			local keys = manifestKeys()
			local stage1 = Constants.Run.Footsteps.Stages[1]
			if stage1.Sound.SoundId ~= "" then
				expect(keys[stage1.Sound.SoundId]).to.equal(true)
			end
			-- Guards the shape as well as the manifest: a stage entry missing ReferenceSpeed or
			-- StepIntervalSeconds would divide by nil inside RunController's cadence, which is a
			-- crash in a per-frame loop rather than a missing sound.
			for stage, config in Constants.Run.Footsteps.Stages do
				expect(typeof(config.ReferenceSpeed)).to.equal("number")
				expect(config.StepIntervalSeconds > 0).to.equal(true)
				expect(stage > 0).to.equal(true)
			end
		end)

		it("covers the dash launch sound without depending on Main.client.lua's require order", function()
			-- Same reasoning as combat/run sounds above, for the newest registrar (DashAudio) --
			-- AssetPreloader.lua's own require(DashAudio) above BuildManifest is what has to hold
			-- regardless of Main.client.lua's own boot order.
			local keys = manifestKeys()
			if ParkourConstants.Dash.Sound.SoundId ~= "" then
				expect(keys[ParkourConstants.Dash.Sound.SoundId]).to.equal(true)
			end
		end)

		it("covers the slide loop sound without depending on Main.client.lua's require order", function()
			-- Same reasoning again, for the newest registrar (SlideAudio) -- AssetPreloader.lua's own
			-- require(SlideAudio) above BuildManifest is what has to hold regardless of
			-- Main.client.lua's own boot order.
			local keys = manifestKeys()
			if ParkourConstants.Slide.Sound.SoundId ~= "" then
				expect(keys[ParkourConstants.Slide.Sound.SoundId]).to.equal(true)
			end
		end)

		it("covers the mantle sound without depending on Main.client.lua's require order", function()
			-- Same reasoning again, for the newest registrar (MantleAudio) -- AssetPreloader.lua's own
			-- require(MantleAudio) above BuildManifest is what has to hold regardless of
			-- Main.client.lua's own boot order.
			local keys = manifestKeys()
			if ParkourConstants.Obstacle.MantleSound.SoundId ~= "" then
				expect(keys[ParkourConstants.Obstacle.MantleSound.SoundId]).to.equal(true)
			end
		end)
	end)

	describe("AssetPreloader.BuildLabelIndex", function()
		it("resolves a Parkour animation id to a readable label", function()
			local labels = AssetPreloader.BuildLabelIndex()
			expect(labels[ParkourConstants.AnimationIds.Leap]).to.equal("Parkour.Leap")
		end)

		it("resolves a UI vital icon id to a readable label", function()
			local labels = AssetPreloader.BuildLabelIndex()
			expect(labels[Constants.UI.VitalIconIds.Health]).to.equal("UI.Health")
		end)

		it("never labels the empty-string placeholder id", function()
			-- "" means "wired, not yet authored" everywhere in this codebase -- it must never resolve
			-- to a label, or a preload failure log for a genuinely different asset that also happens
			-- to be blank-id-adjacent could misreport which slot is unauthored.
			local labels = AssetPreloader.BuildLabelIndex()
			expect(labels[""]).to.equal(nil)
		end)
	end)
end
