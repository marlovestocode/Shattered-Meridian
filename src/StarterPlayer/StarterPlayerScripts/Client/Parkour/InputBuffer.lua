--!strict
--[[
	InputBuffer.lua

	Owns: the local player's buffered parkour intents -- when jump, slide and roll were last pressed,
	whether slide is currently held, and whether each buffered press is still live.

	This module is the entire answer to the design's "add sensible buffering where necessary so
	players can press an input slightly before an action becomes available and still have the action
	occur when possible. This is especially important for jumping, vaulting, wall-jumping, sliding,
	and landing." Without it, every one of those inputs is a coin flip on frame timing: pressing
	slide two frames before sprint speed is reached, or jump two frames before landing, silently does
	nothing and reads to the player as the game dropping their input.

	PEEK VERSUS CONSUME -- the one contract every caller must get right:
	  * Peek* answers "is there a live press?" and changes nothing. State CanEnter predicates MUST use
	    Peek, because ParkourTypes.StateDefinition documents CanEnter as pure, and because the debug
	    overlay calls CanEnter on every registered state on a timer -- a consuming CanEnter would have
	    the overlay silently eating the player's inputs the whole time it was open.
	  * Consume* answers the same question AND clears the press. State Enter callbacks use it, so one
	    press can only ever produce one action.
	Getting this backwards produces a bug that only manifests with the debug overlay open, which is
	precisely when it is hardest to notice, hence the emphasis.

	A single module-level buffer rather than an instantiable object: there is exactly one local
	player, and every other client input module in this codebase (KeybindManager.lua,
	MovementVFX.lua, CombatAnimator.lua) is a module-level singleton for the same reason. The pure
	window arithmetic it delegates to (Shared/Parkour/ParkourMath.BufferLive) is separately testable
	on its own.

	Does not own: reading the keyboard/gamepad (Client/Parkour/ParkourInput.lua does that and calls
	the Press* functions here), or deciding what a buffered press means (the State modules do).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

type AssistSettings = ParkourTypes.AssistSettings

local InputBuffer = {}

-- os.clock() of the most recent press of each intent, or 0 for "not pressed since the last consume".
-- Separate fields rather than a keyed table so every access is a plain field read that typechecks
-- under --!strict, and so no caller can invent an intent by passing an arbitrary string.
local jumpPressedAt = 0
local slidePressedAt = 0
local rollPressedAt = 0

-- THE DOUBLE TAP, which needs two timestamps rather than one and cannot reuse `jumpPressedAt` for
-- either of them.
--
-- `lastJumpPressAt` is raw press HISTORY -- every press, never cleared by a consume -- because the
-- question "were these two presses close together" has to be answerable after the first of them has
-- already been spent on an ordinary jump, which is exactly what happens: tap one launches the jump and
-- clears jumpPressedAt, tap two arrives 0.15s later and has nothing left to compare itself against.
--
-- `doubleTapAt` is the detected gesture, buffered like any other intent so it survives a few frames of
-- the leap not yet being available.
local lastJumpPressAt = 0
local doubleTapAt = 0

-- Held state, distinct from the buffered press above: a slide continues while held and can be
-- released early, where the press itself is a one-shot that expires. Both are needed -- see
-- States/Sliding.lua, which reads the press to START and the hold to decide whether to CONTINUE.
local slideHeld = false

-- Mirrors the player's own assist preferences, pushed in by ParkourController whenever settings
-- change. Held here rather than read from the context at each call site so the buffer's own
-- functions stay callable from anywhere (including ParkourInput, which has no context) and so
-- switching an assist off is impossible to forget at one of several call sites.
local assists: AssistSettings = {
	CoyoteTime = ParkourConstants.Assists.CoyoteTime,
	JumpBuffer = ParkourConstants.Assists.JumpBuffer,
	AutoVault = ParkourConstants.Assists.AutoVault,
	LedgeAssist = ParkourConstants.Assists.LedgeAssist,
	StepAssist = ParkourConstants.Assists.StepAssist,
}

function InputBuffer.SetAssists(next: AssistSettings): ()
	assists = next
end

function InputBuffer.GetAssists(): AssistSettings
	return assists
end

function InputBuffer.PressJump(now: number): ()
	if lastJumpPressAt > 0 and (now - lastJumpPressAt) <= ParkourConstants.Jump.DoubleTapSeconds then
		doubleTapAt = now
	end
	lastJumpPressAt = now
	jumpPressedAt = now
end

function InputBuffer.PressSlide(now: number): ()
	slidePressedAt = now
	slideHeld = true
end

function InputBuffer.ReleaseSlide(): ()
	slideHeld = false
end

function InputBuffer.PressRoll(now: number): ()
	rollPressedAt = now
end

function InputBuffer.IsSlideHeld(): boolean
	return slideHeld
end

-- Jump uses its OWN, tighter window (ParkourConstants.Jump.BufferSeconds) rather than the shared
-- ActionBufferSeconds every other intent uses -- jump is the input players press most often and most
-- reflexively, and a jump buffer long enough to feel generous for a slide reads as the character
-- jumping on its own a beat after you stopped asking it to.
-- The JumpBuffer assist selects the WINDOW; it does not decide whether a press happened.
--
-- Passing `assists.JumpBuffer` as BufferLive's `enabled` argument (as this did) short-circuits the
-- function to false before it looks at the timestamp at all -- so turning the assist off didn't
-- shorten the buffer, it deleted every jump press from the parkour framework's point of view. See
-- ParkourConstants.Jump.UnbufferedWindowSeconds for the full account of what that broke; the short
-- version is that this function is the "was jump pressed" test for wall-jumps, leaps, slide-jumps and
-- ledge climb-ups, not just for buffered jumps.
--
-- `enabled` is now unconditionally true here, exactly as PeekSlide/PeekRoll/PeekDoubleJump already
-- pass it -- the preference is expressed entirely in which window it gets.
function InputBuffer.PeekJump(now: number): boolean
	local window = if assists.JumpBuffer
		then ParkourConstants.Jump.BufferSeconds
		else ParkourConstants.Jump.UnbufferedWindowSeconds
	return ParkourMath.BufferLive(now, jumpPressedAt, window, true)
end

-- Spending a jump press ALSO spends the double tap it was the second half of, and that is the rule that
-- keeps the two inputs from fighting.
--
-- Without it a double tap fires twice: the wall-jump (or the ordinary jump) consumes the press, the
-- gesture survives in its own buffer, and the leap fires a frame or two later out of whatever state the
-- first action handed to. Chained wall-jumps make that constant rather than rare -- climbing a shaft is
-- literally a stream of jump presses inside the double-tap window, so every kick would be chased by a
-- leap that flings the player out of the corridor they were climbing.
--
-- One press, one action, whichever action claimed it.
function InputBuffer.ConsumeJump(now: number): boolean
	if not InputBuffer.PeekJump(now) then
		return false
	end
	jumpPressedAt = 0
	doubleTapAt = 0
	return true
end

-- Whether a double tap of jump is live. Uses the shared action buffer window rather than jump's own
-- tighter one: the leap it triggers has a real availability gate in front of it (a cooldown, and having
-- touched the ground since the last one), so the gesture has to survive long enough to be answered
-- once the gate opens, which is the same forgiveness ActionBufferSeconds exists to provide everywhere
-- else. It is deliberately NOT gated on the JumpBuffer assist -- that preference is about jumps firing
-- late, and a leap that never fires at all is not the same complaint.
function InputBuffer.PeekDoubleJump(now: number): boolean
	return ParkourMath.BufferLive(now, doubleTapAt, ParkourConstants.Assists.ActionBufferSeconds, true)
end

function InputBuffer.ConsumeDoubleJump(now: number): boolean
	if not InputBuffer.PeekDoubleJump(now) then
		return false
	end
	doubleTapAt = 0
	-- The press itself goes too: the second tap of a leap must not also be sitting in the ordinary jump
	-- buffer waiting to launch a jump out of the state the leap hands to.
	jumpPressedAt = 0
	return true
end

function InputBuffer.PeekSlide(now: number): boolean
	return ParkourMath.BufferLive(now, slidePressedAt, ParkourConstants.Assists.ActionBufferSeconds, true)
end

function InputBuffer.ConsumeSlide(now: number): boolean
	if not InputBuffer.PeekSlide(now) then
		return false
	end
	slidePressedAt = 0
	return true
end

function InputBuffer.PeekRoll(now: number): boolean
	return ParkourMath.BufferLive(now, rollPressedAt, ParkourConstants.Assists.ActionBufferSeconds, true)
end

function InputBuffer.ConsumeRoll(now: number): boolean
	if not InputBuffer.PeekRoll(now) then
		return false
	end
	rollPressedAt = 0
	return true
end

-- Whether a jump is still legal within the coyote window after walking off a ledge. Lives here
-- rather than in a state module because it is the same class of forgiveness as the buffers above
-- (the player's timing was slightly off; the game chooses to honor the intent) and because keeping
-- both assist windows in one file means one place to look when either feels wrong.
function InputBuffer.CoyoteAvailable(now: number, leftGroundAt: number): boolean
	return ParkourMath.CoyoteAvailable(now, leftGroundAt, ParkourConstants.Jump.CoyoteTimeSeconds, assists.CoyoteTime)
end

-- Drops every buffered press and the held flag. Called on character bind/rebind and whenever the
-- framework is disabled or hands the body to combat -- a press buffered before a respawn firing
-- immediately after it is a real bug class (the player pressed jump while dying and jumps the
-- instant they respawn), not a hypothetical one.
function InputBuffer.Clear(): ()
	jumpPressedAt = 0
	slidePressedAt = 0
	rollPressedAt = 0
	slideHeld = false
	-- The press HISTORY goes too, not just the live buffers: a press made before a respawn and one made
	-- after it are not a double tap, and leaving the old timestamp would let the first jump of a new life
	-- read as the second half of a gesture from the previous one.
	lastJumpPressAt = 0
	doubleTapAt = 0
end

return InputBuffer
