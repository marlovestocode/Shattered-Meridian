--!strict
--[[
	SwingPresentation.lua

	Owns: playing a move's three SWING cues -- Windup, Active and Recovery (Shared/Combat/
	MovePresentationTypes.lua) -- on the thrower's own client, scheduled off the same Attack_Started payload
	CombatAudio's whoosh and AttackTrail's trail already schedule against.

	THE EVENT, AND ITS LIMIT. Attack_Started is a FireClient to the attacker alone (AttackRequestSystem's
	sendStarted); no client learns that anyone ELSE began a swing. So these cues are the thrower's only --
	the same limit AttackTrail's header records for the trail. Other players read an incoming swing from
	its replicated animation and the heavy tell (SwingTellFX), not from here. A third-party swing cue would
	need the attack layer to broadcast a swing start: a new signal, deliberately not invented for this.

	TIMING. Windup plays as the payload arrives; Active after the payload's own WindupSeconds (the value the
	server scheduled, clip marker included); Recovery after WindupSeconds + ActiveSeconds. A swing cut short
	(AttackInputClient.OnSwingCancelled -- a feint, a parry, hitstun) or replaced by the next swing bumps an
	epoch its pending cues check, so a feinted heavy never plays its Active cue -- CombatAudio's own
	cancelEpoch rule.

	WHO PLAYS WHAT. The Active cue's SOUND is the swing whoosh, and CombatAudio owns that whoosh with its
	weapon and shared layers beneath the move's -- so this module plays every other channel of the Active
	cue and leaves the sound to it. Its TrailColor is AttackTrail's. Windup and Recovery have no default
	sound or effect at all: their cues play here in full through CombatAudio.PlayCue, and unset means
	nothing, as it always did.

	LOOPS (a cue's Loop = "RestOfMove", MovePresentationTypes' SOUND LOOPS). A swing cue that loops its own
	sound starts that loop at its moment (SoundDelay folded in) and ends it with the swing: windup + active +
	recovery seconds after Attack_Started, its FadeOut landing on that last instant. A swing that is cut short
	or replaced stops its loops, each sinking over its own FadeOut. The Active cue's whoosh gives way to its
	loop (CombatAudio.onAttackStarted).

	A swing whose move authors no swing cue costs one table read and schedules nothing.

	Does not own: whether a swing started (the server), the whoosh or the trail (above), or any cue's
	resolution (MovePresentation).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)

local AttackInputClient = require(script.Parent.Parent.Combat.AttackInputClient)
local CombatAudio = require(script.Parent.CombatAudio)
local MovePresentation = require(script.Parent.MovePresentation)
local MovePresentationCatalog = require(script.Parent.MovePresentationCatalog)

type Cue = MovePresentationTypes.Cue

local logger = Logger.scope("SwingPresentation")

local SwingPresentation = {}

local started = false
local cancelEpoch = 0
-- How long the Move Editor's Preview lets a looping cue run before stopping it (there is no move to end it).
local PREVIEW_LOOP_SECONDS = 2.5
-- The loops the current swing has running (CombatAudio.PlayCueLoop), ended when it is cut short or replaced.
local swingLoops: { CombatAudio.CueLoop } = {}
local disconnects: { () -> () } = {}

-- Where a swing cue's template plays: the thrower's root, facing where they face.
local function rootCFrame(): CFrame?
	local player = Players.LocalPlayer
	local character = if player then player.Character else nil
	local root = if character then CharacterUtil.RootOf(character) else nil
	return if root then root.CFrame else nil
end

-- One swing moment's cue, every channel but the ones named in this file's header as someone else's.
-- `includeSound` is false only for the runtime Active moment, whose sound CombatAudio's whoosh plays.
function SwingPresentation.PlayCue(cue: Cue?, moment: string, moveId: string?, includeSound: boolean): ()
	if cue == nil then
		return
	end
	if includeSound then
		CombatAudio.PlayCue(cue)
	end
	MovePresentation.PlayCamera(cue)
	local where = rootCFrame()
	if where then
		MovePresentation.PlayTemplate(cue, where, moveId, moment)
	end
end

-- The Move Editor's Preview of a swing moment: the same PlayCue, plus -- for Active -- the whoosh through
-- CombatAudio.PlaySwing exactly as a thrown swing plays it.
function SwingPresentation.Preview(cue: Cue?, moment: string, kind: AttackTypes.AttackKind, weaponId: string?): ()
	-- A looping cue previews as its loop, for a moment: there is no move to end it.
	if MovePresentation.LoopsToEnd(cue) then
		SwingPresentation.PlayCue(cue, moment, nil, false)
		local loop = CombatAudio.PlayCueLoop(cue)
		if loop then
			task.delay(PREVIEW_LOOP_SECONDS, loop.Stop)
		end
		return
	end
	if moment == "Active" then
		CombatAudio.PlaySwing(kind, weaponId, cue)
	end
	SwingPresentation.PlayCue(cue, moment, nil, moment ~= "Active")
