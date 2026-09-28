--!strict
-- Covers Server/Combat/TrainingBot/TrainingBotBrain.lua.
--
-- The brain is pure -- a Perception and a seeded Random in, an Intent out -- so every case here drives it
-- frame by frame on a synthetic clock with no rig, no engine and no Heartbeat. The claims worth holding
-- it to are the ones that make it fight like a person rather than an input reader: it cannot answer a
-- swing it has not had time to see, its parry presses land inside the real window most (not all) of the
-- time and less often at lower difficulty, it learns habits and changes what it does because of them,
-- and the pure drills never step outside their one job.
--
-- Anything statistical is asserted over a FIXED range of seeds, so it is deterministic run to run; the
-- thresholds are loose enough that retuning a difficulty's numbers does not break them, and tight
-- enough that a brain which ignored those numbers would.

local ServerScriptService = game:GetService("ServerScriptService")

local TrainingBotBrain = require(ServerScriptService.Server.Combat.TrainingBot.TrainingBotBrain)

type Perception = TrainingBotBrain.Perception
type SwingView = TrainingBotBrain.SwingView

local FRAME = 1 / 60
local REACH = 6.8
local WINDUP = 0.6
local PARRY_OPEN = 0
local PARRY_CLOSE = 0.2

local function perception(overrides: { [string]: any }?): Perception
	local p: { [string]: any } = {
		Now = 0,
		HasTarget = true,
		Distance = 5,
		Reach = REACH,
		TargetReach = REACH,
		FacingError = 0,
		BearingFromTarget = 0,
		TargetSwing = nil,
		TargetAttackState = "Idle",
		TargetDefenseState = "Neutral",
		TargetGuardFraction = 1,
		TargetStunned = false,
		SelfSwing = nil,
		SelfAttackState = "Idle",
		SelfBusyUntil = 0,
		SelfDefenseState = "Neutral",
		SelfGuardFraction = 1,
		SelfHealthFraction = 1,
		SelfDisabled = false,
		SelfLocked = false,
		ParryArmableAt = 0,
		SelfRolling = false,
		EvadeReady = true,
		HomeDistance = 0,
		FeintWindowFraction = 0.5,
		ParryOpen = PARRY_OPEN,
		ParryClose = PARRY_CLOSE,
		EvadeStartup = 0.06,
		EvadeActive = 0.25,
	}
	if overrides then
		for key, value in overrides do
			p[key] = value
		end
	end
	return (p :: any) :: Perception
end

local function heavySwing(startedAt: number, feintable: boolean?): SwingView
	return {
		StartedAt = startedAt,
		WindupSeconds = WINDUP,
		Feintable = feintable == true,
		Heavy = true,
	}
end

-- Plays one swing at the brain from `from` to `untilTime`, the swing visible while `visibleUntil`
-- has not passed (a feint or an early end is just a shorter visibleUntil). Returns the first time the
-- brain wanted its guard up, or nil.
local function playSwing(
	brain: TrainingBotBrain.Brain,
	swing: SwingView,
	from: number,
	untilTime: number,
	visibleUntil: number,
	overrides: { [string]: any }?
): number?
	local firstGuard: number? = nil
	local t = from
	while t < untilTime do
		local fields: { [string]: any } = { Now = t }
		if overrides then
			for key, value in overrides do
				fields[key] = value
			end
		end
		if t < visibleUntil then
			fields.TargetSwing = swing
			fields.TargetAttackState = if t < swing.StartedAt + swing.WindupSeconds then "Windup" else "Active"
		end
		local intent = TrainingBotBrain.Think(brain, perception(fields))
		if intent.Guard and firstGuard == nil then
			firstGuard = t
		end
		t += FRAME
	end
	return firstGuard
end

-- Whether a press at `pressAt` opens a window that covers an impact at `impactAt`.
local function covers(pressAt: number?, impactAt: number): boolean
	if pressAt == nil then
		return false
	end
	return pressAt + PARRY_OPEN <= impactAt and impactAt <= pressAt + PARRY_CLOSE
end

