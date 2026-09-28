--!strict
-- Covers Server/Boat/BoatDrive.lua -- the sailing integration, and in particular the three properties
-- that make a boat a boat rather than a slower blimp: the wind owns the speed, the rudder dies with the
-- way, and a beached hull can still back off.
--
-- Every case below advances a plain table. That is the whole payoff of BoatDrive touching no Instance:
-- "does full sail into the wind really make zero way" is a question about a curve, and answering it in a
-- playtest means sailing a boat at a heading you have to eyeball.
--
-- What is NOT covered here, and cannot be: whether AlignPosition actually moves the hull to the target,
-- whether the constraints are strong enough for a loaded deck, or whether any of it FEELS right. Those
-- need a physics-live place and a person.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local BoatTypes = require(ReplicatedStorage.Shared.Boat.BoatTypes)
local BoatWind = require(ReplicatedStorage.Shared.Boat.BoatWind)
local BoatDrive = require(ServerScriptService.Server.Boat.BoatDrive)

-- A hull whose root happens to face the way the artist drew her, so ForwardYawRadians is 0 and the
-- bearing arithmetic in the assertions stays readable. The one test that cares about a mis-oriented root
-- builds its own.
local function tuning(overrides: { [string]: number }?): BoatTypes.DriveTuning
	local drive = BoatConstants.Drive
	local result: BoatTypes.DriveTuning = {
		ForwardYawRadians = 0,
		HullSpeed = drive.HullSpeed,
		SternwaySpeed = drive.SternwaySpeed,
		Acceleration = drive.Acceleration,
		Deceleration = drive.Deceleration,
		TurnRate = drive.TurnRate,
		TurnAcceleration = drive.TurnAcceleration,
		MinRudderAuthority = drive.MinRudderAuthority,
		RudderAuthorityFullAtSpeedFraction = drive.RudderAuthorityFullAtSpeedFraction,
		LeewayFraction = drive.LeewayFraction,
		WaterlineOffset = drive.WaterlineOffset,
		HeaveSpeed = drive.HeaveSpeed,
		HeaveAcceleration = drive.HeaveAcceleration,
		HeelRadiansPerTurnRate = drive.HeelRadiansPerTurnRate,
		HeelRadiansPerWindPressure = drive.HeelRadiansPerWindPressure,
		MaxHeelRadians = drive.MaxHeelRadians,
		TrimRadiansPerAccel = drive.TrimRadiansPerAccel,
		MaxTrimRadians = drive.MaxTrimRadians,
	}
	for key, value in overrides or {} do
		(result :: any)[key] = value
	end
	return result
end

local FULL_WIND_ASTERN: BoatTypes.WindSample = { BearingRadians = 0, Strength = 1 }
local AFLOAT: BoatTypes.WaterSample = { SurfaceY = 0, Supported = true }
local AGROUND: BoatTypes.WaterSample = { SurfaceY = 0, Supported = false }

-- A hull at the origin facing world -Z (bearing 0). With FULL_WIND_ASTERN's own bearing also 0, that is
-- dead into the wind -- in irons -- which is the state several cases below start from deliberately.
local function stateFacing(bearing: number): BoatTypes.DriveState
	local look = CFrame.Angles(0, bearing, 0).LookVector
	return {
		Target = CFrame.lookAt(Vector3.zero, look),
		Speed = 0,
		YawRate = 0,
		HeaveRate = 0,
	}
end

-- Runs `seconds` of sailing at a fixed 1/60 step, which is what the real tick does.
local function sail(
	state: BoatTypes.DriveState,
	intent: BoatTypes.DriveIntent,
	config: BoatTypes.DriveTuning,
	wind: BoatTypes.WindSample,
	water: BoatTypes.WaterSample,
	seconds: number
): BoatTypes.DriveState
	local step = 1 / 60
	for _ = 1, math.floor(seconds / step) do
		state = BoatDrive.Step(state, intent, config, wind, water, step, 1)
	end
	return state
end

