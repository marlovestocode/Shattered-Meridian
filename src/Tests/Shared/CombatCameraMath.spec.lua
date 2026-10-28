--!strict
-- Covers Shared/CombatCameraMath.lua. Both halves MOVED there (from LockOnController.pullCamera and ShiftLockCamera's yaw
-- guards), so each is proved against a verbatim copy of the code it replaced, over a corpus, rather than asserted.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local CombatCameraMath = require(ReplicatedStorage.Shared.CombatCameraMath)
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
local LockOnConstants = require(ReplicatedStorage.Shared.Combat.LockOnConstants)
local CombatTargets = require(StarterPlayer.StarterPlayerScripts.Client.Combat.CombatTargets)

-- CombatTargets.YawOf and AngleDelta as they stood before they became FlightMath's (verbatim): the corpus below compares
-- against these, not against the aliases that now point at the new code.
local function oldYawOf(direction: Vector3): number?
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		return nil
	end
	return math.atan2(-flat.X, -flat.Z)
end

local function oldAngleDelta(from: number, to: number): number
	local delta = (to - from) % (2 * math.pi)
	if delta > math.pi then
		delta -= 2 * math.pi
	end
	return delta
end

local TUNING: CombatCameraMath.LookTuning = LockOnConstants.Camera
local FRAME = 1 / 60

-- LockOnController.pullCamera as it stood before the move, minus the camera write: returns (pitch, yaw) or nil.
local function oldPull(
	velocities: { Yaw: number, Pitch: number },
	look: Vector3,
	focus: Vector3,
	aim: Vector3,
	bodyPosition: Vector3,
	deltaTime: number
): (number?, number?)
	local tuning = LockOnConstants.Camera
	local direction = aim - focus
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local bodyOffset = aim - bodyPosition
	local bodyDistance = Vector3.new(bodyOffset.X, 0, bodyOffset.Z).Magnitude
	if bodyDistance < tuning.MinDistanceStuds then
		velocities.Yaw = 0
		velocities.Pitch = 0
		return nil, nil
	end
	local currentYaw = oldYawOf(look)
	local desiredYaw = oldYawOf(flat)
	if currentYaw == nil or desiredYaw == nil then
		return nil, nil
	end
	local currentPitch = math.asin(math.clamp(look.Y, -1, 1))
	local desiredPitch =
		math.clamp(math.atan2(direction.Y, flat.Magnitude) + tuning.PitchBias, tuning.MinPitch, tuning.MaxPitch)
	local closeness = math.clamp(
		(bodyDistance - tuning.MinDistanceStuds) / math.max(tuning.CloseRangeStuds - tuning.MinDistanceStuds, 1e-3),
		0,
		1
	)
	local scale = tuning.CloseRangeScale + (1 - tuning.CloseRangeScale) * closeness
	local yaw, nextYawVelocity = FlightMath.SpringStep(
		currentYaw,
		velocities.Yaw,
		currentYaw + oldAngleDelta(currentYaw, desiredYaw),
		tuning.YawFrequency * scale,
		tuning.Damping,
		deltaTime
	)
	local pitch, nextPitchVelocity = FlightMath.SpringStep(
		currentPitch,
		velocities.Pitch,
		desiredPitch,
		tuning.PitchFrequency * scale,
		tuning.Damping,
		deltaTime
	)
	velocities.Yaw = nextYawVelocity
	velocities.Pitch = nextPitchVelocity
	return pitch, yaw
end

-- ShiftLockCamera's guards as they stood before the move: true when the yaw write was skipped.
local function oldHeld(flags: CombatCameraMath.FacingFlags): boolean
	local lockOwnsFacing = flags.RootControlLocked
		and not (flags.PunishLocked and not flags.Grabbed and not flags.Mounted)
	if lockOwnsFacing or flags.Flying then
		return true
	end
	if flags.ParkourFacingOwned or flags.CombatFacingOwned then
		return true
	end
	return false
end

local function lookAt(yaw: number, pitch: number): Vector3
	return CFrame.fromOrientation(pitch, yaw, 0).LookVector
end

