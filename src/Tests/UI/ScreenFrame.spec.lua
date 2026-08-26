--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Components = StarterPlayer.StarterPlayerScripts.Client.UI.Components
local ScreenFrame = require(Components.ScreenFrame)

local peek = Fusion.peek

-- Same split as LayoutPrimitives.spec.lua beside it: everything asserted here is STRUCTURE or
-- ARITHMETIC, never rendered geometry, because a headless place resolves no AbsoluteSize.
--
-- The arithmetic half is the interesting one. BodySize exists because four screens each used to sum
-- the band heights by hand, and the failure mode of a stale sum is silent -- a body that clips or
-- leaves a gap, with nothing anywhere reporting it. So the test that matters is not "does BodySize
-- return 540", it is "does BodySize stay consistent with the band heights it is derived from" --
-- which is a property, and holds however those constants are later retuned.

local function newScope(): any
	return Fusion.scoped(Fusion)
end

return function()
	describe("BodySize", function()
		it("gives back exactly what the two bands do not take", function()
			local width, height = ScreenFrame.BodySize(760, 620)
			expect(width).to.equal(760)
			expect(height).to.equal(620 - ScreenFrame.TabStripHeight - ScreenFrame.FooterHeight)
		end)

		it("passes the panel width through untouched -- the bands are horizontal", function()
			local width = ScreenFrame.BodySize(480, 520)
			expect(width).to.equal(480)
		end)

		it("stays in step with the band heights it is derived from", function()
			-- The whole point of the function. If someone retunes a band by editing the constant, this
			-- keeps holding; if someone retunes it by hardcoding a new number into BodySize, it fails.
			local _, height = ScreenFrame.BodySize(900, 640)
			expect(height + ScreenFrame.TabStripHeight + ScreenFrame.FooterHeight).to.equal(640)
		end)
	end)

	describe("NewTabState", function()
		it("selects the first tab on mount", function()
			local tabs = ScreenFrame.NewTabState(newScope(), { "Character", "Arts", "Emotes" })
			expect(peek(tabs.Current)).to.equal("Character")
		end)

		it("builds one Computed per tab, and exactly one of them is true", function()
			local tabs = ScreenFrame.NewTabState(newScope(), { "Character", "Arts", "Emotes" })
			local trueCount = 0
			for _, name in ipairs(tabs.Names) do
				expect(tabs.Selected[name]).to.be.ok()
				if peek(tabs.Selected[name]) then
					trueCount += 1
				end
			end
			expect(trueCount).to.equal(1)
		end)

		it("moves the selection when Current is set", function()
			local tabs = ScreenFrame.NewTabState(newScope(), { "Character", "Arts" })
			tabs.Current:set("Arts")
			expect(peek(tabs.Selected["Arts"])).to.equal(true)
			expect(peek(tabs.Selected["Character"])).to.equal(false)
		end)

		it("hands the SAME Computed to every reader", function()
			-- Load-bearing, and the reason this state is one object rather than a Value plus whatever
			-- each caller derives from it: the strip button and the tab body must be reading one
			-- answer to "which tab is showing", not two that could drift apart.
			local tabs = ScreenFrame.NewTabState(newScope(), { "Character", "Arts" })
			expect(tabs.Selected["Arts"]).to.equal(tabs.Selected["Arts"])
		end)

		it("refuses an empty tab list", function()
			-- A screen with no tabs has no way to say what it is: the frame deliberately has no title
			-- bar, so the strip is the only thing that names it.
			expect(function()
				ScreenFrame.NewTabState(newScope(), {})
			end).to.throw()
		end)
	end)
end
