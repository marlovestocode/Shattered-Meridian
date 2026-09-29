--!strict
--[[
	ParryPrediction.lua

	Owns: the local player's guess, on the key edge, at whether THIS press will arm a parry -- so
	Client/Defense/DefenseClient.lua can play the parry swing-up for a press that will parry and go
	straight to the guard for one that will only block, instead of playing the swing-up for both.

	WHY A GUESS AT ALL. The answer is the server's (DefenseStateMachine.Press), but it arrives a round trip
	after the key went down, and the animation cannot wait for it -- that wait is exactly the "blocking
	feels delayed" this exists to fix. So the press is predicted locally and the server's verdict
	(DefenseTypes.PressVerdict, on Defense_StateChanged) corrects it. Before this the client played the
	parry swing-up on every press, so a press the server had quietly turned into a plain block -- guard
	dropped too recently, a whiffed tap's lockout, a press held through a swing or a stun -- looked
	identical to a real parry, and the player had no way to learn why it "should have parried".

	A MIRROR OF THE MACHINE'S ARMING RULES, fed by the local key edges and a few server facts:
	  * no window                -> never arms (the server fail-closes; its Window push says which).
	  * body committed           -> a press held through a swing or a stun comes up as a block, never a
	                                parry (DefenseSystem.SetBlocking's deferral).
	  * guard broken             -> the guard is not available at all (read off the server's State push).
	  * Parry.MinUnguardedSeconds after a guard that was UP AS A BLOCK came down.
	  * a whiffed tap's lockout  -> released inside the window with nothing parried: no new parry until
	                                the press time + the window's RecoveryEnd.
	  * Staggered                -> refused only when DefenseConstants.Rally.ParryFromStagger is off.
	Press and release travel the same wire in order, so their SPACING is what the server sees too; that
	is why a local clock is enough for everything timed off the player's own input.

	WHAT IT CANNOT SEE, and why that is acceptable: a rally shrinking the window (the lockout starts a
	little earlier on the server), a stun the server applied that has not reached LocalCombatState yet,
	and the exact moment a parry landed relative to a release. Each only ever makes a guess wrong for a
	press made inside a narrow edge, and the verdict corrects every one of them.

	PURE: no Instances, no services, no clock -- every entry point takes `now`, so the spec drives it
	without a rig. Does not own: any animation (DefenseClient), any remote, or the rules themselves
	(the server machine is the authority; this only mirrors it for presentation).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)

type WindowShape = DefenseTypes.WindowShape

local ParryPrediction = {}
ParryPrediction.__index = ParryPrediction

-- One press, from key-down to its settled consequences.
export type Press = {
	Id: number,
	At: number,
	-- The guess, then the server's verdict once it arrives.
	Armed: boolean,
	-- The window this press was judged with, captured at press time: a weapon swap mid-press re-points
	-- the NEXT press's window, not this one's.
	Window: WindowShape?,
	-- Whether the press was held through a committed body, and whether that held guard has since come up.
	-- A deferred press released before it rose never raised a guard, so it stamps nothing.
	Deferred: boolean,
	Raised: boolean,
	ReleasedAt: number?,
	-- A parry landed on this press, and whether the key was still down when the client heard so.
	Landed: boolean,
	LandedWhileHeld: boolean,
	-- The two clocks as they stood before this press settled, so a late verdict can re-settle it.
	BaseGuardDownAt: number,
	BaseLockedUntil: number,
}

export type Predictor = typeof(setmetatable(
	{} :: {
		_window: WindowShape?,
		_serverState: string,
		_guardDownAt: number,
		_lockedUntil: number,
		_press: Press?,
		_nextId: number,
	},
	ParryPrediction
))

function ParryPrediction.New(): Predictor
	return setmetatable({
		_window = nil,
		_serverState = "Neutral",
		_guardDownAt = -math.huge,
		_lockedUntil = -math.huge,
		_press = nil,
		_nextId = 0,
	}, ParryPrediction) :: any
end

-- Settling ------------------------------------------------------------------------------------------

-- What the press's release did to the two clocks, recomputed from scratch against the clocks as they
-- were before it -- so a verdict or a landed parry arriving after the release corrects the settlement
-- rather than stacking a second one on top of it.
local function settle(self: Predictor, press: Press): ()
	local releasedAt = press.ReleasedAt
	if releasedAt == nil then
		return
	end
	self._guardDownAt = press.BaseGuardDownAt
	self._lockedUntil = press.BaseLockedUntil

	local window = press.Window
	if not press.Armed then
		-- A plain block came down -- unless it never went up (released while still deferred).
		if not press.Deferred or press.Raised then
			self._guardDownAt = releasedAt
		end
	elseif press.Landed then
		-- A landed parry drops a HELD guard into Blocking, so its release is a guard coming down; a tap
		-- that parried went Neutral with nothing to stamp and no whiff to pay.
		if press.LandedWhileHeld then
			self._guardDownAt = releasedAt
		end
	elseif window and releasedAt >= press.At + window.Close then
		-- Held through the close: it became a block, and this release brought that block down.
		self._guardDownAt = releasedAt
	else
		-- Let go inside the window with nothing parried: the whiff's lockout, stamped from the window's
		-- own recovery exactly as DefenseStateMachine.Update does.
		local recoveryEnd = if window then window.RecoveryEnd else DefenseConstants.Parry.RecoverySeconds
		self._lockedUntil = math.max(self._lockedUntil, press.At + recoveryEnd)
	end
end

-- Server facts ---------------------------------------------------------------------------------------

-- The window a press would arm right now, from the server's push -- nil when none would.
function ParryPrediction.SetWindow(self: Predictor, window: WindowShape?): ()
	self._window = window
end

function ParryPrediction.GetWindow(self: Predictor): WindowShape?
	return self._window
end

-- The server's latest DefenseState. Only GuardBroken and Staggered change what a press can do.
function ParryPrediction.NoteServerState(self: Predictor, state: string): ()
	self._serverState = state
end

-- The server's verdict on press `id`. Returns true when it CHANGED the guess for the current press, which
-- is the one case DefenseClient has presentation to correct. A verdict for an older press is ignored:
-- the newest press has already superseded whatever it would have said.
function ParryPrediction.Confirm(self: Predictor, id: number, armed: boolean): boolean
	local press = self._press
	if not press or press.Id ~= id or press.Armed == armed then
		return false
	end
	press.Armed = armed
	-- A press made before any window push (the very first of a life) had nothing to capture; the push
	-- carrying this verdict carried the window too, and it is the one the server just judged with.
	if press.Window == nil then
		press.Window = self._window
	end
	settle(self, press)
	return true
end

-- A parry landed -- the server's FaceTowards push. Credited to the newest press, which is the only one
-- that can still have a live window by the time the push arrives.
function ParryPrediction.NoteParryLanded(self: Predictor): ()
	local press = self._press
	if not press or press.Landed then
		return
	end
	press.Landed = true
	press.LandedWhileHeld = press.ReleasedAt == nil
	-- A landed parry means it armed, whatever was guessed.
	press.Armed = true
	settle(self, press)
end

-- Input ---------------------------------------------------------------------------------------------

-- Whether a press made at `now` would arm a parry. `bodyFree` is the caller's read of whether the body is
-- clear of its own swing and any stun (or air-held, where the server never defers the press).
function ParryPrediction.CanArm(self: Predictor, now: number, bodyFree: boolean): boolean
	if self._window == nil or not bodyFree then
		return false
	end
	if self._serverState == "GuardBroken" then
		return false
	end
	if self._serverState == "Staggered" and not DefenseConstants.Rally.ParryFromStagger then
		return false
	end
	if now < self._lockedUntil then
		return false
	end
	return (now - self._guardDownAt) >= DefenseConstants.Parry.MinUnguardedSeconds
end

-- The key went down. Returns the id to send with the press and whether it is predicted to arm.
function ParryPrediction.Press(self: Predictor, now: number, bodyFree: boolean): (number, boolean)
	local armed = ParryPrediction.CanArm(self, now, bodyFree)
	self._nextId += 1
	self._press = {
		Id = self._nextId,
		At = now,
		Armed = armed,
		Window = self._window,
		Deferred = not bodyFree,
		Raised = bodyFree,
		ReleasedAt = nil,
		Landed = false,
		LandedWhileHeld = false,
		BaseGuardDownAt = self._guardDownAt,
		BaseLockedUntil = self._lockedUntil,
	}
	return self._nextId, armed
end

-- A press held through a committed body has come up (as a block) now that the body is free.
function ParryPrediction.NoteGuardRaised(self: Predictor): ()
	local press = self._press
	if press and press.ReleasedAt == nil then
		press.Raised = true
	end
end

-- The key came up.
function ParryPrediction.Release(self: Predictor, now: number): ()
	local press = self._press
	if not press or press.ReleasedAt ~= nil then
		return
	end
	press.ReleasedAt = now
	settle(self, press)
end

-- The current press, while the key is down; nil otherwise. Read-only for the caller.
function ParryPrediction.GetHeldPress(self: Predictor): Press?
	local press = self._press
	if press and press.ReleasedAt == nil then
		return press
	end
	return nil
end

-- A new life: the server builds a fresh machine on registration, so every clock starts clean. The
-- window survives -- it belongs to the weapon, and the next push re-sends it anyway.
function ParryPrediction.Reset(self: Predictor): ()
	self._serverState = "Neutral"
	self._guardDownAt = -math.huge
	self._lockedUntil = -math.huge
	self._press = nil
end

return ParryPrediction
