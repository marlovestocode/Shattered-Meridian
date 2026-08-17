--!strict
-- Covers Client/Parkour/States/init.lua -- the registry that is this framework's whole extension
-- point -- and, by requiring it, load-checks every one of the fifteen state modules plus
-- EnvironmentProbe, InputBuffer and ParkourMotor underneath them.
--
-- THE LOAD CHECK IS HALF THE VALUE HERE. Requiring the registry executes every state module's own
-- require chain, so a broken require path, a syntax error or a typo'd constant lookup in any of them
-- fails THIS spec rather than surfacing as a dead movement system the first time someone playtests.
-- That is the same reasoning scripts/run-tests.lua's own module load-check list documents, applied to
-- a folder whose modules nothing else in the suite would otherwise touch.
--
-- Everything else here is a structural invariant the state machine assumes but cannot itself enforce:
-- unique ids, a strict priority ordering, a complete interface, and probe/report declarations that
-- match what each state actually does. Every one of these is the kind of thing that breaks silently
-- when a sixteenth state is added -- which is exactly the moment this spec is for.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local States = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.States)
local StateMachine = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.StateMachine)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)

-- Every MovementStateId in ParkourTypes. Written out rather than derived, deliberately: a state
-- removed from the registry but left in the union (or vice versa) is exactly the drift this list
-- exists to catch, and deriving one from the other would make the test agree with itself.
local EXPECTED_IDS = {
	"Idle",
	"Walking",
	"Sprinting",
	"Jumping",
	"Falling",
	"Landing",
	"Sliding",
	"Vaulting",
	"Mantling",
	"WallRunning",
	"LedgeHanging",
	"LedgeClimbing",
	"Rolling",
	"Leaping",
	"LedgeLeaping",
	"AerialCombat",
}

local VALID_DRIVES = { Humanoid = true, Velocity = true, Kinematic = true }

-- Roblox's own default Workspace.Gravity. The slide reads the live value (a place-level setting a
-- designer can change), so this is the reference point the slope invariants below are stated at, not
-- an assumption about what any given place is set to.
local DEFAULT_GRAVITY = 196.2

