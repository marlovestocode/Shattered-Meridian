--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AmortizedReclaim = require(ReplicatedStorage.Shared.AmortizedReclaim)

local spawned: { Model } = {}

local function makeModel(name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = workspace
	table.insert(spawned, model)
	return model
end

local function countKeys<K, V>(map: { [K]: V }): number
	local count = 0
	for _ in map do
		count += 1
	end
	return count
end

return function()
	afterEach(function()
		for _, model in spawned do
			model:Destroy()
		end
		table.clear(spawned)
	end)

	describe("AmortizedReclaim -- the bounded step", function()
		it("examines at most ChecksPerStep entries per call", function()
			local map: { [Model]: boolean } = {}
			for index = 1, 20 do
				map[makeModel(`Dead{index}`)] = true
			end
			for model in map do
				model.Parent = nil
			end

			local cursor = AmortizedReclaim.New(4)
			expect(cursor:Step(map)).to.equal(4)
			expect(countKeys(map)).to.equal(16)
		end)

		it("laps the whole table across enough steps, leaving nothing dead behind", function()
			local map: { [Model]: boolean } = {}
			for index = 1, 20 do
				map[makeModel(`Lapped{index}`)] = true
			end
			for model in map do
				model.Parent = nil
			end

			local cursor = AmortizedReclaim.New(4)
			for _ = 1, 5 do
				cursor:Step(map)
			end
			expect(countKeys(map)).to.equal(0)
		end)

		it("leaves live entries alone however many times it is stepped", function()
			local map: { [Model]: number } = {}
			for index = 1, 10 do
				map[makeModel(`Alive{index}`)] = index
			end

			local cursor = AmortizedReclaim.New(4)
			for _ = 1, 50 do
				expect(cursor:Step(map)).to.equal(0)
			end
			expect(countKeys(map)).to.equal(10)
		end)

		it("finds a model that dies long after the cursor has already passed it", function()
			-- The round-robin property: a cursor that only ever ran forward would never come back to
			-- an entry that was alive the one time it was checked.
			local map: { [Model]: boolean } = {}
			local victim = makeModel("LateDeath")
			map[victim] = true
			for index = 1, 9 do
				map[makeModel(`Bystander{index}`)] = true
			end

			local cursor = AmortizedReclaim.New(4)
			for _ = 1, 6 do
				cursor:Step(map)
			end
			expect(countKeys(map)).to.equal(10)

			victim.Parent = nil
			for _ = 1, 6 do
				cursor:Step(map)
			end
			expect(map[victim]).to.equal(nil)
			expect(countKeys(map)).to.equal(9)
		end)
	end)

	describe("AmortizedReclaim -- a cursor pointing at something that moved", function()
		it("survives its resume key being removed by some other path", function()
			-- unbindCharacter and PlayerRemoving both drop entries out from under this cursor. `next`
			-- past a key that is no longer in the table would error, so the guard restarts the lap.
			local map: { [Model]: boolean } = {}
			local models: { Model } = {}
			for index = 1, 10 do
				local model = makeModel(`Yanked{index}`)
				models[index] = model
				map[model] = true
			end

			local cursor = AmortizedReclaim.New(4)
			cursor:Step(map)
			-- Whatever the cursor is resting on, this removes half the table including (very likely)
			-- that key -- the case the guard exists for.
			for index = 1, 10, 2 do
				map[models[index]] = nil
			end

			expect(function()
				for _ = 1, 10 do
					cursor:Step(map)
				end
			end).never.to.throw()
			expect(countKeys(map)).to.equal(5)
		end)

		it("survives entries being added between steps", function()
			local map: { [Model]: boolean } = {}
			local cursor = AmortizedReclaim.New(4)
			expect(function()
				for index = 1, 20 do
					map[makeModel(`Growing{index}`)] = true
					cursor:Step(map)
				end
			end).never.to.throw()
			expect(countKeys(map)).to.equal(20)
		end)

		it("treats an empty table as a no-op", function()
			local cursor = AmortizedReclaim.New(4)
			local map: { [Model]: boolean } = {}
			expect(cursor:Step(map)).to.equal(0)
			expect(cursor:Step(map)).to.equal(0)
		end)

		it("clamps ChecksPerStep to at least one, so a bad tuning value cannot stall the sweep", function()
			local map: { [Model]: boolean } = {}
			local model = makeModel("Clamped")
			map[model] = true
			model.Parent = nil

			local cursor = AmortizedReclaim.New(0)
			expect(cursor:Step(map)).to.equal(1)
		end)

		it("Reset drops the resume point without touching the table", function()
			local map: { [Model]: boolean } = {}
			for index = 1, 8 do
				map[makeModel(`Reset{index}`)] = true
			end

			local cursor = AmortizedReclaim.New(4)
			cursor:Step(map)
			cursor:Reset()
			expect(countKeys(map)).to.equal(8)
			expect(cursor:Step(map)).to.equal(0)
		end)
	end)
end
