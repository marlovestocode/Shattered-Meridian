--!strict
--[[
	CombatAudio.lua

	Owns: registering combat's sound effects with SoundManager.lua and exposing verb-named play
	functions for CombatClient.lua to call (PlayBlockImpact(), not CombatClient.lua calling
	SoundManager.Play("BlockImpact") itself with a bare string). SoundManager.lua owns the actual
	Sound Instance/registry mechanics; this module only owns WHICH combat sounds exist and gives
	them a typed API, per animation-systems.md's "Damage numbers and combat feedback" section --
	SFX fires in the same frame as the server-validated hit confirmation, never optimistically on
	local input (a client-side block-button press proves nothing landed; only the server's feedback
	event does, which is why CombatClient.lua -- not this module -- decides when to call these).

	Does not own: deciding WHEN a block/parry happened -- CombatSystem.lua decides that server-side;
	CombatClient.lua relays it here. This module only knows how to make noise once told to.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local SoundManager = require(script.Parent.SoundManager)

local CombatAudio = {}

local BLOCK_IMPACT_SOUND_NAME = "BlockImpact"
local HAND_TO_HAND_PARRIED_SOUND_NAME = "HandToHandParried"
local HIT_SOUND_NAME = "Hit"

SoundManager.Register(BLOCK_IMPACT_SOUND_NAME, Constants.Combat.Sound.BlockImpact)
SoundManager.Register(HAND_TO_HAND_PARRIED_SOUND_NAME, Constants.Combat.Sound.HandToHandParried)
SoundManager.Register(HIT_SOUND_NAME, Constants.Combat.Sound.Hit)

-- Plain blocks (any weight) and parried Heavy attacks -- see PlayHandToHandParried below for why
-- a parried Basic attack doesn't use this one. The "PARRIED"/nothing distinction in
-- CombatFeedback.lua's floating text is what tells a parry apart from a plain block visually.
function CombatAudio.PlayBlockImpact(): ()
	SoundManager.Play(BLOCK_IMPACT_SOUND_NAME)
end

-- The hand-to-hand parry sound -- CombatClient.lua calls this instead of PlayBlockImpact() when
-- payload.Kind == "Parried" and payload.IsHeavy is falsy (Basic-category attacks are this combat
-- system's hand-to-hand strikes; there's no separate attack category for it yet, only Basic/
-- Heavy). Deliberately not a catch-all parry sound: a parried Heavy attack still plays
-- PlayBlockImpact(), per this sound being scoped to hand-to-hand parries specifically.
function CombatAudio.PlayHandToHandParried(): ()
	SoundManager.Play(HAND_TO_HAND_PARRIED_SOUND_NAME)
end

-- An unmitigated hit landing -- CombatClient.lua calls this for Kind == "Hit" (never "Blocked" or
-- "Parried", which already have their own sounds above) where the local player was the attacker,
-- confirming their own hit landed (see that call site for why this is gated on AttackerUserId, not
-- TargetUserId).
function CombatAudio.PlayHit(): ()
	SoundManager.Play(HIT_SOUND_NAME)
end

return CombatAudio
