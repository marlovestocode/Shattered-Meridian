--!strict
-- Covers Screens/DeathFeed's kill feed now that it has a producer: rows render, newest first, the
-- tile leaves its region stack when empty, and the cap drops the oldest. Row expiry
-- (DeathConstants.KillFeed.RowSeconds) is a single task.delay and is not waited out here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local DeathConstants = require(ReplicatedStorage.Shared.Death.DeathConstants)
local DeathFeed = require(StarterPlayer.StarterPlayerScripts.Client.UI.Screens.DeathFeed)

local function rowsIn(tile: Instance): { Frame }
	local rows: { Frame } = {}
	for _, child in tile:GetChildren() do
		if child:IsA("Frame") and child.Name == "KillFeedRow" then
			table.insert(rows, child)
		end
	end
	return rows
end

local function textOf(row: Frame): string
	local label = row:FindFirstChildWhichIsA("TextLabel", true)
	return if label then label.Text else ""
end

return function()
	local scope: any
	local handle: any
	local tile: Frame

	beforeEach(function()
		scope = Fusion.scoped(Fusion)
		handle, tile = DeathFeed.Mount(scope, Instance.new("Folder") :: any, 1)
	end)

	afterEach(function()
		scope:doCleanup()
	end)

	it("stays out of its region's stack while it has nothing to show", function()
		expect(tile.Visible).to.equal(false)
		expect(#rowsIn(tile)).to.equal(0)
	end)

	it("renders a pushed kill, in words, from the local player's side", function()
		handle.PushKill("Killer", "Victim", "None")
		handle.PushKill("Killer", "Victim", "Killer")
		handle.PushKill("Killer", "Victim", "Victim")
		task.wait()

		expect(tile.Visible).to.equal(true)
		local texts: { [string]: boolean } = {}
		for _, row in rowsIn(tile) do
			texts[textOf(row)] = true
		end
		expect(texts["Killer slew Victim"]).to.equal(true)
		expect(texts["You slew Victim"]).to.equal(true)
		expect(texts["Killer slew you"]).to.equal(true)
	end)

	it("orders the newest row first", function()
		handle.PushKill("First", "A", "None")
		handle.PushKill("Second", "B", "None")
		task.wait()
		local rows = rowsIn(tile)
		table.sort(rows, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		expect(textOf(rows[1])).to.equal("Second slew B")
	end)

	it("drops the oldest row past the cap", function()
		for index = 1, DeathConstants.KillFeed.MaxRows + 2 do
			handle.PushKill(`K{index}`, "V", "None")
		end
		task.wait()
		local rows = rowsIn(tile)
		expect(#rows).to.equal(DeathConstants.KillFeed.MaxRows)
		for _, row in rows do
			expect(textOf(row) ~= "K1 slew V").to.equal(true)
			expect(textOf(row) ~= "K2 slew V").to.equal(true)
		end
	end)
end
