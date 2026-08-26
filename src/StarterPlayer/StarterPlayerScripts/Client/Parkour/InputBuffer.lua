--!strict
--[[
	InputBuffer.lua

	Owns: the local player's buffered parkour intents -- when jump, slide, roll, leap and dash were
	last pressed, whether slide is currently held, whether each buffered press is still live, and the
	one intent that survives an arbitrarily long gap: a slide key held through a fall, re-armed as a
	fresh press at the moment of touchdown (ArmHeldSlideOnLanding).

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
-- The committed leap's own dedicated press -- see PressLeap/PeekLeap/ConsumeLeap below, which mirror
-- Roll's shape exactly. Leap used to be detected as a double-tap of jump instead of having a key of its
-- own -- that mechanism (a raw press-history timestamp plus a detected-gesture buffer, and a line inside
-- ConsumeJump spending the gesture alongside an ordinary jump so the two inputs could not fire twice off
-- one press) is gone along with it: a dedicated key needs none of that cross-consumption, because there
-- is only ever one input to spend.
local leapPressedAt = 0
-- The four-way dash's press (States/Dashing.lua). Mirrors Roll's shape exactly, and deliberately has
-- no held counterpart the way slide does: a dash is a one-shot burst with an authored duration, so
-- there is nothing for holding the key to extend.
local dashPressedAt = 0

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

function InputBuffer.PressLeap(now: number): ()
	leapPressedAt = now
end

function InputBuffer.PressDash(now: number): ()
	dashPressedAt = now
end

function InputBuffer.IsSlideHeld(): boolean
	return slideHeld
end

-- THE AIR-HELD SLIDE: holding the slide key through a fall queues a slide that fires the instant the
-- character touches down, however long the fall was.
--
-- Called by ParkourController on the airborne -> grounded edge -- the one place that edge is already
-- detected (see the ground-contact bookkeeping block there, and its own note on why it lives in the
-- controller rather than in any state). Nothing else about the transition needed building:
-- States/Sliding.lua's priority (120) outranks Landing's (90) and Falling's (60), so route 2 pre-empts
-- the landing on the first grounded frame and Sliding.CanEnter is asked IN FULL -- speed, cooldown and
-- the combat gate all still apply. That is why this is a buffer change and not a new transition; the
-- route-1 chain in States/Dashing.lua has to re-check those gates by hand precisely because it skips
-- them, and this skips nothing.
--
-- THE GAP IT CLOSES: slideHeld was already true the whole way down. Only the PRESS was missing -- it
-- expires after Assists.ActionBufferSeconds (0.18s), so any fall longer than that landed with
-- CanEnter refusing "NoSlideInput". The intent was never lost, just its timestamp.
--
-- RE-STAMPED ON THE EDGE, deliberately, rather than either obvious alternative:
--   * A LONGER WINDOW would also keep a stale GROUND press alive, which is the "character slides on
--     its own a beat after you stopped asking for it" failure PeekJump's comment above already warns
--     about for the jump buffer. The window is not what is wrong here, so widening it trades one
--     dropped input for a spurious one.
--   * TREATING THE HOLD ITSELF AS A LIVE PRESS would re-enter Sliding on every frame the key is down:
--     the slide ends, the key is still held, it starts again, forever. This grants exactly ONE attempt
--     per landing, which then expires through the ordinary window like any other press.
--
-- Releasing before touchdown cancels it, because slideHeld is what gates this -- with the ordinary
-- press window still covering a release in the last few frames, which is forgiveness, not a leak.
function InputBuffer.ArmHeldSlideOnLanding(now: number): ()
	if not slideHeld then
		return
	end
	slidePressedAt = now
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
-- `enabled` is now unconditionally true here, exactly as PeekSlide/PeekRoll/PeekLeap already pass it --
-- the preference is expressed entirely in which window it gets.
function InputBuffer.PeekJump(now: number): boolean
	local window = if assists.JumpBuffer
		then ParkourConstants.Jump.BufferSeconds
		else ParkourConstants.Jump.UnbufferedWindowSeconds
	return ParkourMath.BufferLive(now, jumpPressedAt, window, true)
end

function InputBuffer.ConsumeJump(now: number): boolean
	if not InputBuffer.PeekJump(now) then
		return false
	end
	jumpPressedAt = 0
	return true
end

function InputBuffer.PeekLeap(now: number): boolean
	return ParkourMath.BufferLive(now, leapPressedAt, ParkourConstants.Assists.ActionBufferSeconds, true)
end

function InputBuffer.ConsumeLeap(now: number): boolean
	if not InputBuffer.PeekLeap(now) then
		return false
	end
	leapPressedAt = 0
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

function InputBuffer.PeekDash(now: number): boolean
	return ParkourMath.BufferLive(now, dashPressedAt, ParkourConstants.Assists.ActionBufferSeconds, true)
end

function InputBuffer.ConsumeDash(now: number): boolean
	if not InputBuffer.PeekDash(now) then
		return false
	end
	dashPressedAt = 0
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
	leapPressedAt = 0
	dashPressedAt = 0
	slideHeld = false
end

return InputBuffer