return function()
	describe("SanitizeHelmInput", function()
		it("accepts a well-formed rudder", function()
			local input = BoatDrive.SanitizeHelmInput({ Steer = 0.5 })
			expect(input).to.be.ok()
			expect((input :: BoatTypes.HelmInput).Steer).to.equal(0.5)
		end)

		it("clamps rather than rejects an out-of-range axis -- hard over is the honest reading", function()
			expect((BoatDrive.SanitizeHelmInput({ Steer = 7 }) :: BoatTypes.HelmInput).Steer).to.equal(1)
			expect((BoatDrive.SanitizeHelmInput({ Steer = -7 }) :: BoatTypes.HelmInput).Steer).to.equal(-1)
		end)

		it("refuses anything that is not a table with a finite Steer", function()
			expect(BoatDrive.SanitizeHelmInput(nil)).to.never.be.ok()
			expect(BoatDrive.SanitizeHelmInput(3)).to.never.be.ok()
			expect(BoatDrive.SanitizeHelmInput({})).to.never.be.ok()
			expect(BoatDrive.SanitizeHelmInput({ Steer = "hard over" })).to.never.be.ok()
			expect(BoatDrive.SanitizeHelmInput({ Steer = 0 / 0 })).to.never.be.ok()
			expect(BoatDrive.SanitizeHelmInput({ Steer = math.huge })).to.never.be.ok()
		end)

		it("returns nil rather than a neutral input, because neutral is a real command", function()
			-- Centring the rudder is a thing a helmsman does. If a malformed packet resolved to it, a
			-- tampered client could centre a rival's helm by sending garbage.
			local centred = BoatDrive.SanitizeHelmInput({ Steer = 0 })
			expect(centred).to.be.ok()
			expect(BoatDrive.SanitizeHelmInput("garbage")).to.never.be.ok()
		end)
	end)

	describe("the wind owns the speed", function()
		it("makes ZERO way with full sail set dead into the wind", function()
			local after = sail(stateFacing(0), { Sail = 1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 6)
			expect(after.Speed).to.equal(0)
			-- HORIZONTALLY unmoved. The Y is deliberately not checked against the start here: the hull
			-- floats up to the waterline whatever her sails are doing, which is the water's business and
			-- not the wind's, and is asserted in its own block below.
			expect(after.Target.Position.X).to.be.near(0, 1e-6)
			expect(after.Target.Position.Z).to.be.near(0, 1e-6)
		end)

		it("makes way once she bears away out of the no-go arc", function()
			local reaching = stateFacing(BoatConstants.Wind.PeakRadians)
			local after = sail(reaching, { Sail = 1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 6)
			expect(after.Speed > 0).to.equal(true)
		end)

		it("tops out at hull speed on the best point of sail in a full wind", function()
			local reaching = stateFacing(BoatConstants.Wind.PeakRadians)
			local after = sail(reaching, { Sail = 1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 40)
			expect(after.Speed).to.be.near(BoatConstants.Drive.HullSpeed, 0.5)
		end)

		it("goes slower in a lighter wind on the same heading", function()
			local heading = BoatConstants.Wind.PeakRadians
			local strong = sail(stateFacing(heading), { Sail = 1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 40)
			local light = sail(
				stateFacing(heading),
				{ Sail = 1, Steer = 0 },
				tuning(),
				{ BearingRadians = 0, Strength = 0.5 },
				AFLOAT,
				40
			)
			expect(light.Speed < strong.Speed).to.equal(true)
		end)

		it("goes slower with less canvas on the same heading in the same wind", function()
			local heading = BoatConstants.Wind.PeakRadians
			local full = sail(stateFacing(heading), { Sail = 1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 40)
			local reefed =
				sail(stateFacing(heading), { Sail = 0.45, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 40)
			expect(reefed.Speed < full.Speed).to.equal(true)
		end)

		it("goes slower running than reaching -- the polar, felt in the integrator", function()
			local reach = sail(
				stateFacing(BoatConstants.Wind.PeakRadians),
				{ Sail = 1, Steer = 0 },
				tuning(),
				FULL_WIND_ASTERN,
				AFLOAT,
				40
			)
			local run = sail(stateFacing(math.pi), { Sail = 1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 40)
			expect(run.Speed < reach.Speed).to.equal(true)
			expect(run.Speed > 0).to.equal(true)
		end)
	end)

	describe("she carries her way", function()
		it("takes longer to stop than to start", function()
			local heading = BoatConstants.Wind.PeakRadians
			local underway = sail(stateFacing(heading), { Sail = 1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 40)

			-- How long from a standstill to half speed...
			local gathering = stateFacing(heading)
			local gatherTicks = 0
			while gathering.Speed < underway.Speed * 0.5 and gatherTicks < 6000 do
				gathering =
					BoatDrive.Step(gathering, { Sail = 1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 1 / 60, 1)
				gatherTicks += 1
			end

			-- ...against how long from full speed back down to half, with the sails furled.
			local losing = underway
			local loseTicks = 0
			while losing.Speed > underway.Speed * 0.5 and loseTicks < 6000 do
				losing = BoatDrive.Step(losing, { Sail = 0, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 1 / 60, 1)
				loseTicks += 1
			end

			expect(loseTicks > gatherTicks).to.equal(true)
		end)

		it("sheds way faster while aground -- a hull that hits shore does not coast", function()
			local heading = BoatConstants.Wind.PeakRadians
			local underway = sail(stateFacing(heading), { Sail = 1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 40)

			local afloat =
				BoatDrive.Step(underway, { Sail = 0, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 1 / 60, 1)
			local aground = BoatDrive.Step(
				underway,
				{ Sail = 0, Steer = 0 },
				tuning(),
				FULL_WIND_ASTERN,
				AGROUND,
				1 / 60,
				BoatConstants.Beaching.DecelerationMultiple
			)
			expect(aground.Speed < afloat.Speed).to.equal(true)
		end)
	end)

	describe("the rudder dies with the way", function()
		it("barely turns a hull lying dead in the water", function()
			local dead = stateFacing(0)
			-- Furled, so she never gathers way -- only the rudder is being asked for.
			local after = sail(dead, { Sail = 0, Steer = 1 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 3)
			local full = BoatConstants.Drive.TurnRate
			expect(after.YawRate < full * BoatConstants.Drive.MinRudderAuthority * 1.05).to.equal(true)
		end)

		it("turns at full rate once she has steerage", function()
			local underway = sail(
				stateFacing(BoatConstants.Wind.PeakRadians),
				{ Sail = 1, Steer = 0 },
				tuning(),
				FULL_WIND_ASTERN,
				AFLOAT,
				40
			)
			local turning =
				BoatDrive.Step(underway, { Sail = 1, Steer = 1 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 1 / 60, 1)
			-- One tick of ramp, so this only has to prove the COMMANDED rate is the full one, which it
			-- reaches by climbing toward it rather than sitting at the floor.
			expect(turning.YawRate > 0).to.equal(true)
			local settled = sail(underway, { Sail = 1, Steer = 1 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 3)
			expect(settled.YawRate).to.be.near(BoatConstants.Drive.TurnRate, 0.02)
		end)

		it("steers the same making sternway as making the same speed ahead", function()
			-- Deliberate, and not the naive reading -- see rudderAuthority's own comment on why a
			-- reversing rudder was tried and taken out.
			local ahead = stateFacing(0)
			ahead.Speed = 20
			local astern = stateFacing(0)
			astern.Speed = -20
			local turnedAhead =
				BoatDrive.Step(ahead, { Sail = 0, Steer = 1 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 1 / 60, 1)
			local turnedAstern =
				BoatDrive.Step(astern, { Sail = 0, Steer = 1 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 1 / 60, 1)
			expect(turnedAhead.YawRate).to.be.near(turnedAstern.YawRate, 1e-9)
		end)
	end)

	describe("aground", function()
		it("refuses forward drive outright", function()
			local reaching = stateFacing(BoatConstants.Wind.PeakRadians)
			local after = sail(reaching, { Sail = 1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AGROUND, 6)
			expect(after.Speed).to.equal(0)
		end)

		it("still makes sternway, which is the whole recovery path", function()
			local after = sail(stateFacing(0), { Sail = -1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AGROUND, 6)
			expect(after.Speed < 0).to.equal(true)
		end)

		it("backs out of irons too, because sternway ignores the wind", function()
			-- Head to wind is the other dead end. Sails backed must work there or a player can be stuck
			-- with no input that helps.
			local inIrons = stateFacing(0)
			local after = sail(inIrons, { Sail = -1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 6)
			expect(after.Speed < 0).to.equal(true)
		end)

		it("holds her last height rather than falling through the map", function()
			local raised = stateFacing(0)
			raised.Target = CFrame.new(0, 137, 0) * raised.Target.Rotation
			local after = sail(raised, { Sail = 0, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AGROUND, 4)
			expect(after.Target.Position.Y).to.be.near(137, 1e-6)
		end)
	end)

	describe("the vertical is the water's", function()
		it("rises to the waterline plus this hull's own offset", function()
			local sunk = stateFacing(0)
			sunk.Target = CFrame.new(0, -40, 0) * sunk.Target.Rotation
			local after = sail(
				sunk,
				{ Sail = 0, Steer = 0 },
				tuning(),
				FULL_WIND_ASTERN,
				{ SurfaceY = 12, Supported = true },
				8
			)
			expect(after.Target.Position.Y).to.be.near(12 + BoatConstants.Drive.WaterlineOffset, 0.05)
		end)

		it("does not overshoot and oscillate on the way there", function()
			-- The ramped heave carries momentum; without the overshoot guard she sails past the surface
			-- and comes back, beating against the swell that is already bobbing her.
			local sunk = stateFacing(0)
			sunk.Target = CFrame.new(0, -40, 0) * sunk.Target.Rotation
			local target = 12 + BoatConstants.Drive.WaterlineOffset
			local state = sunk
			local overshoot = 0
			for _ = 1, 600 do
				state = BoatDrive.Step(
					state,
					{ Sail = 0, Steer = 0 },
					tuning(),
					FULL_WIND_ASTERN,
					{ SurfaceY = 12, Supported = true },
					1 / 60,
					1
				)
				overshoot = math.max(overshoot, state.Target.Position.Y - target)
			end
			expect(overshoot).to.be.near(0, 1e-6)
		end)
	end)

	describe("leeway", function()
		it("slides her downwind of where she is pointing", function()
			local beam = stateFacing(math.pi / 2)
			local withLeeway = sail(beam, { Sail = 1, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 20)
			local without =
				sail(beam, { Sail = 1, Steer = 0 }, tuning({ LeewayFraction = 0 }), FULL_WIND_ASTERN, AFLOAT, 20)
			-- The wind blows FROM bearing 0 (world -Z), so it pushes toward world +Z.
			expect(withLeeway.Target.Position.Z > without.Target.Position.Z).to.equal(true)
		end)

		it("does not slide her at a standstill", function()
			local dead = sail(stateFacing(0), { Sail = 0, Steer = 0 }, tuning(), FULL_WIND_ASTERN, AFLOAT, 5)
			expect(dead.Target.Position.X).to.be.near(0, 1e-9)
			expect(dead.Target.Position.Z).to.be.near(0, 1e-9)
		end)
	end)

	describe("the bow correction", function()
		it("sails a hull whose root is turned 180 degrees the way her bow points", function()
			-- The escape hatch for "my boat sails stern-first". Root facing world +Z, bow correction pi,
			-- so her BOW is world -Z and she should behave exactly like the un-corrected hull above.
			local reversed = stateFacing(math.pi)
			local corrected = tuning({ ForwardYawRadians = math.pi })
			expect(BoatDrive.BowBearing(reversed, corrected)).to.be.near(0, 1e-5)

			-- Bow at bearing 0 into a wind from bearing 0 is in irons, so she makes no way -- which is the
			-- proof that the correction reached the travel direction and not just the report.
			local after = sail(reversed, { Sail = 1, Steer = 0 }, corrected, FULL_WIND_ASTERN, AFLOAT, 6)
			expect(after.Speed).to.equal(0)
		end)
	end)

	describe("ClampLead", function()
		it("leaves a target that is already close enough exactly alone", function()
			local target = CFrame.new(10, 0, 0)
			expect(BoatDrive.ClampLead(target, Vector3.new(9, 0, 0), 60)).to.equal(target)
		end)

		it("pulls a runaway target back onto the same line without rotating it", function()
			local target = CFrame.new(500, 0, 0) * CFrame.Angles(0, 1.2, 0)
			local clamped = BoatDrive.ClampLead(target, Vector3.zero, 60)
			expect(clamped.Position.Magnitude).to.be.near(60, 1e-4)
			expect(clamped.LookVector:Dot(target.LookVector)).to.be.near(1, 1e-6)
		end)
	end)

	describe("PresentationCFrame", function()
		local function rollOf(cframe: CFrame): number
			local _, _, roll = cframe:ToEulerAnglesXYZ()
			return roll
		end

		it("leaves an upright hull upright with no wind, no turn and flat water", function()
			local calm: BoatTypes.WindSample = { BearingRadians = 0, Strength = 1 }
			local pose = BoatDrive.PresentationCFrame(stateFacing(0), tuning(), 0, calm, 0, 0, 0)
			expect(rollOf(pose)).to.be.near(0, 1e-6)
		end)

		it("heels her AWAY from a wind on the port bow", function()
			-- Wind from bearing +1 rad with the bow at 0 puts it on the port bow, which pushes her over
			-- to starboard -- and a negative roll about the local Z drops the starboard side.
			local beam: BoatTypes.WindSample = { BearingRadians = 1.2, Strength = 1 }
			local pose = BoatDrive.PresentationCFrame(stateFacing(0), tuning(), 1, beam, 0, 0, 0)
			expect(BoatWind.LateralFactor(BoatWind.RelativeAngle(0, 1.2)) > 0).to.equal(true)
			expect(rollOf(pose) < 0).to.equal(true)
		end)

		it("heels her the other way for a wind on the starboard bow", function()
			local beam: BoatTypes.WindSample = { BearingRadians = -1.2, Strength = 1 }
			local pose = BoatDrive.PresentationCFrame(stateFacing(0), tuning(), 1, beam, 0, 0, 0)
			expect(rollOf(pose) > 0).to.equal(true)
		end)

		it("does not heel her with the sails furled, however hard it blows", function()
			local beam: BoatTypes.WindSample = { BearingRadians = 1.2, Strength = 1 }
			local pose = BoatDrive.PresentationCFrame(stateFacing(0), tuning(), 0, beam, 0, 0, 0)
			expect(rollOf(pose)).to.be.near(0, 1e-6)
		end)

		it("drops the starboard side in a starboard turn", function()
			local turning = stateFacing(0)
			turning.YawRate = BoatConstants.Drive.TurnRate
			local calm: BoatTypes.WindSample = { BearingRadians = 0, Strength = 1 }
			local pose = BoatDrive.PresentationCFrame(turning, tuning(), 0, calm, 0, 0, 0)
			expect(rollOf(pose) < 0).to.equal(true)
		end)

		it("never exceeds the authored heel ceiling, even with the turn and the wind agreeing", function()
			local turning = stateFacing(0)
			turning.YawRate = BoatConstants.Drive.TurnRate * 4
			local beam: BoatTypes.WindSample = { BearingRadians = math.pi / 2, Strength = 1 }
			local pose = BoatDrive.PresentationCFrame(turning, tuning(), 1, beam, 0, 0, 0)
			-- The wave tilt is a separate, separately-clamped channel, so the ceiling checked here is the
			-- heel's own plus the swell's.
			local ceiling = BoatConstants.Drive.MaxHeelRadians + BoatConstants.Swell.MaxTiltRadians
			expect(math.abs(rollOf(pose)) <= ceiling + 1e-6).to.equal(true)
		end)
	end)
end
