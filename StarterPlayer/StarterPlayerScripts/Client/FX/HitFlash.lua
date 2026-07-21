--!strict
--[[
	HitFlash.lua

	Owns: a brief coloured Highlight over a character the instant a server-validated hit resolves on
	them -- the "small visual confirmation" on the victim's body that docs/ui-ux-philosophy.md's Hit
	Feedback section asks for, and the per-body counterpart to the screen-space damage number. The
	colour reads the same family the rest of combat feedback uses: white for a plain hit, gold for a
	parry deflection, red-gold for a posture break. CombatClient.lua's Combat_FeedbackEvent handler is
	the only caller, so a flash only ever fires on a resolution the server already confirmed.

	Pooled via FXPool (Constants.FX.HitFlash.PoolMaxSize) -- the object-pooling animation-systems.md
	mandates, and well under Roblox's ~31 rendered-Highlight limit, which this melee system (one
	player fighting the handful of characters in view) never approaches. Idle Highlights sit
	unparented (not rendered, not counted) in the pool; an acquired one is parented to a persistent
	holder Folder (NOT the target character -- so a target dying mid-flash can't destroy a pooled
	instance) with its Adornee pointed at the character, then faded and released. If the pool is at
	cap the flash is simply dropped -- a missed cosmetic flash is a non-issue.

	Does not own: resolving TargetUserId -> character (CombatClient hands in the Model), deciding WHEN
	a hit happened (the server, relayed by CombatClient), or the camera shake / hit-stop / damage
	number that accompany a flash. Purely local presentation; nothing here crosses the network.
]]

local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local FXPool = require(script.Parent.FXPool)

local logger = Logger.scope("HitFlash")

local CONFIG = Constants.FX.HitFlash

-- "ParryWindow" is the only NON-impact kind: it's the "parry is armed right now" tell (held for the
-- window via FlashHold), not a reaction to a landed hit. Everything else is a one-shot impact flash.
export type FlashKind = "Hit" | "Parry" | "PostureBreak" | "ParryWindow"

local KIND_COLOR: { [FlashKind]: Color3 } = {
	Hit = CONFIG.HitColor,
	Parry = CONFIG.ParryColor,
	PostureBreak = CONFIG.PostureBreakColor,
	ParryWindow = CONFIG.ParryWindowColor,
}

local HitFlash = {}

-- A persistent, unreplicated container the pooled Highlights live under while active -- keeping them
-- off the target character means a character destroyed mid-flash never takes a pooled instance with
-- it (see the header). Lazily created (and re-created if Workspace.CurrentCamera gets swapped out
-- from under it) via FXPool.GetHolder -- see that function's own header for why the parent is a
-- provider function rather than a plain Instance.
local function getHolder(): Folder
	return FXPool.GetHolder("HitFlashHolder", function(): Instance
		return Workspace.CurrentCamera or Workspace
	end)
end

local function makeHighlight(): Highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = "HitFlash"
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	-- AlwaysOnTop off so the flash respects world occlusion (a hit behind a wall shouldn't glow
	-- through it) -- reads as a surface flash on the body, not an X-ray marker.
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = nil
	highlight.Parent = nil
	return highlight
end

-- Returns a released Highlight to a clean idle state: unparented (so it stops rendering and no
-- longer counts against the Highlight limit) with no Adornee holding a reference to a possibly-dead
-- character.
local function resetHighlight(highlight: Highlight): ()
	highlight.Adornee = nil
	highlight.Parent = nil
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
end

local pool = FXPool.New(makeHighlight, resetHighlight, CONFIG.PoolMaxSize)

-- Acquires a pooled Highlight, colours it for `kind`, and snaps it visible on `character`. Returns
-- the highlight, or nil if the pool is at cap / the character is gone (both harmless -- the caller
-- just drops the flash). Shared by Flash and FlashHold.
local function acquireAndShow(character: Model, kind: FlashKind): Highlight?
	if not character.Parent then
		return nil
	end
	local highlight = pool:Acquire()
	if not highlight then
		logger:debug("HitFlash pool at cap -- dropping flash", { character = character.Name, kind = kind })
		return nil
	end
	local color = KIND_COLOR[kind] or CONFIG.HitColor
	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = 0.45
	highlight.OutlineTransparency = 0
	highlight.Adornee = character
	highlight.Parent = getHolder()
	return highlight
end

local function fadeAndRelease(highlight: Highlight): ()
	local fade = TweenService:Create(
		highlight,
		TweenInfo.new(CONFIG.DurationSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
		{ FillTransparency = 1, OutlineTransparency = 1 }
	)
	fade:Play()
	fade.Completed:Once(function()
		pool:Release(highlight)
	end)
end

-- One-shot impact flash: snap visible, then immediately fade -- a pop-and-melt on a landed hit /
-- parry / posture break. No-op if the pool is at cap or the character is gone.
function HitFlash.Flash(character: Model, kind: FlashKind): ()
	local highlight = acquireAndShow(character, kind)
	if highlight then
		fadeAndRelease(highlight)
	end
end

-- HELD flash for the parry-window tell: stays fully visible for `holdSeconds` (the parry window's
-- duration) so an attacker can read "they're parry-armed" the whole time it matters, THEN fades.
-- Guards the highlight for having been released/destroyed if the character despawned mid-hold.
function HitFlash.FlashHold(character: Model, kind: FlashKind, holdSeconds: number): ()
	local highlight = acquireAndShow(character, kind)
	if not highlight then
		return
	end
	task.delay(holdSeconds, function()
		if highlight.Parent then
			fadeAndRelease(highlight)
		end
	end)
end

return HitFlash
