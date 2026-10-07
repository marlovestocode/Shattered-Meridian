--!strict
--[[
	HitFlash.lua

	Owns: the victim hit-flash -- a colored Highlight popped onto whoever just took a resolved contact,
	color-coded by what kind of resolution it was (FXConstants.HitFlash's own "white = a plain hit,
	gold = a parry deflection, red-gold = a posture break" family).

	GENERIC, LIKE CameraShake.lua, NOT COMBAT-VOCABULARY-AWARE. This module knows how to pop a colored
	Highlight onto a Model and fade it back out; it has no idea what "Parried" or "GuardBroken" means.
	Client/Combat/CombatFeedbackClient.lua owns that mapping.

	ONE PERSISTENT HIGHLIGHT PER BODY, ENABLED ONLY WHILE IT FLASHES -- and that is a performance fix,
	not tidiness (docs/architecture/2026-09-28-combat-performance-audit.md, F2). This used to take a
	pooled Highlight, point its Adornee at the victim and reparent it on EVERY hit, which makes the engine
	rebuild the outline for a fresh adornee each time -- on top of the always-on-top pass itself, one of
	the most expensive per-object render features Roblox has. A body now gets its Highlight once, adorned
	and parented for as long as the body exists; a hit only switches it on and tweens it out, and it is
	switched OFF again the moment the fade ends. A disabled Highlight is not rendered at all, so a body
	that is not flashing costs nothing.

	NOT ON YOUR OWN BODY by default (FXConstants.HitFlash.SkipLocalCharacter): on the victim's own
	client that flash is the most expensive one -- the largest model on screen, drawn over everything --
	and the least informative, since the shake, the impact sound and the health bar all land on the same
	frame. Everyone else still sees it on you, on their own clients.

	BOUNDED at FXConstants.HitFlash.PoolMaxSize bodies -- well under Roblox's 31-Highlight render limit.
	Past it, the least recently flashed body gives its Highlight up.

	INSTANT POP, FAST FADE, NO HOLD: snaps to full visibility on the frame it is called and tweens back
	to invisible over DurationSeconds.

	Does not own: WHAT a resolved contact means (Client/Combat/CombatFeedbackClient.lua decides which
	color), or the "parry window is currently armed" hold-glint (FXConstants.HitFlash.ParryWindowColor)
	-- that tell fires off a block/parry PRESS and is still documented-but-unbuilt.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local FXPool = require(script.Parent.FXPool)

local HitFlash = {}

local CONFIG = FXConstants.HitFlash

-- Visible resting values for an active flash -- a wash on the fill, a crisp outline, both eased back to
-- fully transparent. This module's own rendering choice, not a balance number.
local FLASH_FILL_TRANSPARENCY = 0.55
local FLASH_OUTLINE_TRANSPARENCY = 0

type Entry = {
	Highlight: Highlight,
	Tween: Tween?,
	-- Bumped on every flash, so an older fade finishing cannot switch off a newer flash.
	Generation: number,
	LastFlashAt: number,
	Cleanup: RBXScriptConnection,
}

local entries: { [Model]: Entry } = {}
local entryCount = 0

-- Unreplicated, client-local container under the camera -- a Highlight has no position of its own,
-- only an Adornee. FXPool.GetHolder re-resolves the camera if it is replaced.
local function getHolder(): Folder
	return FXPool.GetHolder("HitFlashHolder", function(): Instance
		return Workspace.CurrentCamera :: Instance
	end)
end

local function release(model: Model): ()
	local entry = entries[model]
	if not entry then
		return
	end
	entries[model] = nil
	entryCount -= 1
	entry.Cleanup:Disconnect()
	if entry.Tween then
		entry.Tween:Cancel()
	end
	entry.Highlight:Destroy()
end

local function evictOldest(): ()
	local oldest: Model? = nil
	local oldestAt = math.huge
	for model, entry in entries do
		if entry.LastFlashAt < oldestAt then
			oldest = model
			oldestAt = entry.LastFlashAt
		end
	end
	if oldest then
		release(oldest)
	end
end

local function entryFor(model: Model): Entry
	local existing = entries[model]
	if existing then
		return existing
	end
	if entryCount >= CONFIG.PoolMaxSize then
		evictOldest()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "HitFlash"
	-- Reads through a crowd or partial occlusion in a group fight -- the backstabs and ganks this cue
	-- matters most for.
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.Enabled = false
	highlight.Adornee = model
	highlight.Parent = getHolder()

	local entry: Entry = {
		Highlight = highlight,
		Tween = nil,
		Generation = 0,
		LastFlashAt = 0,
		-- A body leaving the world (death, respawn, a bot despawning) takes its Highlight with it.
		Cleanup = model.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				release(model)
			end
		end),
	}
	entries[model] = entry
	entryCount += 1
	return entry
end

function HitFlash.Flash(model: Model, color: Color3): ()
	if model.Parent == nil then
		return
	end
	if CONFIG.SkipLocalCharacter and model == Players.LocalPlayer.Character then
		return
	end

	local entry = entryFor(model)
	local highlight = entry.Highlight
	-- The holder can be replaced with the camera; keep the Highlight under the live one.
	local holder = getHolder()
	if highlight.Parent ~= holder then
		highlight.Parent = holder
	end

	if entry.Tween then
		entry.Tween:Cancel()
	end
	entry.Generation += 1
	entry.LastFlashAt = os.clock()
	local generation = entry.Generation

	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = FLASH_FILL_TRANSPARENCY
	highlight.OutlineTransparency = FLASH_OUTLINE_TRANSPARENCY
	highlight.Enabled = true

	local tween = TweenService:Create(
		highlight,
		TweenInfo.new(CONFIG.DurationSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
		{ FillTransparency = 1, OutlineTransparency = 1 }
	)
	entry.Tween = tween
	tween.Completed:Once(function()
		-- Off, not merely invisible: a disabled Highlight is not rendered at all.
		if entries[model] == entry and entry.Generation == generation then
			highlight.Enabled = false
			entry.Tween = nil
		end
	end)
	tween:Play()
end

-- Live bodies holding a Highlight, for a spec or the debug readout.
function HitFlash.CountTracked(): number
	return entryCount
end

return HitFlash