-- Which states own the character's velocity and therefore MUST report to the server -- otherwise
-- Server/Combat/Movement.ComputeDesiredWalkSpeed keeps driving WalkSpeed underneath them, which is
-- the precise failure this feature's whole server integration exists to prevent.
-- No WallJumping entry: kicking off a wall is a phase of WallRunning now, not its own state, and
-- reports as a continuation of the same "WallRun" window (see ParkourTypes.ActionKind's own header).
local MUST_REPORT = {
	Sliding = "Slide",
	Vaulting = "Vault",
	Mantling = "Mantle",
	WallRunning = "WallRun",
	LedgeClimbing = "LedgeClimb",
	Rolling = "Roll",
	Leaping = "Leap",
	LedgeLeaping = "Leap",
}

local function byId(): { [string]: any }
	local map: { [string]: any } = {}
	for _, definition in States do
		map[definition.Id] = definition
	end
	return map
end

return function()
	describe("States registry -- membership", function()
		it("registers exactly the expected set of states", function()
			expect(#States).to.equal(#EXPECTED_IDS)
		end)

		it("registers every id in the MovementStateId union", function()
			local map = byId()
			for _, id in EXPECTED_IDS do
				expect(map[id]).never.to.equal(nil)
			end
		end)

		it("registers no id twice", function()
			local seen: { [string]: boolean } = {}
			for _, definition in States do
				expect(seen[definition.Id]).to.equal(nil)
				seen[definition.Id] = true
			end
		end)
	end)

	describe("States registry -- interface completeness", function()
		it("gives every state a CanEnter and an Update", function()
			for _, definition in States do
				expect(typeof(definition.CanEnter)).to.equal("function")
				expect(typeof(definition.Update)).to.equal("function")
			end
		end)

		it("gives every state a valid drive mode", function()
			for _, definition in States do
				expect(VALID_DRIVES[definition.Drive]).to.equal(true)
			end
		end)

		it("gives every state a probe request table", function()
			for _, definition in States do
				expect(typeof(definition.Probes)).to.equal("table")
			end
		end)

		it("gives every state a numeric priority", function()
			for _, definition in States do
				expect(typeof(definition.Priority)).to.equal("number")
			end
		end)
	end)

	describe("States registry -- priority ordering", function()
		it("assigns no two states the same priority", function()
			-- Equal priorities are not an error the machine cannot survive (it tiebreaks by id for
			-- determinism), but they ARE always a design mistake: two states at the same priority can
			-- never pre-empt each other, so one of them is silently unreachable from the other.
			local seen: { [number]: string } = {}
			for _, definition in States do
				expect(seen[definition.Priority]).to.equal(nil)
				seen[definition.Priority] = definition.Id
			end
		end)

		it("puts AerialCombat above everything -- combat ownership may never be pre-empted", function()
			local map = byId()
			for _, definition in States do
				if definition.Id ~= "AerialCombat" then
					expect(definition.Priority < map.AerialCombat.Priority).to.equal(true)
				end
			end
		end)

		it("orders the ground locomotion ladder Idle < Walking < Sprinting", function()
			local map = byId()
			expect(map.Idle.Priority < map.Walking.Priority).to.equal(true)
			expect(map.Walking.Priority < map.Sprinting.Priority).to.equal(true)
		end)

		it("puts every traversal above ordinary ground locomotion", function()
			local map = byId()
			for _, id in { "Sliding", "Vaulting", "Mantling", "WallRunning", "Rolling" } do
				expect(map[id].Priority > map.Sprinting.Priority).to.equal(true)
			end
		end)

		it("puts Vaulting above Mantling -- when both are viable the faster option wins", function()
			local map = byId()
			expect(map.Vaulting.Priority > map.Mantling.Priority).to.equal(true)
		end)

		it("puts LedgeClimbing above LedgeHanging", function()
			local map = byId()
			expect(map.LedgeClimbing.Priority > map.LedgeHanging.Priority).to.equal(true)
		end)
	end)

	describe("States registry -- server reporting", function()
		it("declares a report kind for every velocity-owning state", function()
			local map = byId()
			for id, expectedKind in MUST_REPORT do
				expect(map[id].Reports).to.equal(expectedKind)
			end
		end)

		it("declares NO report for ordinary locomotion -- those must not be network events", function()
			local map = byId()
			for _, id in { "Idle", "Walking", "Sprinting", "Jumping", "Falling", "Landing", "AerialCombat" } do
				expect(map[id].Reports).to.equal(nil)
			end
		end)

		it("never declares a report for a state that hands the body to the engine", function()
			-- A Humanoid-driven state reporting velocity ownership would make the server stand its own
			-- WalkSpeed resolver down while nothing was actually driving the character -- a dead stop.
			for _, definition in States do
				if definition.Reports ~= nil then
					expect(definition.Drive).never.to.equal("Humanoid")
				end
			end
		end)
	end)

	describe("States registry -- probe declarations", function()
		it("has every state request the ground probe", function()
			-- Ground gates essentially every decision in the framework, and EnvironmentProbe degrades a
			-- probe nobody asked for to a stale cached answer -- so a state that forgot to request it
			-- would make decisions off last frame's grounding.
			for _, definition in States do
				expect(definition.Probes.Ground).to.equal(true)
			end
		end)

		it("has the wall state request wall probes", function()
			local map = byId()
			expect(map.WallRunning.Probes.Walls).to.equal(true)
		end)

		it("has the ledge states request ledge probes", function()
			local map = byId()
			expect(map.LedgeHanging.Probes.Ledge).to.equal(true)
			expect(map.Falling.Probes.Ledge).to.equal(true)
		end)

		it("has the crouching states request the ceiling probe", function()
			-- Standing up inside geometry is the failure this probe exists to prevent, so both states
			-- that lower the character have to be asking for it.
			local map = byId()
			expect(map.Sliding.Probes.Ceiling).to.equal(true)
			expect(map.Rolling.Probes.Ceiling).to.equal(true)
		end)

		it("has the obstacle-traversal states request obstacle probes", function()
			local map = byId()
			expect(map.Vaulting.Probes.Obstacle).to.equal(true)
			expect(map.Mantling.Probes.Obstacle).to.equal(true)
		end)
	end)

	describe("States registry -- commitment", function()
		it("marks every kinematic traversal committed so nothing steals it mid-animation", function()
			local map = byId()
			for _, id in { "Vaulting", "Mantling", "LedgeClimbing" } do
				expect(map[id].Committed).to.equal(true)
			end
		end)

		it("commits the hang too -- a held pose owns its own exits", function()
			-- Not a traversal, but committed for a related reason. LedgeClimbing outranks LedgeHanging by
			-- one step, so an uncommitted hang is pre-empted into a climb on its FIRST frame and the hold
			-- never happens: the player jumps at a wall and is pulled up without asking. The paired guard
			-- is LedgeClimbing.CanEnter's own jump-input check; this is the structural half.
			expect(byId().LedgeHanging.Committed).to.equal(true)
		end)

		it("never lets a state be pre-empted into by a peer that accepts unconditionally", function()
			-- The general form of the bug above: if state B outranks state A and B.CanEnter is satisfiable
			-- purely by "A is active", then A is unreachable for more than one frame. Every state that
			-- names a predecessor must ALSO gate on something that predecessor does not supply on entry --
			-- an input, a timer, a probe. Asserted here for the one pair that has it (LedgeHanging ->
			-- LedgeClimbing) so a future state that copies the pattern has a failing test to read.
			local map = byId()
			expect(map.LedgeClimbing.Priority > map.LedgeHanging.Priority).to.equal(true)
			expect(map.LedgeHanging.Committed).to.equal(true)
		end)

		it("leaves ordinary locomotion interruptible", function()
			local map = byId()
			for _, id in { "Idle", "Walking", "Sprinting", "Falling" } do
				expect(map[id].Committed).never.to.equal(true)
			end
		end)
	end)

	describe("States registry -- machine integration", function()
		it("registers into a real StateMachine without collision", function()
			local machine = StateMachine.New("Idle")
			for _, definition in States do
				machine:Register(definition)
			end
			for _, id in EXPECTED_IDS do
				expect(machine:GetDefinition(id)).never.to.equal(nil)
			end
			expect(machine:GetCurrentId()).to.equal("Idle")
		end)
	end)

	describe("ParkourConstants -- action durations are reportable", function()
		it("keeps every reportable action's own duration inside the validator's ceiling", function()
			-- ParkourController sends each Start report a duration derived from these; one longer than
			-- MaxActionSeconds would be rejected server-side, which would silently mean that action never
			-- got velocity ownership at all.
			local ceiling = ParkourConstants.Validation.MaxActionSeconds
			expect(ParkourConstants.Slide.MaxDurationSeconds < ceiling).to.equal(true)
			expect(ParkourConstants.WallRun.MaxDurationSeconds < ceiling).to.equal(true)
			expect(ParkourConstants.Obstacle.MantleDurationSeconds < ceiling).to.equal(true)
			expect(ParkourConstants.Ledge.ClimbDurationSeconds < ceiling).to.equal(true)
			expect(ParkourConstants.Roll.DurationSeconds < ceiling).to.equal(true)
		end)

		it("keeps the ledge grab's attach pull short enough to read as a catch", function()
			-- The pull into the hang pose is dead time for the player: inputs do not open until it lands
			-- (States/LedgeHanging.Update). Past roughly a sixth of a second that stops reading as the
			-- character catching something and starts reading as input lag, which is the exact complaint
			-- the blend was added to fix -- so making it longer to smooth out a rough-looking grab would
			-- trade one clunk for a worse one.
			local ledge = ParkourConstants.Ledge
			expect(ledge.AttachMinSeconds > 0).to.equal(true)
			expect(ledge.AttachMinSeconds <= ledge.AttachMaxSeconds).to.equal(true)
			expect(ledge.AttachMaxSeconds <= 0.16).to.equal(true)
		end)

		it("keeps even the furthest legal grab moving at a speed the eye can follow", function()
			-- The cap does not truncate the blend -- alpha still runs 0 to 1 -- it makes the pull travel
			-- FASTER, so the thing worth bounding is the implied speed of the worst case rather than
			-- whether AttachSpeed alone could cover it. Worst case is a lip at the bottom of the band
			-- (dropping the root by the band depth plus the hang offset) at the far edge of the reach.
			-- Past roughly 60 studs/s that stops being a pull and becomes the single-frame relocation the
			-- whole blend exists to replace, so widening the grab band or the reach without revisiting
			-- AttachMaxSeconds is caught here.
			local ledge = ParkourConstants.Ledge
			local worstCase = Vector3.new(
				ledge.GrabReachDistance,
				ledge.GrabBandBelowHead + math.abs(ledge.HangVerticalOffset),
				0
			).Magnitude
			expect(worstCase / ledge.AttachMaxSeconds <= 60).to.equal(true)
			-- And the near case still has to be visible: at least a couple of frames of motion on a 30fps
			-- client, or the cheapest grabs go back to popping.
			expect(ledge.AttachMinSeconds >= 1 / 30).to.equal(true)
		end)

		it("keeps the blanket re-grab lockout far below the same-ledge one", function()
			-- The blanket window exists only to let the release push clear the body off the face; the long
			-- window is what stops the dropped edge being re-caught. Collapsing them back into one number
			-- is what made dropping down a stepped face feel like the system had stopped responding, so
			-- the two are asserted to be genuinely different orders of delay.
			local ledge = ParkourConstants.Ledge
			expect(ledge.RegrabAnyLedgeSeconds > 0).to.equal(true)
			expect(ledge.RegrabAnyLedgeSeconds < ledge.RegrabLockoutSeconds * 0.5).to.equal(true)
		end)

		it("keeps the slide's own speed band inside the validator's reported-speed ceiling", function()
			-- A slide that can legitimately exceed MaxReportedSpeed means an honest player on a big hill
			-- gets their own movement rejected by the server. Raising Slide.MaxSpeed without raising the
			-- validator with it has already happened once during tuning; this is what catches it.
			expect(ParkourConstants.Slide.MaxSpeed < ParkourConstants.Validation.MaxReportedSpeed).to.equal(true)
		end)

		it("keeps the momentum carry ceiling below slide speed", function()
			-- Exiting a fast downhill slide should carry real speed into the run that follows, but running
			-- at full slide speed on the flat is not something the carry is meant to grant.
			local carryCeiling = ParkourConstants.Locomotion.SprintSpeed
				* ParkourConstants.Locomotion.MomentumCarryMaxMultiplier
			expect(carryCeiling < ParkourConstants.Slide.MaxSpeed).to.equal(true)
			expect(carryCeiling > ParkourConstants.Locomotion.SprintSpeed).to.equal(true)
		end)

		it("sets the forced-slide angle low enough to catch a real ramp", function()
			-- The player-facing symptom this guards: at 48 degrees, running down a large purpose-built
			-- wedge (which sits around 35-40) did nothing whatsoever, and the entire slope system looked
			-- dead. Anything above ~45 is effectively unreachable on hand-built geometry.
			expect(ParkourConstants.Slope.ForcedSlideAngleDegrees <= 42).to.equal(true)
		end)

		it("forces a slide BEFORE a surface becomes unstandable, not after", function()
			-- "Steep enough that gravity owns you" has to trigger below "too steep to stand on at all",
			-- or there is a band of slope where the character neither slides nor can stand.
			expect(ParkourConstants.Slope.ForcedSlideAngleDegrees < ParkourConstants.Slope.MaxWalkableAngleDegrees).to.equal(
				true
			)
		end)

		it("keeps the sustain threshold below the forced-slide angle", function()
			-- A slope steep enough to force a slide must also be steep enough to sustain one, or a forced
			-- slide on a cliff would still expire on the flat-ground duration cap.
			expect(ParkourConstants.Slide.SustainSlopeDegrees < ParkourConstants.Slope.ForcedSlideAngleDegrees).to.equal(
				true
			)
		end)

		it("sustains a slide only on slopes that actually accelerate one", function()
			-- SustainSlopeDegrees suspends the slide's duration cap AND its speed floor, on the claim
			-- that terrain is carrying it. That claim has to be true: below the angle where the slope
			-- pull first exceeds flat-ground friction, suspending the exits would hold a slide open that
			-- is in fact decaying to a halt. Break-even is where
			-- gravity * sin(t) * SlopeGravityFraction == FrictionPerSecond * cos(t).
			local breakEven = math.deg(
				math.atan(
					ParkourConstants.Slide.FrictionPerSecond
						/ (DEFAULT_GRAVITY * ParkourConstants.Slide.SlopeGravityFraction)
				)
			)
			expect(ParkourConstants.Slide.SustainSlopeDegrees > breakEven).to.equal(true)
		end)

		it("starts a downhill slide moving without making it a burst", function()
			-- The player-facing symptom this guards: the slide drives the body through a velocity
			-- constraint, so an entry momentum near zero commands a velocity near zero and pins the
			-- character in place instead of sliding. The floor has to be high enough to visibly move and
			-- low enough that it is never worth taking for the speed alone.
			expect(ParkourConstants.Slide.DownhillEntrySpeed > 0).to.equal(true)
			expect(ParkourConstants.Slide.DownhillEntrySpeed < ParkourConstants.Locomotion.WalkSpeed).to.equal(true)
			expect(ParkourConstants.Slide.DownhillEntrySpeed < ParkourConstants.Slide.EntryMinSpeed).to.equal(true)
		end)

		it("keeps sprint speed above walk speed and slide entry near sprint", function()
			expect(ParkourConstants.Locomotion.SprintSpeed > ParkourConstants.Locomotion.WalkSpeed).to.equal(true)
			expect(ParkourConstants.Slide.EntryMinSpeed <= ParkourConstants.Locomotion.SprintSpeed).to.equal(true)
		end)
	end)
end
