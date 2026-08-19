--!strict
--[[
	FOVOffset.lua

	Owns: the single canonical writer of Workspace.CurrentCamera.FieldOfView. Before this module
	existed, two client modules wrote FieldOfView directly and uncoordinated: SwingEffect.lua's
	combat "punch" (reads the CURRENT FieldOfView as its own base at call time, tweens out and back)
	and FlightCamera.lua's continuous zoom (captures a base ONCE at flight-engage time, writes
	baseFov + delta every frame). FlightCamera.lua's own header already flagged this as fragile
	("never assumes a hardcoded base FOV, since other systems... can have left the camera at a
	non-default value") -- the two were already implicitly relying on never firing in the same
	window. Adding a third direct writer (Sprint/Slide zoom) the same way would make all three fight:
	whichever Tween/write happened last each frame wins, and each captures a stale "base" to return
	to. This module is the fix -- the same architectural role CameraShake.lua already plays for
	camera ROTATION (a shared, named, composable primitive at a fixed RenderPriority), just for FOV.

	Two composition kinds, both keyed by caller-chosen name so unrelated callers never collide:
	  * Continuous (SetContinuous/ClearContinuous) -- a persistent, optionally-eased offset. Flight
	    hands over an already-eased delta every frame (easeSpeed = nil, snaps instantly -- it did its
	    own easing upstream); Sprint hands over a raw target + an ease rate and lets THIS module ease
	    toward it every frame, since Sprint has no per-frame owner of its own the way Flight's
	    onRenderStep is.
	  * Punch (Punch) -- a one-shot ease-out-then-back-to-zero, analytic (not TweenService: multiple
	    named slots must SUM onto the same camera.FieldOfView, and two Tweens can't compose on one
	    property -- the second Tween's writes would simply clobber the first's every frame). Used by
	    SwingEffect's combat punch and the new Slide kick. Re-callable mid-punch under the same name
	    (restarts that slot), same "safe to call again" contract SwingEffect.Play already documented
	    before this refactor.

	All slots sum onto ONE lazily-captured base FOV (captured the first time this module's render
	step actually runs with a live camera, before any slot has ever contributed) and are written to
	camera.FieldOfView once per frame at a single RenderPriority -- no other module should ever write
	FieldOfView directly again.

	Does not own: deciding WHEN to punch/zoom (SwingEffect/FlightCamera/CombatClient's Sprint-Slide
	code still own that), or any other camera property (CameraOffset stays ShiftLockCamera/
	FlightCamera's alone; camera rotation stays CameraShake's alone).
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("FOVOffset")

local RENDER_STEP_NAME = "FOVOffsetCompose"

type ContinuousSlot = {
	Kind: "Continuous",
	Current: number,
	Target: number,
	EaseSpeed: number?,
}

type PunchSlot = {
	Kind: "Punch",
	StartClock: number,
	Delta: number,
	OutSeconds: number,
	BackSeconds: number,
}

type Slot = ContinuousSlot | PunchSlot

local FOVOffset = {}

local slots: { [string]: Slot } = {}

local started = false
local baseFovCaptured = false
-- Last value actually written to Camera.FieldOfView, so an unchanged frame can skip the write -- see
-- onRenderStep. nil until the first write, so the first frame after Start (or after a camera swap
-- resets baseFov) always writes.
local lastWritten: number? = nil
local baseFov = 70

-- Persistent named offset. If easeSpeed is a positive number, THIS module eases the slot's live
-- value toward targetDelta every frame (Shared/FlightMath.EaseAlpha's rate->alpha conversion, the
-- same idiom Constants.Camera.Flight.FOVEaseSpeed already uses) -- for a caller with no per-frame
-- owner of its own (Sprint). If easeSpeed is nil, the slot snaps straight to targetDelta -- for a
-- caller (Flight) that already eased its own delta upstream and would otherwise be double-eased.
function FOVOffset.SetContinuous(name: string, targetDelta: number, easeSpeed: number?): ()
	local existing = slots[name]
	if existing and existing.Kind == "Continuous" then
		existing.Target = targetDelta
		existing.EaseSpeed = easeSpeed
		if not easeSpeed then
			existing.Current = targetDelta
		end
		return
	end
	slots[name] = {
		Kind = "Continuous",
		Current = if easeSpeed then 0 else targetDelta,
		Target = targetDelta,
		EaseSpeed = easeSpeed,
	} :: ContinuousSlot
end

-- Hard removal, no fade -- for teardown (e.g. CharacterRemoving) where a lingering offset would be
-- wrong regardless of how it looks. A caller wanting a smooth release should call
-- SetContinuous(name, 0, easeSpeed) instead and just leave the settled ~0 slot in place.
function FOVOffset.ClearContinuous(name: string): ()
	slots[name] = nil
end

-- The player's own Types.ComfortSettings.FieldOfViewEffects preference, pushed by Client/Settings/
-- SettingsClient.lua. Defaults to true for the same reason CameraShake.lua's own flag does: a client
-- whose settings round trip fails gets the shipped experience, not a quietly diminished one.
local punchesEnabled = true

-- Gates the Punch path ONLY -- SetContinuous slots are deliberately unaffected. A continuous slot is
-- the run's speed zoom: it eases rather than snaps, and it is a readout of how fast the player is
-- moving, which is information a player needs rather than punctuation they might not want. The
-- one-shot punches are the impact emphasis, and they are what a player reaching for a camera-comfort
-- setting is actually reaching for. See Types.ComfortSettings for the same split stated from the
-- settings side.
--
-- Clears every in-flight punch on the way to disabled -- same reasoning as CameraShake.SetEnabled's
-- own clear. Continuous slots are left exactly as they are, which is the whole point of the split.
function FOVOffset.SetPunchesEnabled(enabled: boolean): ()
	punchesEnabled = enabled
	if enabled then
		return
	end
	for name, slot in pairs(slots) do
		if slot.Kind == "Punch" then
			slots[name] = nil
		end
	end
end

-- One-shot: eases this named slot from 0 to delta over outSeconds, then back to 0 over
-- backSeconds, then removes itself. Safe to call again mid-punch under the SAME name (restarts
-- that slot from StartClock = now). A DIFFERENT name's punch is a separate slot -- both sum
-- normally (e.g. a Basic swing's punch landing the same frame as a Slide kick).
function FOVOffset.Punch(name: string, delta: number, outSeconds: number, backSeconds: number): ()
	if not punchesEnabled then
		return
	end
	slots[name] = {
		Kind = "Punch",
		StartClock = os.clock(),
		Delta = delta,
		OutSeconds = math.max(outSeconds, 1e-4),
		BackSeconds = math.max(backSeconds, 1e-4),
	} :: PunchSlot
end

-- Analytic Sine-InOut ease, x in [0, 1] -- the same curve TweenService's Sine/InOut style produces,
-- reproduced here because multiple slots must sum onto one property (see header for why this can't
-- just be a Tween).
local function sineInOut(x: number): number
	return -(math.cos(math.pi * x) - 1) / 2
end

local function punchContribution(slot: PunchSlot, now: number): (number, boolean)
	local elapsed = now - slot.StartClock
	if elapsed < slot.OutSeconds then
		return slot.Delta * sineInOut(elapsed / slot.OutSeconds), false
	end
	local backElapsed = elapsed - slot.OutSeconds
	if backElapsed < slot.BackSeconds then
		return slot.Delta * (1 - sineInOut(backElapsed / slot.BackSeconds)), false
	end
	return 0, true
end

local function onRenderStep(deltaTime: number): ()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if not baseFovCaptured then
		baseFov = camera.FieldOfView
		baseFovCaptured = true
		-- A freshly captured base means the memo below describes the PREVIOUS camera's projection, not
		-- this one's -- cleared so the first frame against a new base always writes.
		lastWritten = nil
	end

	local now = os.clock()
	local total = 0
	for name, slot in pairs(slots) do
		if slot.Kind == "Continuous" then
			if slot.EaseSpeed then
				local alpha = FlightMath.EaseAlpha(slot.EaseSpeed :: number, deltaTime)
				slot.Current += (slot.Target - slot.Current) * alpha
			else
				slot.Current = slot.Target
			end
			total += slot.Current
		else
			local contribution, finished = punchContribution(slot, now)
			total += contribution
			if finished then
				slots[name] = nil
			end
		end
	end

	-- Conditional for exactly the reason CameraOffsetComposer.lua's own write is -- see that module's
	-- comment, and Server/Systems/RunSystem.lua's Heartbeat for where this codebase states the rule.
	-- FieldOfView is the more expensive of the two to re-assert: it is a camera projection parameter,
	-- so writing it invalidates frustum-derived work even when the value is unchanged. The steady
	-- state is an empty `slots` table -- no speed zoom, no punch -- which produced baseFov + 0 every
	-- single rendered frame, forever, for every player.
	local nextFov = baseFov + total
	if lastWritten ~= nextFov then
		camera.FieldOfView = nextFov
		lastWritten = nextFov
	end
end

-- Binds the render-step compositor. Called once from Main.client.lua's boot sequence. Idempotent.
-- Binds at the same Enum.RenderPriority.Camera.Value + 1 slot ShiftLockCamera/FlightCamera use for
-- CameraOffset -- a different property (FieldOfView, not CameraOffset), so there's no ordering
-- hazard sharing it. CameraShake.lua's own Camera + 2 rotation composition is unaffected -- it
-- never touches FieldOfView.
function FOVOffset.Start(): ()
	if started then
		return
	end
	started = true
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, onRenderStep)
	logger:info("FOVOffset started")
end

return FOVOffset