return function()
	describe("CombatCameraMath.LockOnLook", function()
		it("answers exactly as LockOnController.pullCamera did, frame after frame, over a corpus", function()
			local random = Random.new(20261027)
			for case = 1, 200 do
				local state = CombatCameraMath.NewLookState()
				local old = { Yaw = 0, Pitch = 0 }
				local look = lookAt(random:NextNumber(-math.pi, math.pi), random:NextNumber(-0.6, 0.4))
				local body =
					Vector3.new(random:NextNumber(-50, 50), random:NextNumber(0, 20), random:NextNumber(-50, 50))
				local focus = body + Vector3.new(random:NextNumber(-2, 2), 1.5, random:NextNumber(-2, 2))
				-- Some cases inside MinDistanceStuds, some far, some above and below.
				local reach = if case % 10 == 0 then random:NextNumber(0, 2) else random:NextNumber(2, 40)
				local bearing = random:NextNumber(-math.pi, math.pi)
				local aim = body
					+ Vector3.new(math.cos(bearing) * reach, random:NextNumber(-8, 12), math.sin(bearing) * reach)
				for _ = 1, 20 do
					local pitch, yaw = CombatCameraMath.LockOnLook(state, look, focus, aim, body, FRAME, TUNING)
					local oldPitch, oldYaw = oldPull(old, look, focus, aim, body, FRAME)
					expect(pitch == nil).to.equal(oldPitch == nil)
					expect(yaw == nil).to.equal(oldYaw == nil)
					if pitch == nil or yaw == nil or oldPitch == nil or oldYaw == nil then
						break
					end
					-- Not bit-exact: FlightMath normalises the flat vector (float32 Vector3) before atan2 and the old YawOf
					-- did not, which moves the angle in the seventh decimal.
					expect(pitch).to.be.near(oldPitch, 1e-5)
					expect(yaw).to.be.near(oldYaw, 1e-5)
					expect(state.YawVelocity).to.be.near(old.Yaw, 1e-3)
					expect(state.PitchVelocity).to.be.near(old.Pitch, 1e-3)
					look = lookAt(yaw, pitch)
				end
			end
		end)

		it("turns the short way round a target behind the view", function()
			local state = CombatCameraMath.NewLookState()
			local yaw0 = math.pi - 0.1
			local look = lookAt(yaw0, 0)
			-- A target just past +pi: the short way is a small positive turn, not most of a circle back.
			local aim = Vector3.zero + lookAt(-math.pi + 0.1, 0) * 20
			local _, yaw = CombatCameraMath.LockOnLook(state, look, Vector3.zero, aim, Vector3.zero, FRAME, TUNING)
			expect(yaw).to.be.ok()
			expect(math.abs(FlightMath.AngleDelta(yaw0, yaw :: number)) < 0.2).to.equal(true)
			expect(state.YawVelocity > 0).to.equal(true)
		end)

		it("stands down and forgets its swing when the bodies overlap", function()
			local state = CombatCameraMath.NewLookState()
			state.YawVelocity = 3
			state.PitchVelocity = -2
			local pitch = CombatCameraMath.LockOnLook(
				state,
				lookAt(0, 0),
				Vector3.zero,
				Vector3.new(0.5, 0, 0.5),
				Vector3.zero,
				FRAME,
				TUNING
			)
			expect(pitch).to.equal(nil)
			expect(state.YawVelocity).to.equal(0)
			expect(state.PitchVelocity).to.equal(0)
		end)

		it("never pulls the pitch past its clamp", function()
			local state = CombatCameraMath.NewLookState()
			local look = lookAt(0, 0)
			local pitch = 0
			for _ = 1, 600 do
				local nextPitch, yaw = CombatCameraMath.LockOnLook(
					state,
					look,
					Vector3.zero,
					Vector3.new(0, 500, -10),
					Vector3.zero,
					FRAME,
					TUNING
				)
				pitch = nextPitch :: number
				look = lookAt(yaw :: number, pitch)
			end
			expect(pitch <= TUNING.MaxPitch + 1e-3).to.equal(true)
		end)
	end)

	describe("the re-exported angle helpers", function()
		it("give the old CombatTargets answers", function()
			local random = Random.new(7)
			for _ = 1, 500 do
				local direction =
					Vector3.new(random:NextNumber(-10, 10), random:NextNumber(-10, 10), random:NextNumber(-10, 10))
				local new = CombatTargets.YawOf(direction)
				local old = oldYawOf(direction)
				expect(new == nil).to.equal(old == nil)
				if new and old then
					expect(new).to.be.near(old, 1e-5)
				end
				local a, b = random:NextNumber(-10, 10), random:NextNumber(-10, 10)
				expect(CombatTargets.AngleDelta(a, b)).to.equal(oldAngleDelta(a, b))
			end
		end)
	end)

	describe("CombatCameraMath.BodyFacingHeld", function()
		it("answers as the yaw guards it replaced, over all 128 combinations", function()
			local names = {
				"RootControlLocked",
				"PunishLocked",
				"Grabbed",
				"Mounted",
				"Flying",
				"ParkourFacingOwned",
				"CombatFacingOwned",
			}
			for mask = 0, 2 ^ #names - 1 do
				local flags: any = {}
				for index, name in names do
					flags[name] = bit32.band(mask, 2 ^ (index - 1)) ~= 0
				end
				expect(CombatCameraMath.BodyFacingHeld(flags)).to.equal(oldHeld(flags))
			end
		end)

		it("leaves a staggered body to shift lock, but not a staggered body that is also grabbed", function()
			local flags: CombatCameraMath.FacingFlags = {
				RootControlLocked = true,
				PunishLocked = true,
				Grabbed = false,
				Mounted = false,
				Flying = false,
				ParkourFacingOwned = false,
				CombatFacingOwned = false,
			}
			expect(CombatCameraMath.BodyFacingHeld(flags)).to.equal(false)
			flags.Grabbed = true
			expect(CombatCameraMath.BodyFacingHeld(flags)).to.equal(true)
		end)
	end)
end
