--!strict
-- Covers Client/Parkour/States/StateSupport.lua's pure, Vector3-in/boolean-out helpers -- the parts
-- of a module that otherwise only exists to be handed a live ParkourContext.
--
-- StateSupport.IsMovingToward is the one function here worth its own file: it is the shared gate
-- Mantling.CanEnter and Vaulting.CanEnter both call to refuse a traversal whose LIVE travel direction
-- has diverged from the obstacle's face since the obstacle was probed -- the fix for "can mantle/vault
-- backward." A bug in the angle convention or the sign of the normal negation would silently let every
-- caller through (or refuse every caller), so it is asserted directly against the same geometry
-- ObstacleProbe.Normal actually reports: an OUTWARD face normal, pointing back at whoever is
-- approaching it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local StateSupport = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.States.StateSupport)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)

return function()
	describe("StateSupport.IsMovingToward", function()
		it("allows a dead-on approach", function()
			-- Wall facing the character (-Z travel into a wall whose outward normal is +Z).
			expect(StateSupport.IsMovingToward(Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), 65)).to.equal(true)
		end)

		it("allows a diagonal approach inside the threshold", function()
			local travel = Vector3.new(-1, 0, -1).Unit
			expect(StateSupport.IsMovingToward(travel, Vector3.new(0, 0, 1), 65)).to.equal(true)
		end)

		it("refuses a dead-sideways approach", function()
			-- Running along the face (perpendicular to the inward direction) is 90 degrees off -- past
			-- any threshold that still means "walking into it."
			expect(StateSupport.IsMovingToward(Vector3.new(1, 0, 0), Vector3.new(0, 0, 1), 65)).to.equal(false)
		end)

		it("refuses moving directly AWAY from the face -- the backward-vault case", function()
			-- Travel is +Z (away from the wall) while the wall's outward normal is also +Z, i.e. the
			-- character is retreating from the exact face it supposedly found. This is the geometry a
			-- reversed input produces and is exactly what this gate exists to catch.
			expect(StateSupport.IsMovingToward(Vector3.new(0, 0, 1), Vector3.new(0, 0, 1), 65)).to.equal(false)
		end)

		it("treats the threshold angle itself as passing", function()
			-- 65 degrees off dead-on, still inside a 65-degree max.
			local radians = math.rad(65)
			local travel = Vector3.new(math.sin(radians), 0, -math.cos(radians))
			expect(StateSupport.IsMovingToward(travel, Vector3.new(0, 0, 1), 65)).to.equal(true)
		end)

		it("refuses a degenerate (zero) outward normal rather than passing by default", function()
			expect(StateSupport.IsMovingToward(Vector3.new(0, 0, -1), Vector3.zero, 65)).to.equal(false)
		end)

		it("ignores the vertical component of both vectors -- this is a planar question", function()
			-- A steep obstacle face and a travel direction with vertical drift should classify identically
			-- to their flattened counterparts; an accidental Y contribution would make the same horizontal
			-- approach pass or fail depending on how much the character is falling.
			local travel = Vector3.new(0, -5, -1)
			expect(StateSupport.IsMovingToward(travel, Vector3.new(0, 0.6, 1), 65)).to.equal(true)
		end)
	end)

	describe("StateSupport wall lockout identity", function()
		-- A context with only the fields the wall lockout touches; the real one is built by ParkourController.
		local function newContext(): any
			return {
				Now = 10,
				LastWallInstance = nil,
				LastWallPosition = nil,
				LastWallNormal = nil,
				LastWallLeftAt = 0,
			}
		end

		local function wallOn(part: any, x: number, normal: Vector3?): any
			return { Instance = part, Position = Vector3.new(x, 5, 0), Normal = normal or Vector3.new(-1, 0, 0) }
		end

		local function newPart(): BasePart
			return Instance.new("Part")
		end

		it("recognises the same part", function()
			local context, part = newContext(), newPart()
			StateSupport.NoteWallLeft(context, wallOn(part, 2.5))
			expect(StateSupport.IsLastWall(context, wallOn(part, 2.5))).to.equal(true)
			part:Destroy()
		end)

		it("recognises the same PHYSICAL wall when it is reported on a flush neighbouring part", function()
			-- The wall probes follow a wall onto whichever flush part the ray hits, so the part reported can change
			-- with no change to the wall. A lockout keyed on the part alone would release whenever it did.
			local context, first, second = newContext(), newPart(), newPart()
			StateSupport.NoteWallLeft(context, wallOn(first, 2.5))
			expect(StateSupport.IsLastWall(context, wallOn(second, 2.52))).to.equal(true)
			first:Destroy()
			second:Destroy()
		end)

		it("does not mistake a wall facing another way, or standing well off the plane, for the last one", function()
			local context, first, second = newContext(), newPart(), newPart()
			StateSupport.NoteWallLeft(context, wallOn(first, 2.5))
			expect(StateSupport.IsLastWall(context, wallOn(second, 2.5, Vector3.new(0, 0, -1)))).to.equal(false)
			expect(StateSupport.IsLastWall(context, wallOn(second, -2.5, Vector3.new(1, 0, 0)))).to.equal(false)
			expect(StateSupport.IsLastWall(context, wallOn(second, 5))).to.equal(false)
			first:Destroy()
			second:Destroy()
		end)

		it("remembers nothing until a wall is left, and forgets when the record is cleared", function()
			local context, part = newContext(), newPart()
			expect(StateSupport.IsLastWall(context, wallOn(part, 2.5))).to.equal(false)
			StateSupport.NoteWallLeft(context, wallOn(part, 2.5))
			context.LastWallInstance = nil
			expect(StateSupport.IsLastWall(context, wallOn(part, 2.5))).to.equal(false)
			part:Destroy()
		end)

		it("ignores a wall with no part, rather than recording a lockout on nothing", function()
			local context = newContext()
			StateSupport.NoteWallLeft(context, wallOn(nil, 2.5))
			expect(context.LastWallInstance).to.equal(nil)
			expect(context.LastWallLeftAt).to.equal(0)
		end)

		it("falls back to the part alone when the surface test is switched off", function()
			local context, first, second = newContext(), newPart(), newPart()
			local was = ParkourConstants.Surface.Enabled
			ParkourConstants.Surface.Enabled = false
			StateSupport.NoteWallLeft(context, wallOn(first, 2.5))
			local sameFlush = StateSupport.IsLastWall(context, wallOn(second, 2.5))
			local samePart = StateSupport.IsLastWall(context, wallOn(first, 2.5))
			ParkourConstants.Surface.Enabled = was
			expect(sameFlush).to.equal(false)
			expect(samePart).to.equal(true)
			first:Destroy()
			second:Destroy()
		end)
	end)

	describe("ParkourConstants.Obstacle.MaxApproachAngleDegrees", function()
		it("sits strictly between 'requires a square hit' and 'sideways still counts'", function()
			local threshold = ParkourConstants.Obstacle.MaxApproachAngleDegrees
			expect(threshold > 0).to.equal(true)
			expect(threshold < 90).to.equal(true)
		end)
	end)
end
