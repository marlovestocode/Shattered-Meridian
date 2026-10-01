--!strict
-- Covers Shared/HitboxEngine/ProjectileMotion.lua and ProjectileTypes.lua -- the pure half of projectile
-- moves: how a volley spreads, how one step of flight moves a shot, and the schema's gate. No Instances.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProjectileMotion = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileMotion)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)

local EPSILON = 1e-3

local function spec(overrides: { [string]: any }?): ProjectileTypes.ProjectileSpec
	local result = ProjectileTypes.Defaults() :: any
	for key, value in pairs(overrides or {}) do
		result[key] = value
	end
	return result
end

-- Degrees right of straight ahead (-Z) for a direction, the convention FanAngle uses.
local function yawOf(direction: Vector3): number
	return math.deg(math.atan2(direction.X, -direction.Z))
end

local function near(a: number, b: number): boolean
	return math.abs(a - b) <= EPSILON
end

return function()
	describe("ProjectileMotion.FanAngle", function()
		it("spreads five shots evenly across a 30 degree arc, ends included", function()
			local expected = { -15, -7.5, 0, 7.5, 15 }
			for index, angle in expected do
				expect(near(ProjectileMotion.FanAngle(index, 5, 30), angle)).to.equal(true)
			end
		end)

		it("puts a lone shot dead ahead whatever the angle", function()
			expect(ProjectileMotion.FanAngle(1, 1, 90)).to.equal(0)
		end)

		it("never doubles a shot on a full 360 ring", function()
			local seen: { number } = {}
			for index = 1, 4 do
				table.insert(seen, ProjectileMotion.FanAngle(index, 4, 360))
			end
			expect(near(seen[1], -180)).to.equal(true)
			expect(near(seen[2], -90)).to.equal(true)
			expect(near(seen[3], 0)).to.equal(true)
			expect(near(seen[4], 90)).to.equal(true)
		end)
	end)

	describe("ProjectileMotion.Volley", function()
		local aim = CFrame.new(0, 5, 0)

		it("fires ONE shot for Single, whatever Count says", function()
			local shots = ProjectileMotion.Volley(spec({ SpreadPattern = "Single", Count = 5 }), aim)
			expect(#shots).to.equal(1)
			expect(near(shots[1].Direction.Z, -1)).to.equal(true)
		end)

		it("fans Count shots at FanAngle's headings, in order", function()
			local shots = ProjectileMotion.Volley(spec({ SpreadPattern = "Fan", Count = 5, SpreadAngle = 30 }), aim)
			expect(#shots).to.equal(5)
			for index, shot in shots do
				expect(near(yawOf(shot.Direction), ProjectileMotion.FanAngle(index, 5, 30))).to.equal(true)
				expect(near(shot.Direction.Y, 0)).to.equal(true)
				expect(shot.Origin).to.equal(aim.Position)
			end
		end)

		it("lays a Horizontal row side by side, Spacing apart and all parallel", function()
			local shots = ProjectileMotion.Volley(spec({ SpreadPattern = "Horizontal", Count = 3, Spacing = 2 }), aim)
			expect(#shots).to.equal(3)
			expect(near(shots[1].Origin.X, -2)).to.equal(true)
			expect(near(shots[2].Origin.X, 0)).to.equal(true)
			expect(near(shots[3].Origin.X, 2)).to.equal(true)
			for _, shot in shots do
				expect(near(shot.Direction.Z, -1)).to.equal(true)
			end
		end)

		it("stacks a Vertical column top to bottom", function()
			local shots = ProjectileMotion.Volley(spec({ SpreadPattern = "Vertical", Count = 3, Spacing = 1.5 }), aim)
			expect(near(shots[1].Origin.Y, 6.5)).to.equal(true)
			expect(near(shots[2].Origin.Y, 5)).to.equal(true)
			expect(near(shots[3].Origin.Y, 3.5)).to.equal(true)
		end)

		it("rings a Radial volley evenly around the aim, half the angle off it", function()
			local shots = ProjectileMotion.Volley(spec({ SpreadPattern = "Radial", Count = 4, SpreadAngle = 60 }), aim)
			local sum = Vector3.zero
			for _, shot in shots do
				local offAxis = math.deg(ProjectileMotion.AngleBetween(shot.Direction, Vector3.new(0, 0, -1)))
				expect(near(offAxis, 30)).to.equal(true)
				sum += shot.Direction
			end
			-- Evenly around the axis: the sideways parts cancel.
			expect(near(sum.X, 0)).to.equal(true)
			expect(near(sum.Y, 0)).to.equal(true)
		end)

		it("turns the whole pattern with the aim's roll", function()
			local rolled = aim * CFrame.Angles(0, 0, math.rad(90))
			local shots = ProjectileMotion.Volley(spec({ SpreadPattern = "Fan", Count = 3, SpreadAngle = 40 }), rolled)
			-- A fan rolled a quarter turn spreads up and down, not left and right.
			expect(near(shots[1].Direction.X, 0)).to.equal(true)
			expect(math.abs(shots[1].Direction.Y) > 0.3).to.equal(true)
		end)
	end)

	describe("ProjectileMotion.Integrate", function()
		local motion: ProjectileMotion.Motion = { Gravity = 0, Acceleration = 0, HomingStrength = 0, MaxSpeed = 400 }

		it("flies straight at constant speed with no forces", function()
			local position, velocity =
				ProjectileMotion.Integrate(Vector3.zero, Vector3.new(0, 0, -10), motion, 0.5, nil)
			expect(near(position.Z, -5)).to.equal(true)
			expect(near(velocity.Magnitude, 10)).to.equal(true)
		end)

		it("pulls down by Gravity", function()
			local falling = table.clone(motion)
			falling.Gravity = 20
			local _, velocity = ProjectileMotion.Integrate(Vector3.zero, Vector3.new(0, 0, -10), falling, 0.5, nil)
			expect(near(velocity.Y, -10)).to.equal(true)
		end)

		it("stops a decelerating shot rather than reversing it", function()
			local braking = table.clone(motion)
			braking.Acceleration = -100
			local _, velocity = ProjectileMotion.Integrate(Vector3.zero, Vector3.new(0, 0, -10), braking, 1, nil)
			expect(velocity.Magnitude).to.equal(0)
		end)

		it("turns a homing shot toward its point by at most its strength", function()
			local homing = table.clone(motion)
			homing.HomingStrength = 90
			local _, velocity =
				ProjectileMotion.Integrate(Vector3.zero, Vector3.new(0, 0, -10), homing, 0.5, Vector3.new(100, 0, 0))
			-- 90 degrees/s for half a second: 45 degrees of the 90 it wanted.
			local turned = math.deg(ProjectileMotion.AngleBetween(velocity.Unit, Vector3.new(0, 0, -1)))
			expect(near(turned, 45)).to.equal(true)
		end)

		it("ignores a homing point when the motion does not home", function()
			local _, velocity =
				ProjectileMotion.Integrate(Vector3.zero, Vector3.new(0, 0, -10), motion, 0.5, Vector3.new(100, 0, 0))
			expect(near(velocity.X, 0)).to.equal(true)
		end)
	end)

	describe("ProjectileMotion.Reflect", function()
		it("sends a shot back off a surface it hits head-on", function()
			local reflected = ProjectileMotion.Reflect(Vector3.new(0, 0, -5), Vector3.new(0, 0, 1))
			expect(near(reflected.Z, 5)).to.equal(true)
		end)
	end)

	describe("ProjectileTypes.Validate", function()
		it("fills every absent field with its default", function()
			local validated = ProjectileTypes.Validate({})
			expect(validated).to.be.ok()
			for _, field in ProjectileTypes.Fields do
				expect((validated :: any)[field.Name]).to.equal(field.Default)
			end
		end)

		it("rejects an option that does not exist", function()
			local validated, reason = ProjectileTypes.Validate({ SpreadPattern = "Spiral" })
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidProjectile")
		end)

		it("rejects a value of the wrong type", function()
			expect((ProjectileTypes.Validate({ Count = "3" }))).to.equal(nil)
			expect((ProjectileTypes.Validate({ Piercing = 1 }))).to.equal(nil)
			expect((ProjectileTypes.Validate({ Speed = 0 / 0 }))).to.equal(nil)
			expect((ProjectileTypes.Validate("nope"))).to.equal(nil)
		end)

		it("clamps numbers into their limits and rounds whole-number fields", function()
			local validated = ProjectileTypes.Validate({ Speed = 100000, Count = 3.6, Size = -1 }) :: any
			expect(validated.Speed).to.equal(ProjectileTypes.Limits.Speed.Max)
			expect(validated.Count).to.equal(4)
			expect(validated.Size).to.equal(ProjectileTypes.Limits.Size.Min)
		end)
	end)

	describe("ProjectileTypes.Copy", function()
		it("carries exactly the schema's fields", function()
			local source = ProjectileTypes.Defaults() :: any
			source.Junk = true
			local copy = ProjectileTypes.Copy(source) :: any
			expect(copy.Junk).to.equal(nil)
			for _, field in ProjectileTypes.Fields do
				expect(copy[field.Name]).to.equal(source[field.Name])
			end
			expect(copy).never.to.equal(source)
		end)
	end)
end
