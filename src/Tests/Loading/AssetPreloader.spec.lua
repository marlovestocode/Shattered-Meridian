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
local StarterPlayer = game:GetService("StarterPlayer")

local Constants = require(ReplicatedStorage.Shared.Constants)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)

local Client = StarterPlayer.StarterPlayerScripts.Client
local AssetPreloader = require(Client.Loading.AssetPreloader)

-- Mirrors AssetPreloader's own assetKey(): a manifest entry is either a raw content-id string or an
-- instance carrying its id as a property. Building the key set once per test lets each assertion ask
-- the single question that matters -- "is this authored id actually in there?" -- without caring
-- which of the two shapes it arrived as (that is an implementation detail of the owning module, and
-- ParkourAnimator deliberately differs from CombatAnimator here).
local function manifestKeys(): { [string]: boolean }
	local keys: { [string]: boolean } = {}
	for _, item in AssetPreloader.BuildManifest() do
		if typeof(item) == "string" then
			keys[item] = true
		elseif item:IsA("Sound") then
			keys[item.SoundId] = true
		elseif item:IsA("Animation") then
			keys[item.AnimationId] = true
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
				if typeof(item) == "string" then
					-- "" is the unauthored convention; the BARE prefix is the anti-pattern
					-- EmoteDefinitions.lua records having shipped once -- it passes every ~= ""
					-- guard and still reaches a real load attempt.
					expect(item).never.to.equal("")
					expect(item).never.to.equal("rbxassetid://")
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
				local key
				if typeof(item) == "string" then
					key = item
				elseif item:IsA("Sound") then
					key = item.SoundId
				elseif item:IsA("Animation") then
					key = item.AnimationId
				end
				if key ~= nil then
					expect(seen[key]).to.equal(nil)
					seen[key] = true
				end
			end
		end)
	end)

	describe("manifest coverage by category", function()
		it("covers every authored combat animation", function()
			expectAllAuthoredIdsPresent(manifestKeys(), Constants.Combat.AnimationIds, "Constants.Combat.AnimationIds")
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
			expectAllAuthoredIdsPresent(manifestKeys(), Constants.Flight.AnimationIds, "Constants.Flight.AnimationIds")
		end)

		it("covers the HUD vital icons", function()
			-- The most player-visible textures in the game: they render the frame the loading screen
			-- clears, so an unpreloaded one pops in blank on the first frame of actual gameplay.
			expectAllAuthoredIdsPresent(manifestKeys(), Constants.UI.VitalIconIds, "Constants.UI.VitalIconIds")
		end)

		it("covers the movement dust texture", function()
			if Constants.FX.MovementDust.Texture ~= "" then
				expect(manifestKeys()[Constants.FX.MovementDust.Texture]).to.equal(true)
			end
		end)

		it("covers combat sounds without depending on Main.client.lua's require order", function()
			-- SoundManager is a REGISTRY -- it only knows the sounds someone Register()ed. This
			-- asserts AssetPreloader pulls in the registrars itself, rather than inheriting them by
			-- luck from whatever else the boot script happened to require first. Requiring this spec
			-- never loads Main.client.lua, so if AssetPreloader stopped requiring CombatAudio these
			-- ids would vanish and this test would fail -- which is the entire point.
			local keys = manifestKeys()
			expect(keys[Constants.Combat.Sound.Hit.SoundId]).to.equal(true)
			expect(keys[Constants.Combat.Sound.BlockImpact.SoundId]).to.equal(true)
			expect(keys[Constants.Combat.Sound.HandToHandParried.SoundId]).to.equal(true)
		end)

		it("covers run footstep sounds without depending on Main.client.lua's require order", function()
			-- Same reasoning as combat sounds above, for the newest registrar (RunAudio) -- the one
			-- most likely to be missed, since it arrived after the preloader was written.
			local keys = manifestKeys()
			expect(keys[Constants.Run.Footsteps.Stage1.Sound.SoundId]).to.equal(true)
			expect(keys[Constants.Run.Footsteps.Stage2.Sound.SoundId]).to.equal(true)
			expect(keys[Constants.Run.Stage2Onset.Sound.SoundId]).to.equal(true)
		end)
	end)
end
