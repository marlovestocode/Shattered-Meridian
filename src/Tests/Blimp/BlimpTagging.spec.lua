--!strict
-- Covers Shared/Blimp/BlimpTagging.lua's two geometric resolvers -- where a mounted body stands, and the
-- bow that follows from it.
--
-- These DO need Instances (a raycast against a real deck is the whole mechanism), so each case builds a
-- throwaway hull in Workspace and tears it down after. Everything is anchored and CanCollide false: the
-- deck probe passes RespectCanCollide = false, so collision is not part of what is being tested, and an
-- unanchored test hull would fall for the length of the run.
--
-- The case that matters most is "flat deck, wheel turned round" -- the shipped bug. Both probes hit the
-- same deck at the same height, so the old nearest-hit ranking tied, fell through to whichever candidate
-- was tested first, and resolved to the wheel mesh's +Z face. Because ResolveForwardYaw reads the bow off
-- the pilot's facing, that put the pilot on the wrong side of the wheel and flew the hull astern on W.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpTagging = require(ReplicatedStorage.Shared.Blimp.BlimpTagging)

-- World -Z is the bow throughout, so "outboard at the helm" reads as -Z and every expectation below can
-- be checked against one axis by eye.
local BOW = Vector3.new(0, 0, -1)

local function newPart(name: string, size: Vector3, cframe: CFrame, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Anchored = true
	part.CanCollide = false
	part.CFrame = cframe
	part.Parent = parent
	return part
end

return function()
	local hulls: { Model } = {}

	-- A hull with its deck centred on the origin, running `deckLength` studs fore and aft, and one station
	-- part at `stationCFrame`. The station is NOT tagged: every function under test takes the part
	-- directly, so tagging it would only exercise CollectionService.
	local function hull(stationCFrame: CFrame, deckLength: number): (Model, BasePart)
		local model = Instance.new("Model")
		model.Name = "TestBlimp"

		newPart("Deck", Vector3.new(12, 1, deckLength), CFrame.new(0, 0, 0), model)
		local station = newPart("Wheel", Vector3.new(3, 3, 0.5), stationCFrame, model)

		model.Parent = Workspace
		table.insert(hulls, model)
		return model, station
	end

	-- An empty, untagged Model in Workspace, torn down by the same afterEach as `hull` -- the fuel
	-- resolvers below don't need a deck/wheel pairing, only a Model to hang tags/Attributes off of.
	local function bareModel(): Model
		local model = Instance.new("Model")
		model.Name = "TestBlimp"
		model.Parent = Workspace
		table.insert(hulls, model)
		return model
	end

	afterEach(function()
		for _, model in hulls do
			model:Destroy()
		end
		table.clear(hulls)
	end)

	describe("ResolveStandOffset", function()
		it("stands the pilot on the hull side of a wheel whose own axis points outboard", function()
			-- The regression. The wheel is forward of the hull's centre and turned a half circle, so its
			-- +Z face -- the side the old nearest-hit tie resolved to -- is the side out over the bow.
			local model, station = hull(CFrame.new(0, 3, -20) * CFrame.Angles(0, math.pi, 0), 60)

			local stand = station.CFrame * BlimpTagging.ResolveStandOffset(station, model)

			-- Behind the wheel, i.e. nearer the middle of the ship than the wheel is.
			expect(stand.Position.Z > station.Position.Z).to.equal(true)
			-- ...and looking out over it, along the bow.
			expect(stand.LookVector:Dot(BOW)).to.be.near(1, 1e-3)
		end)

		it("stands the pilot on the hull side of a wheel whose own axis points inboard", function()
			-- The same hull with the wheel modelled the other way round. The answer must not change:
			-- which face of the mesh is +Z is exactly the artefact this resolver exists to ignore.
			local model, station = hull(CFrame.new(0, 3, -20), 60)

			local stand = station.CFrame * BlimpTagging.ResolveStandOffset(station, model)

			expect(stand.Position.Z > station.Position.Z).to.equal(true)
			expect(stand.LookVector:Dot(BOW)).to.be.near(1, 1e-3)
		end)

		it("takes the side that has deck under it even when the outboard test disagrees", function()
			-- Rule 1 beats rule 2, and this is the build that separates them: a wheel out on a forecastle
			-- with a gap between it and the main deck, so the only side anyone can stand on is the side
			-- FURTHER out. A pilot placed by the outboard test alone would be standing on air.
			local model = Instance.new("Model")
			model.Name = "TestBlimp"
			newPart("MainDeck", Vector3.new(12, 1, 30), CFrame.new(0, 0, 10), model)
			newPart("Forecastle", Vector3.new(12, 1, 6), CFrame.new(0, 0, -22), model)
			local station = newPart("Wheel", Vector3.new(3, 3, 0.5), CFrame.new(0, 3, -17), model)
			model.Parent = Workspace
			table.insert(hulls, model)

			local stand = station.CFrame * BlimpTagging.ResolveStandOffset(station, model)

			expect(stand.Position.Z < station.Position.Z).to.equal(true)
		end)

		it("stands a passenger inboard of a rail, looking out over it", function()
			-- The same rule read on the other kind of station, and the reason it is phrased as "outboard"
			-- rather than "toward the bow": a handhold on the port rail is not fore or aft of anything.
			local model, station = hull(CFrame.new(-5, 3, 0) * CFrame.Angles(0, math.pi / 2, 0), 60)

			local stand = station.CFrame * BlimpTagging.ResolveStandOffset(station, model)

			expect(stand.Position.X > station.Position.X).to.equal(true)
			expect(stand.LookVector:Dot(Vector3.new(-1, 0, 0))).to.be.near(1, 1e-3)
		end)

		it("faces the station whichever side it picks", function()
			-- The invariant under all of the above: a body with its back to the wheel is never an answer.
			local placements = {
				CFrame.new(0, 3, -20),
				CFrame.new(0, 3, -20) * CFrame.Angles(0, math.pi, 0),
				CFrame.new(0, 3, 20) * CFrame.Angles(0, math.pi / 3, 0),
				CFrame.new(4, 3, 0) * CFrame.Angles(0, -math.pi / 2, 0),
			}
			for _, placement in placements do
				local model, station = hull(placement, 60)
				local stand = station.CFrame * BlimpTagging.ResolveStandOffset(station, model)
				local toStation = (station.Position - stand.Position).Unit
				expect(stand.LookVector:Dot(toStation)).to.be.near(1, 1e-3)
			end
		end)

		it("lets an authored Stand Attachment overrule the whole search", function()
			local model, station = hull(CFrame.new(0, 3, -20), 60)
			local authored = Instance.new("Attachment")
			authored.Name = BlimpConstants.Attachments.Stand
			-- Deliberately absurd -- nothing the resolver could ever produce on its own.
			authored.CFrame = CFrame.new(0, 9, 7) * CFrame.Angles(0, math.pi / 4, 0)
			authored.Parent = station

			local offset = BlimpTagging.ResolveStandOffset(station, model)

			expect((offset.Position - authored.CFrame.Position).Magnitude).to.be.near(0, 1e-4)
		end)
	end)

	describe("ResolveForwardYaw", function()
		it("puts the bow where the pilot ends up looking, whatever the root part faces", function()
			-- The pairing that makes the two symptoms one bug: the yaw is what BlimpDrive rotates the
			-- hull's own facing by to get the direction of travel, so it has to land on the pilot's look.
			local model, station = hull(CFrame.new(0, 3, -20) * CFrame.Angles(0, math.pi, 0), 60)
			local root = newPart("Hull", Vector3.new(8, 4, 40), CFrame.new(0, 6, 0) * CFrame.Angles(0, 1.1, 0), model)

			local offset = BlimpTagging.ResolveStandOffset(station, model)
			local yaw = BlimpTagging.ResolveForwardYaw(model, root, station, offset)

			local travel = (root.CFrame * CFrame.Angles(0, yaw, 0)).LookVector
			expect(travel:Dot(BOW)).to.be.near(1, 1e-3)
		end)

		it("honours an explicit BlimpForwardYaw over the pilot's facing", function()
			local model, station = hull(CFrame.new(0, 3, -20), 60)
			local root = newPart("Hull", Vector3.new(8, 4, 40), CFrame.new(0, 6, 0), model)
			model:SetAttribute(BlimpConstants.ModelAttributes.ForwardYaw, 180)

			local offset = BlimpTagging.ResolveStandOffset(station, model)

			expect(BlimpTagging.ResolveForwardYaw(model, root, station, offset)).to.be.near(math.pi, 1e-6)
		end)

		it("has no bow to argue about without a helm", function()
			local model = Instance.new("Model")
			model.Parent = Workspace
			table.insert(hulls, model)
			local root = newPart("Hull", Vector3.new(8, 4, 40), CFrame.new(0, 6, 0), model)

			expect(BlimpTagging.ResolveForwardYaw(model, root, nil, nil)).to.equal(0)
		end)
	end)

	describe("ResolveFuelStation", function()
		it("finds nothing on a model with no furnace tag at all", function()
			local model = bareModel()
			newPart("Deck", Vector3.new(12, 1, 20), CFrame.new(0, 0, 0), model)

			expect(BlimpTagging.ResolveFuelStation(model)).to.equal(nil)
		end)

		it("finds the one station a builder tagged -- both coal and water are loaded there", function()
			local model = bareModel()
			local furnacePart = newPart("Furnace", Vector3.new(2, 2, 2), CFrame.new(3, 0, 0), model)
			CollectionService:AddTag(furnacePart, BlimpConstants.Tags.Furnace)

			expect(BlimpTagging.ResolveFuelStation(model)).to.equal(furnacePart)
		end)

		it("keeps the first furnace and ignores a second one on the same hull", function()
			local model = bareModel()
			local first = newPart("Furnace1", Vector3.new(2, 2, 2), CFrame.new(3, 0, 0), model)
			CollectionService:AddTag(first, BlimpConstants.Tags.Furnace)
			local second = newPart("Furnace2", Vector3.new(2, 2, 2), CFrame.new(6, 0, 0), model)
			CollectionService:AddTag(second, BlimpConstants.Tags.Furnace)

			expect(BlimpTagging.ResolveFuelStation(model)).to.equal(first)
		end)
	end)

	describe("ResolveFuelTuning", function()
		it("falls through entirely to BlimpConstants.Fuel with no Attributes set", function()
			local model = bareModel()
			local tuningResult = BlimpTagging.ResolveFuelTuning(model)
			expect(tuningResult.CoalCapacity).to.equal(BlimpConstants.Fuel.CoalCapacity)
			expect(tuningResult.WaterCapacity).to.equal(BlimpConstants.Fuel.WaterCapacity)
			expect(tuningResult.CoalMinimum).to.equal(BlimpConstants.Fuel.CoalMinimum)
			expect(tuningResult.WaterMinimum).to.equal(BlimpConstants.Fuel.WaterMinimum)
			expect(tuningResult.CoalBurnPerSecond).to.equal(BlimpConstants.Fuel.CoalBurnPerSecond)
			expect(tuningResult.WaterBurnPerSecond).to.equal(BlimpConstants.Fuel.WaterBurnPerSecond)
		end)

		it("honours a per-model Attribute override", function()
			local model = bareModel()
			model:SetAttribute(BlimpConstants.ModelAttributes.CoalCapacity, 999)
			local tuningResult = BlimpTagging.ResolveFuelTuning(model)
			expect(tuningResult.CoalCapacity).to.equal(999)
			-- Untouched siblings still fall through to the defaults -- one override must not reset the rest.
			expect(tuningResult.WaterCapacity).to.equal(BlimpConstants.Fuel.WaterCapacity)
		end)

		it("falls back to the shipped defaults entirely when a Minimum override exceeds its own Capacity", function()
			-- An unflyable pairing (the hull could never hold enough to clear its own cutoff) rather than
			-- an override typo silently grounding a blimp forever with nothing in any log to explain why.
			local model = bareModel()
			model:SetAttribute(BlimpConstants.ModelAttributes.CoalCapacity, 10)
			model:SetAttribute(BlimpConstants.ModelAttributes.CoalMinimum, 50)
			local tuningResult = BlimpTagging.ResolveFuelTuning(model)
			expect(tuningResult.CoalCapacity).to.equal(BlimpConstants.Fuel.CoalCapacity)
			expect(tuningResult.CoalMinimum).to.equal(BlimpConstants.Fuel.CoalMinimum)
		end)
	end)
end
