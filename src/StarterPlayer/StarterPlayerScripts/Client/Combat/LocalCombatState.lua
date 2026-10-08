--!strict
--[[
	LocalCombatState.lua

	Owns: the LOCAL player's own combat commitments, as this client can see them -- until when its own
	swing is playing, until when it is reeling from a hit, and whether its guard key is down. Three
	facts, each written by exactly one module and read by the others:

	    swing       Client/Combat/AttackInputClient.lua   (predicted or confirmed, and cancelled)
	    hitstun     Client/Combat/CombatFeedbackClient.lua (a stunning hit, from Combat_Feedback), and
	                Client/FX/EnvironmentFX.lua (a wall splat's stun, from Combat_EnvironmentFX) -- both
	                only ever EXTEND the deadline (NoteHitstun), so the two cannot fight
	    guard held  Client/Defense/DefenseClient.lua       (the key edge)

	WHY A MODULE OF ITS OWN. The attack and defence clients each need the other's answer -- a swing may
	not be predicted while the guard is up, and the guard animation may not start while a swing is still
	playing -- and requiring each other directly would be a cycle. This is the seam between them, the
	client-side twin of the Humanoid Attributes (CombatBusyUntil, HitstunUntil, DefenseState) the server
	systems use for the same reason.

	A MIRROR, NEVER AN AUTHORITY. Every one of these is also enforced server-side (HitboxEngine,
	DamageSystem.CanAttack, DefenseSystem's guard deferral) and the server's answer always wins. This
	only exists so the local presentation agrees with what the server is about to say instead of
	playing an animation the server will refuse a round trip later.

	DEADLINES, NOT FLAGS, on this client's own os.clock(): a swing or a stun that ends by being forgotten
	has merely passed, the same reasoning AttributeConstants gives for CombatBusyUntil.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CallbackList = require(ReplicatedStorage.Shared.CallbackList)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("LocalCombatState")

local LocalCombatState = {}

local swingEndsAt = 0
local stunEndsAt = 0
local guardHeld = false
-- When the current swing's recovery may be cut, because it LANDED (AttackConstants.HitConfirm), or 0 when
-- it may not. Written by AttackInputClient on the attacker's own Combat_Feedback; reset with the swing.
local cancelAt = 0
-- When a guard may cut this swing's recovery (AttackConstants.GuardCut); 0 = never.
local guardCutAt = 0

-- Called whenever a commitment ends EARLY -- a swing cancelled mid-flight -- so a module waiting for the
-- body to be free (DefenseClient's held guard) can act on this frame rather than at the deadline it
-- scheduled against.
-- Pcall'd per listener (Shared/CallbackList.lua): this runs from inside a swing cut or a parry's stun exit,
-- and one listener erroring must not leave the others waiting on a body that is already free.
local releasedListeners: CallbackList.CallbackList<> = CallbackList.New(logger, "LocalCombatState.OnReleased")

local function notifyReleased(): ()
	releasedListeners:Fire()
end

function LocalCombatState.SetSwing(endsAt: number): ()
	swingEndsAt = endsAt
	cancelAt = 0
	guardCutAt = 0
end

function LocalCombatState.SetGuardCutAt(at: number): ()
	guardCutAt = at
end

function LocalCombatState.ClearSwing(): ()
	cancelAt = 0
	if swingEndsAt == 0 then
		return
	end
	swingEndsAt = 0
	notifyReleased()
end

-- The current swing landed: its recovery may be cut from `at` (AttackConstants.HitConfirmCancelAt).
function LocalCombatState.SetCancelAt(at: number): ()
	cancelAt = at
end

-- When the current swing may be cut, or 0 when it may not.
function LocalCombatState.CancelAt(): number
	return cancelAt
end

function LocalCombatState.SwingEndsAt(): number
	return swingEndsAt
end

-- Extends, never shortens: a second stunning hit inside the first stun pushes the deadline out.
function LocalCombatState.NoteHitstun(endsAt: number): ()
	if endsAt > stunEndsAt then
		stunEndsAt = endsAt
	end
end

function LocalCombatState.IsStunned(now: number): boolean
	return now < stunEndsAt
end

-- Ends the recorded stun now -- the server does the same when this body parries out of one
-- (DefenseConstants.StunParry). Notifies like a cut swing does, so anything waiting on the body acts now.
function LocalCombatState.ClearHitstun(): ()
	if stunEndsAt <= os.clock() then
		return
	end
	stunEndsAt = 0
	notifyReleased()
end

-- When the body is next free of both a swing and a stun, or `now` if it already is. `cancelable` asks for
-- an action that may take a landed swing's cut (AttackConstants.HitConfirm.CancelInto): for it the swing
-- ends at its cut point instead of its real end.
-- When a GUARD may next come up: FreeAt, except that a swing ends at its guard cut point
-- (AttackConstants.GuardCut) instead of its real end -- the server's own rule, mirrored.
function LocalCombatState.GuardFreeAt(now: number): number
	local swing = swingEndsAt
	if guardCutAt > 0 and guardCutAt < swing then
		swing = guardCutAt
	end
	return math.max(now, swing, stunEndsAt)
end

function LocalCombatState.FreeAt(now: number, cancelable: boolean?): number
	local swing = swingEndsAt
	if cancelable and cancelAt > 0 and cancelAt < swing then
		swing = cancelAt
	end
	return math.max(now, swing, stunEndsAt)
end

-- Asks whoever is playing the local swing to cut it now -- the parkour framework, when an evade takes a
-- landed swing's cut. A leaf-module signal because Client/Parkour must not require Client/Combat.
-- Pcall'd too: it runs from the parkour evade path, which must not unwind on a combat listener's error.
local cutListeners: CallbackList.CallbackList<> = CallbackList.New(logger, "LocalCombatState.OnSwingCutRequested")

function LocalCombatState.RequestSwingCut(): ()
	cutListeners:Fire()
end

function LocalCombatState.OnSwingCutRequested(listener: () -> ()): () -> ()
	return cutListeners:Connect(listener)
end

function LocalCombatState.SetGuardHeld(held: boolean): ()
	guardHeld = held
end

function LocalCombatState.IsGuardHeld(): boolean
	return guardHeld
end

function LocalCombatState.OnReleased(listener: () -> ()): () -> ()
	return releasedListeners:Connect(listener)
end

-- A new life carries no commitments over. The guard key is deliberately NOT reset: it describes a key
-- the player is physically holding, which a respawn does not release.
function LocalCombatState.ResetForNewLife(): ()
	swingEndsAt = 0
	stunEndsAt = 0
	cancelAt = 0
end

return LocalCombatState