return function()
	describe("TrainingBotBrain -- seeing the swing", function()
		it("cannot answer a swing before its reaction time has passed", function()
			for seed = 1, 20 do
				local brain = TrainingBotBrain.new("ParryOnly", "Master", Random.new(seed))
				local swing = heavySwing(0)
				-- Master's floor is ReactionMinSeconds; nothing may happen inside it.
				local pressed = playSwing(brain, swing, 0, brain.Difficulty.ReactionMinSeconds, 10)
				expect(pressed).to.equal(nil)
			end
		end)

		it("lets a swing from out of range whiff rather than defending it", function()
			local brain = TrainingBotBrain.new("ParryOnly", "Master", Random.new(7))
			local pressed = playSwing(brain, heavySwing(0), 0, 1, 1, { Distance = 20 })
			expect(pressed).to.equal(nil)
		end)
	end)

	describe("TrainingBotBrain -- timing", function()
		it("a Master's parry covers the impact nearly every time", function()
			local hits = 0
			for seed = 1, 50 do
				local brain = TrainingBotBrain.new("ParryOnly", "Master", Random.new(seed))
				local pressed = playSwing(brain, heavySwing(0), 0, 1, 1)
				if covers(pressed, WINDUP) then
					hits += 1
				end
			end
			expect(hits >= 45).to.equal(true)
		end)

		it("a Novice's parry covers it markedly less often than a Master's", function()
			local function successes(difficulty: string): number
				local count = 0
				for seed = 1, 60 do
					local brain = TrainingBotBrain.new("ParryOnly", difficulty, Random.new(seed))
					if covers(playSwing(brain, heavySwing(0), 0, 1, 1), WINDUP) then
						count += 1
					end
				end
				return count
			end
			local novice = successes("Novice")
			local master = successes("Master")
			expect(novice < master - 5).to.equal(true)
			-- ...but a novice is not hopeless either.
			expect(novice > 10).to.equal(true)
		end)

		it("holds its block through a string instead of re-reacting to every hit", function()
			local brain = TrainingBotBrain.new("BlockOnly", "Master", Random.new(4))
			-- BlockOnly holds its guard at close range anyway; switched off so this measures the carry-over
			-- from one swing's block into the next, not the neutral stance.
			local style = table.clone(brain.Style) :: any
			style.HoldGuardInNeutral = false
			brain.Style = style
			local function basic(startedAt: number): SwingView
				return { StartedAt = startedAt, WindupSeconds = 0.3, Feintable = false, Heavy = false }
			end
			-- Two Basics back to back: the second starts 0.05s after the first stops being visible.
			local firstGuard = playSwing(brain, basic(0), 0, 0.7, 0.7)
			expect(firstGuard).to.be.ok()
			local dropped = false
			local t = 0.7
			while t < 1.1 do
				local intent = TrainingBotBrain.Think(
					brain,
					perception({
						Now = t,
						TargetSwing = if t >= 0.75 then basic(0.75) else nil,
						TargetAttackState = if t >= 0.75 then "Windup" else "Idle",
					})
				)
				if not intent.Guard then
					dropped = true
				end
				t += FRAME
			end
			expect(dropped).to.equal(false)
		end)

		it("reads a string's rhythm and sees the on-beat follow-ups early", function()
			local early = 0
			for seed = 1, 30 do
				local brain = TrainingBotBrain.new("FullFight", "Master", Random.new(seed))
				local function basic(startedAt: number): SwingView
					return { StartedAt = startedAt, WindupSeconds = 0.31, Feintable = false, Heavy = false }
				end
				-- Three M1s on a steady 0.74s beat; the third is the one that should be read.
				for index = 0, 2 do
					local start = index * 0.74
					TrainingBotBrain.Think(
						brain,
						perception({ Now = start, TargetSwing = basic(start), TargetAttackState = "Windup" })
					)
					if index == 2 then
						local threat = brain.Threat :: any
						if threat.NoticeAt - threat.StartedAt < 0.13 then
							early += 1
						end
					end
					TrainingBotBrain.Think(brain, perception({ Now = start + 0.7 }))
				end
			end
			-- Master reads rhythm 90% of the time; its ordinary reaction floor is 0.13s, so nothing else counts.
			expect(early >= 18).to.equal(true)
		end)

		it("guards the next hit out of a hitstun instead of giving up on it", function()
			local guarded = 0
			for seed = 1, 20 do
				local brain = TrainingBotBrain.new("ParryOnly", "Master", Random.new(seed))
				local stunEnds = 0.35
				local sawGuard = false
				local t = 0
				while t < WINDUP do
					local stunned = t < stunEnds
					local intent = TrainingBotBrain.Think(
						brain,
						perception({
							Now = t,
							TargetSwing = heavySwing(0),
							TargetAttackState = "Windup",
							SelfDisabled = stunned,
							SelfBusyUntil = stunEnds,
						})
					)
					if intent.Guard and t >= stunEnds - FRAME then
						sawGuard = true
					end
					t += FRAME
				end
				if sawGuard then
					guarded += 1
				end
				expect(brain.Stats.Busy).to.equal(0)
			end
			expect(guarded >= 18).to.equal(true)
		end)

		it("never raises a guard it cannot legally raise in time through its own swing", function()
			local brain = TrainingBotBrain.new("ParryOnly", "Master", Random.new(3))
			-- Committed to its own swing until after the incoming one lands.
			local pressed = playSwing(brain, heavySwing(0), 0, 1, 1, { SelfBusyUntil = 5 })
			expect(pressed).to.equal(nil)
		end)
	end)

	describe("TrainingBotBrain -- feints", function()
		it("learns that you feint from feintable swings that vanish early", function()
			local brain = TrainingBotBrain.new("FullFight", "Adept", Random.new(11))
			local start = 0
			for _ = 1, 6 do
				-- Visible for a third of the windup, then gone: a feint.
				playSwing(brain, heavySwing(start, true), start, start + 1, start + WINDUP * 0.3)
				start += 1.5
			end
			expect(brain.Habits.Feint > 0.5).to.equal(true)
		end)

		it("un-learns it when the feintable swings keep landing", function()
			local brain = TrainingBotBrain.new("FullFight", "Adept", Random.new(12))
			brain.Habits.Feint = 0.9
			local start = 0
			for _ = 1, 8 do
				playSwing(brain, heavySwing(start, true), start, start + 1.2, start + 1)
				start += 1.5
			end
			expect(brain.Habits.Feint < 0.3).to.equal(true)
		end)

		it("once it knows you feint, a Master waits out the feint window before committing", function()
			local brain = TrainingBotBrain.new("ParryOnly", "Master", Random.new(5))
			brain.Habits.Feint = 0.9
			local swing = heavySwing(0, true)
			local feintSafeAt = WINDUP * 0.5
			playSwing(brain, swing, 0, feintSafeAt - 0.02, 10)
			local threat = brain.Threat
			expect(threat).to.be.ok()
			expect((threat :: any).Decided).to.equal(false)
			playSwing(brain, swing, feintSafeAt - 0.02, feintSafeAt + 0.1, 10)
			expect((brain.Threat :: any).Decided).to.equal(true)
		end)

		it("arms and emits its own planned feint inside the window", function()
			local brain = TrainingBotBrain.new("FullFight", "Master", Random.new(2))
			brain.Plan = {
				Label = "Feint the Heavy",
				Queue = { "Heavy", "Basic" },
				FeintFraction = 0.5,
				FeintAt = nil,
				WantedSince = nil,
				ExpiresAt = 10,
				Punish = false,
			}
			TrainingBotBrain.OnOwnSwingAccepted(brain, "Heavy", heavySwing(0, true), 0.5)
			local plan = brain.Plan :: any
			expect(plan.Queue[1]).to.equal("Basic")
			-- Half of a half-windup feint window.
			expect(math.abs(plan.FeintAt - WINDUP * 0.25) < 1e-6).to.equal(true)
			local intent = TrainingBotBrain.Think(
				brain,
				perception({
					Now = WINDUP * 0.25 + 0.01,
					SelfAttackState = "Windup",
					SelfSwing = heavySwing(0, true),
					SelfBusyUntil = 2,
				})
			)
			expect(intent.Feint).to.equal(true)
		end)
	end)

	describe("TrainingBotBrain -- reading habits", function()
		it("tracks how you answer its swings", function()
			local brain = TrainingBotBrain.new("FullFight", "Adept", Random.new(1))
			for _ = 1, 10 do
				TrainingBotBrain.OnOutcome(brain, "Attacker", "Blocked", 0)
			end
			expect(brain.Habits.Block > 0.8).to.equal(true)
			expect(brain.Habits.Clean < 0.1).to.equal(true)
			expect(string.find(TrainingBotBrain.DescribeRead(brain), "blk", 1, true)).to.be.ok()
		end)

		it("opens with Heavies more often against someone who blocks", function()
			local function heavyOpeners(blockHabit: number): number
				local count = 0
				for seed = 1, 120 do
					local brain = TrainingBotBrain.new("FullFight", "Master", Random.new(seed))
					brain.Habits.Block = blockHabit
					brain.Habits.Parry = 0
					local t = 0
					while brain.Plan == nil and t < 3 do
						TrainingBotBrain.Think(brain, perception({ Now = t }))
						t += FRAME
					end
					local plan = brain.Plan
					if plan and plan.Queue[1] == "Heavy" then
						count += 1
					end
				end
				return count
			end
			expect(heavyOpeners(0.9) > heavyOpeners(0) + 10).to.equal(true)
		end)
	end)

	describe("TrainingBotBrain -- offence", function()
		it("punishes a staggered target", function()
			local punished = 0
			for seed = 1, 20 do
				local brain = TrainingBotBrain.new("FullFight", "Master", Random.new(seed))
				local intent = TrainingBotBrain.Think(brain, perception({ Now = 0, TargetDefenseState = "Staggered" }))
				local plan = brain.Plan
				if plan and plan.Punish and intent.Attack == "Basic" then
					punished += 1
				end
			end
			expect(punished >= 15).to.equal(true)
		end)

		it("judges each opening once rather than re-rolling it every frame", function()
			local brain = TrainingBotBrain.new("FullFight", "Novice", Random.new(4))
			local punishPlans = 0
			for frame = 0, 90 do
				TrainingBotBrain.Think(brain, perception({ Now = frame * FRAME, TargetDefenseState = "Staggered" }))
				local plan = brain.Plan
				if plan and plan.Punish then
					punishPlans += 1
					break
				end
				brain.Plan = nil
			end
			-- Either it took the one roll it gets or it declined it -- a Novice re-rolling a 35% chance
			-- every frame would take it within a few frames every single time.
			expect(punishPlans <= 1).to.equal(true)
			expect(brain.PunishJudgedState).to.equal("Staggered")
		end)

		it("AttackOnly presses the attack from inside its reach", function()
			local brain = TrainingBotBrain.new("AttackOnly", "Adept", Random.new(9))
			local attacked = false
			local t = 0
			while t < 3 and not attacked do
				local intent = TrainingBotBrain.Think(brain, perception({ Now = t }))
				attacked = intent.Attack ~= nil
				t += FRAME
			end
			expect(attacked).to.equal(true)
		end)

		it("the defensive drills never attack, not even to punish", function()
			for _, style in { "BlockOnly", "ParryOnly", "DodgeOnly" } do
				local brain = TrainingBotBrain.new(style, "Master", Random.new(6))
				local t = 0
				while t < 3 do
					local intent = TrainingBotBrain.Think(
						brain,
						perception({ Now = t, TargetDefenseState = if t > 1 then "Staggered" else "Neutral" })
					)
					expect(intent.Attack).to.equal(nil)
					expect(intent.Feint).to.equal(false)
					t += FRAME
				end
			end
		end)
	end)

	describe("TrainingBotBrain -- posture and mood", function()
		it("a Turtle holds its guard in neutral when you are close", function()
			local brain = TrainingBotBrain.new("Turtle", "Adept", Random.new(8))
			brain.Style = table.clone(brain.Style) :: any
			(brain.Style :: any).Aggression = 0
			local intent = TrainingBotBrain.Think(brain, perception({ Now = 0, Distance = REACH }))
			expect(intent.Guard).to.equal(true)
		end)

		it("a rattled bot gives more ground", function()
			local calm = TrainingBotBrain.new("DodgeOnly", "Adept", Random.new(10))
			local rattled = TrainingBotBrain.new("DodgeOnly", "Adept", Random.new(10))
			rattled.Composure = 0
			local at = perception({ Now = 0, Distance = REACH + 1 })
			local calmIntent = TrainingBotBrain.Think(calm, at)
			-- Think recovers composure by elapsed time; at Now = 0 no time has passed.
			local rattledIntent = TrainingBotBrain.Think(rattled, at)
			expect(calmIntent.Move ~= "Retreat").to.equal(true)
			expect(rattledIntent.Move).to.equal("Retreat")
		end)

		it("walks home and forgets the fight when it has no target", function()
			local brain = TrainingBotBrain.new("FullFight", "Adept", Random.new(1))
			TrainingBotBrain.Think(brain, perception({ Now = 0, TargetSwing = heavySwing(0) }))
			local intent =
				TrainingBotBrain.Think(brain, perception({ Now = 0.1, HasTarget = false, HomeDistance = 30 }))
			expect(intent.Move).to.equal("Home")
			expect(brain.Threat).to.equal(nil)
		end)
	end)
end
