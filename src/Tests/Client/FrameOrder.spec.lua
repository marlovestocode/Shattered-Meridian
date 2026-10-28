--!strict
local StarterPlayer = game:GetService("StarterPlayer")

local FrameOrder = require(StarterPlayer.StarterPlayerScripts.Client.Config.FrameOrder)

local function key(names: { string }): string
	return table.concat(names, ",")
end

return function()
	describe("FrameOrder", function()
		it("has no render-step clash beyond the ones written down when the table was made", function()
			local known: { [string]: boolean } = {}
			for _, names in FrameOrder.KnownClashes() do
				known[key(names)] = true
			end
			for _, names in FrameOrder.Clashes() do
				expect(known[key(names)] and key(names) or `NEW CLASH: {key(names)}`).to.equal(key(names))
			end
		end)

		it("lists no known clash that has since been fixed (delete its row when it is)", function()
			local live: { [string]: boolean } = {}
			for _, names in FrameOrder.Clashes() do
				live[key(names)] = true
			end
			for _, names in FrameOrder.KnownClashes() do
				expect(live[key(names)] and key(names) or `STALE ROW: {key(names)}`).to.equal(key(names))
			end
		end)

		it("refuses a slot it does not know", function()
			expect(function()
				FrameOrder.Priority("NoSuchSlot")
			end).to.throw()
		end)
	end)
end