end

-- Ends every loop the last swing left running, each sinking over its own authored fade.
local function stopSwingLoops(): ()
	for _, loop in swingLoops do
		loop.Stop()
	end
	table.clear(swingLoops)
end

local function schedule(delaySeconds: number, epoch: number, run: () -> ()): ()
	if delaySeconds <= 0 then
		run()
		return
	end
	task.delay(delaySeconds, function()
		if cancelEpoch == epoch then
			run()
		end
	end)
end

local function onAttackStarted(payload: AttackTypes.AttackStartedPayload): ()
	-- A new swing retires whatever the last one still had pending (a hit-confirm cancel into a follow-up
	-- never reaches the old swing's recovery) -- AttackTrail's "a new swing always retires the last" rule.
	cancelEpoch += 1
	stopSwingLoops()
	local moveId = payload.MoveId
	local presentation = if typeof(moveId) == "string" then MovePresentationCatalog.Get(moveId) else nil
	if presentation == nil then
		return
	end
	local windup = if typeof(payload.WindupSeconds) == "number" then math.max(payload.WindupSeconds, 0) else 0
	local active = if typeof(payload.ActiveSeconds) == "number" then math.max(payload.ActiveSeconds, 0) else 0
	-- Resolved now, like the weapon a whoosh captures: an edit mid-swing does not change a swing thrown.
	local windupCue = MovePresentation.CueFrom(presentation, "Windup")
	local activeCue = MovePresentation.CueFrom(presentation, "Active")
	local recoveryCue = MovePresentation.CueFrom(presentation, "Recovery")
	local epoch = cancelEpoch
	local recovery = if typeof(payload.RecoverySeconds) == "number" then math.max(payload.RecoverySeconds, 0) else 0
	local startedAt = os.clock()

	-- A looping cue's sound starts SoundDelay from its moment and ends with the swing, its fade-out landing on the
	-- swing's last instant. Both timers are the swing's own; a cut swing's epoch stops the start, and a stop
	-- already made leaves the end's Stop a no-op.
	local function startLoop(cue: Cue, momentSeconds: number): ()
		schedule(momentSeconds + MovePresentation.SoundDelay(cue), epoch, function()
			local loop = CombatAudio.PlayCueLoop(cue)
			if loop == nil then
				return
			end
			table.insert(swingLoops, loop)
			local untilEnd = (windup + active + recovery) - (os.clock() - startedAt)
			local stopIn = untilEnd - loop.FadeOutSeconds
			if stopIn <= 0 then
				loop.Stop()
			else
				task.delay(stopIn, loop.Stop)
			end
		end)
	end

	if windupCue then
		local loops = MovePresentation.LoopsToEnd(windupCue)
		SwingPresentation.PlayCue(windupCue, "Windup", moveId, not loops)
		if loops then
			startLoop(windupCue, 0)
		end
	end
	if activeCue then
		schedule(windup, epoch, function()
			SwingPresentation.PlayCue(activeCue, "Active", moveId, false)
		end)
		if MovePresentation.LoopsToEnd(activeCue) then
			startLoop(activeCue, windup)
		end
	end
	if recoveryCue and MovePresentation.LoopsToEnd(recoveryCue) then
		-- Its look stays on the moment; its sound is the loop.
		schedule(windup + active, epoch, function()
			SwingPresentation.PlayCue(recoveryCue, "Recovery", moveId, false)
		end)
		startLoop(recoveryCue, windup + active)
	elseif recoveryCue then
		-- The recovery's look stays on the moment; its SOUND is placed by the cue's SoundDelay from it, a lead
		-- included (recovery is known now, windup + active seconds out). Both are dropped with a cancelled
		-- swing, like every other cue here.
		schedule(windup + active, epoch, function()
			SwingPresentation.PlayCue(recoveryCue, "Recovery", moveId, false)
		end)
		schedule(windup + active + MovePresentation.SoundDelay(recoveryCue), epoch, function()
			CombatAudio.PlayCueNow(recoveryCue)
		end)
	end
end

function SwingPresentation.Start(): ()
	if started then
		return
	end
	started = true
	table.insert(disconnects, AttackInputClient.OnAttackStarted(onAttackStarted))
	table.insert(
		disconnects,
		AttackInputClient.OnSwingCancelled(function()
			cancelEpoch += 1
			stopSwingLoops()
		end)
	)
	logger:debug("SwingPresentation started")
end

function SwingPresentation.Stop(): ()
	if not started then
		return
	end
	started = false
	for _, disconnect in disconnects do
		disconnect()
	end
	table.clear(disconnects)
	cancelEpoch += 1
	stopSwingLoops()
end

return SwingPresentation
