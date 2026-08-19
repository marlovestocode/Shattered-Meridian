--!strict
--[[
	HitFlash.lua

	Owns: the victim hit-flash -- a pooled Highlight popped onto whoever just took a resolved contact,
	color-coded by what kind of resolution it was (Constants.FX.HitFlash's own "white = a plain hit,
	gold = a parry deflection, red-gold = a posture break" family). Same acquire-from-pool -> animate ->
	release-on-Completed shape Client/FX/FlightVFX.lua's own header credits this module with
	establishing first -- see that file for the sibling that reuses it for a tweened Size instead of
	Transparency.

	GENERIC, LIKE CameraShake.lua, NOT COMBAT-VOCABULARY-AWARE. This module knows how to pop a colored
	Highlight onto a Model and fade it back out; it has no idea what "Parried" or "GuardBroken" means.
	Client/Combat/CombatFeedbackClient.lua owns that mapping (DefenseTypes.OutcomeKind -> one of
	Constants.FX.HitFlash's three named colors) in exactly the place it already owns the identical
	mapping for CameraShake's presets -- one module answering "what does this outcome mean," not two
	disagreeing answers spread across the FX layer.

	VICTIM ONLY. Constants.FX.HitFlash's own header calls this "victim hit-flash" by name, and
	Client/Combat/CombatFeedbackClient.lua's onFeedback fires this on the resolved contact's Defender
	regardless of which participant's client is running it -- a Highlight is adorned onto a replicated
	Model and reads the same for anyone who can see that body, unlike the shake/FOV cues in this same
	folder that are inherently first-person. So both the attacker's client and the defender's own client
	independently draw their own local flash on the defender's body from their own copy of the
	Combat_Feedback event; neither needs to know the other did.

	INSTANT POP, FAST FADE, NO HOLD. Constants.FX.HitFlash.DurationSeconds documents "how long the
	flash holds before fading" for the OTHER mechanism this file does not implement (FlashHold, the
	"parry window is armed right now" tell, which triggers off a block/parry PRESS rather than off a
	resolved Combat_Feedback contact and is out of scope for this pass -- see Does not own below) and is
	explicit that the one-shot Flash this module DOES implement "stays an instant pop... a fast snap is
	what reads as contact, right now." So Flash snaps straight to full visibility on the frame it is
	called and tweens back to invisible over the whole of DurationSeconds, with no separate hold phase.

	Does not own: WHAT a resolved contact means (Client/Combat/CombatFeedbackClient.lua decides which
	color), the pooling primitive itself (Client/FX/FXPool.lua), or the "parry window is currently
	armed" hold-glint (Constants.FX.HitFlash.ParryWindowColor/HoldFadeInSeconds) -- that tell fires off a
	block/parry PRESS, a different trigger from the landed-contact Flash this module provides, and
	wiring it would mean a new seam into Client/Defense/DefenseClient.lua rather than the
	Combat_Feedback hook this pass is scoped to. Left as documented-but-unbuilt, the same
	wired-but-unauthored discipline the rest of this combat-feel pass follows.
]]

local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local FXPool = require(script.Parent.FXPool)

local logger = Logger.scope("HitFlash")

local HitFlash = {}

local CONFIG = Constants.FX.HitFlash

-- A persistent, unreplicated container the pooled Highlights live under while active. Parented under
-- Workspace.CurrentCamera rather than plain Workspace (FlightVFX/MovementVFX's choice for their own
-- world-positioned Parts) -- a Highlight has no position of its own, only an Adornee, so it needs no
-- presence in world-space at all, and the camera is a client-local Instance Roblox never streams out
-- from under a pooled effect the way a far-away Workspace folder theoretically could. FXPool.GetHolder
-- already handles the camera itself being destroyed and replaced on some camera-mode transitions --
-- see that function's own header for why the provider is re-invoked rather than cached.
local function getHolder(): Folder
	return FXPool.GetHolder("HitFlashHolder", function(): Instance
		return Workspace.CurrentCamera :: Instance
	end)
end

local function makeHighlight(): Highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = "HitFlash"
	-- Reads through a crowd/partial occlusion in a group fight, which is the case this cue exists for
	-- -- a flash that only shows when nothing is in the way would miss the exact moments (backstabs,
	-- ganks) it matters most for.
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.Adornee = nil
	highlight.Parent = nil
	return highlight
end

local function resetHighlight(highlight: Highlight): ()
	highlight.Adornee = nil
	highlight.Parent = nil
end

local pool = FXPool.New(makeHighlight, resetHighlight, CONFIG.PoolMaxSize)

-- Visible resting values for an active flash -- a wash on the fill, a crisp outline, both eased back to
-- fully transparent by Flash below. Not authored in Constants.FX.HitFlash (only the per-outcome COLOR
-- and the overall duration are) because these are this module's own rendering choice, not a balance or
-- readability number anyone would retune per outcome.
local FLASH_FILL_TRANSPARENCY = 0.55
local FLASH_OUTLINE_TRANSPARENCY = 0

-- Pops a colored flash onto `model`, held nowhere -- see this file's header on why there is no hold
-- phase. Drops the request rather than erroring when the pool is at cap (FXPool.Acquire returning nil),
-- the same "a dropped cosmetic is a non-issue" tolerance FlightVFX.playRing already extends to its own
-- pool.
function HitFlash.Flash(model: Model, color: Color3): ()
	local highlight = pool:Acquire()
	if not highlight then
		logger:debug("HitFlash pool at cap -- dropping flash", { model = model.Name })
		return
	end

	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = FLASH_FILL_TRANSPARENCY
	highlight.OutlineTransparency = FLASH_OUTLINE_TRANSPARENCY
	highlight.Adornee = model
	highlight.Parent = getHolder()

	local tween = TweenService:Create(
		highlight,
		TweenInfo.new(CONFIG.DurationSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
		{ FillTransparency = 1, OutlineTransparency = 1 }
	)
	tween:Play()
	tween.Completed:Once(function()
		pool:Release(highlight)
	end)
end

return HitFlash
