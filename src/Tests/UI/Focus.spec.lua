--!strict
-- Covers Client/UI/Shell/Focus.lua -- the geometric selection graph behind gamepad menu navigation.
--
-- EVERY ASSERTION HERE GOES THROUGH Focus.BuildGraph RATHER THAN THROUGH REAL GuiObjects, which is
-- the seam that file's own header argues for: a headless suite has no render pass, so the
-- AbsolutePosition/AbsoluteSize of a Frame built here would be zeroes, and a spec driven off them
-- would be asserting against the layout engine's willingness to run rather than against the
-- traversal rule. The rects below are the numbers a real layout WOULD produce, stated directly.

local StarterPlayer = game:GetService("StarterPlayer")

local Focus = require(StarterPlayer.StarterPlayerScripts.Client.UI.Shell.Focus)

-- A control of `size` whose top-left corner is at (x, y) -- the same shape AbsolutePosition/
-- AbsoluteSize report.
local function rect(x: number, y: number, width: number, height: number): Focus.Rect
	return { Position = Vector2.new(x, y), Size = Vector2.new(width, height) }
end

return function()
	describe("BuildGraph", function()
		it("is constructible with no LocalPlayer, and returns one entry per rect", function()
			-- The first assertion of every Client/Input-adjacent spec in this codebase: this module is
			-- require-loaded on the server by scripts/run-tests.lua, where Players.LocalPlayer is nil.
			-- Reaching this line at all is the proof.
			local graph = Focus.BuildGraph({ rect(0, 0, 100, 40), rect(0, 60, 100, 40) })
			expect(#graph).to.equal(2)
		end)

		it("returns no edges at all for a single control", function()
			local graph = Focus.BuildGraph({ rect(0, 0, 100, 40) })
			expect(graph[1].Up).to.equal(nil)
			expect(graph[1].Down).to.equal(nil)
			expect(graph[1].Left).to.equal(nil)
			expect(graph[1].Right).to.equal(nil)
		end)

		it("links a vertical stack top-to-bottom in order", function()
			-- Three rows, one column.
			local graph = Focus.BuildGraph({
				rect(0, 0, 100, 40),
				rect(0, 50, 100, 40),
				rect(0, 100, 100, 40),
			})
			expect(graph[1].Down).to.equal(2)
			expect(graph[2].Down).to.equal(3)
			expect(graph[2].Up).to.equal(1)
			expect(graph[3].Up).to.equal(2)
		end)

		it("links a horizontal row left-to-right in order", function()
			local graph = Focus.BuildGraph({
				rect(0, 0, 40, 40),
				rect(50, 0, 40, 40),
				rect(100, 0, 40, 40),
			})
			expect(graph[1].Right).to.equal(2)
			expect(graph[2].Right).to.equal(3)
			expect(graph[2].Left).to.equal(1)
			expect(graph[3].Left).to.equal(2)
		end)

		it("wraps a vertical stack from the bottom back to the top", function()
			-- The wrap is this file's own rather than SelectionGroup's -- see Focus.lua's header for
			-- why explicit NextSelection* properties mean the engine never gets to do it.
			local graph = Focus.BuildGraph({
				rect(0, 0, 100, 40),
				rect(0, 50, 100, 40),
				rect(0, 100, 100, 40),
			})
			expect(graph[3].Down).to.equal(1)
			expect(graph[1].Up).to.equal(3)
		end)

		it("prefers the control directly below over a nearer one far to the side", function()
			-- THE CASE THE PERPENDICULAR PENALTY EXISTS FOR. From control 1, control 3 sits directly
			-- below at 60px; control 2 is only 10px below but 400px to the right, so plain
			-- nearest-centre would pick it and a Down press would jump sideways across the panel.
			local graph = Focus.BuildGraph({
				rect(0, 0, 100, 40),
				rect(400, 30, 100, 40),
				rect(0, 60, 100, 40),
			})
			expect(graph[1].Down).to.equal(3)
		end)

		it("reaches a full-width control from every narrow control directly above it", function()
			-- THE CASE acrossFor MEASURES EDGE GAPS FOR. Three narrow buttons in a row, one wide field
			-- beneath them spanning all three. By centre distance the field is "far" from buttons 1
			-- and 3 and Down would skip past it; by edge gap it overlaps all three and is 0 away from
			-- each.
			local graph = Focus.BuildGraph({
				rect(0, 0, 100, 40),
				rect(120, 0, 100, 40),
				rect(240, 0, 100, 40),
				rect(0, 60, 340, 40),
				rect(0, 120, 340, 40),
			})
			expect(graph[1].Down).to.equal(4)
			expect(graph[2].Down).to.equal(4)
			expect(graph[3].Down).to.equal(4)
			expect(graph[4].Down).to.equal(5)
		end)

		it("treats a row of equal-height controls as one row, not a column", function()
			-- Same Y, so no candidate is strictly Up or Down of another WITHIN the row; the only
			-- vertical answer available is the wrap, which must stay inside the row rather than
			-- resolving to nil.
			local graph = Focus.BuildGraph({
				rect(0, 0, 40, 40),
				rect(50, 0, 40, 40),
			})
			expect(graph[1].Up).to.equal(nil)
			expect(graph[1].Down).to.equal(nil)
			expect(graph[1].Right).to.equal(2)
			expect(graph[2].Left).to.equal(1)
		end)

		it("ignores sub-pixel Y drift within a row", function()
			-- Two controls laid out in the same row can differ by a fraction of a pixel; treating that
			-- as a real vertical direction would make Down inside a button row jump to its neighbour.
			local graph = Focus.BuildGraph({
				rect(0, 0, 40, 40),
				rect(50, 0.2, 40, 40),
			})
			expect(graph[1].Down).to.equal(nil)
			expect(graph[1].Right).to.equal(2)
		end)

		it("navigates a grid down its own column rather than diagonally", function()
			-- A 2x2 grid: 1 2 on the top row, 3 4 on the bottom.
			local graph = Focus.BuildGraph({
				rect(0, 0, 100, 40),
				rect(120, 0, 100, 40),
				rect(0, 60, 100, 40),
				rect(120, 60, 100, 40),
			})
			expect(graph[1].Down).to.equal(3)
			expect(graph[2].Down).to.equal(4)
			expect(graph[3].Up).to.equal(1)
			expect(graph[4].Up).to.equal(2)
			expect(graph[1].Right).to.equal(2)
			expect(graph[3].Right).to.equal(4)
		end)

		it("wraps a grid column back to the same column, not across to the other one", function()
			local graph = Focus.BuildGraph({
				rect(0, 0, 100, 40),
				rect(120, 0, 100, 40),
				rect(0, 60, 100, 40),
				rect(120, 60, 100, 40),
			})
			expect(graph[3].Down).to.equal(1)
			expect(graph[4].Down).to.equal(2)
		end)

		it("reproduces the bug report form's own hand-wired order", function()
			-- The exact layout Screens/BugReport/init.lua used to wire by hand -- a close button, a
			-- four-button category row, a description field, then Submit/Cancel side by side. This is
			-- the regression guard for deleting those twenty-one assignments: the derived graph has to
			-- agree with what that screen shipped.
			local closeButton = rect(452, 16, 28, 28)
			local category1 = rect(20, 80, 110, 36)
			local category2 = rect(138, 80, 110, 36)
			local category3 = rect(256, 80, 110, 36)
			local category4 = rect(374, 80, 110, 36)
			local description = rect(20, 150, 464, 90)
			local submit = rect(20, 260, 228, 36)
			local cancel = rect(256, 260, 228, 36)

			local graph = Focus.BuildGraph({
				closeButton,
				category1,
				category2,
				category3,
				category4,
				description,
				submit,
				cancel,
			})

			-- The category row runs left to right and stops wrapping only at its own ends.
			expect(graph[2].Right).to.equal(3)
			expect(graph[3].Right).to.equal(4)
			expect(graph[4].Right).to.equal(5)
			expect(graph[5].Left).to.equal(4)

			-- Down out of the category row lands on the description field, from every button in it.
			expect(graph[2].Down).to.equal(6)
			expect(graph[3].Down).to.equal(6)
			expect(graph[4].Down).to.equal(6)
			expect(graph[5].Down).to.equal(6)

			-- Down out of the field lands on Submit; Submit and Cancel are horizontal neighbours.
			expect(graph[6].Down).to.equal(7)
			expect(graph[7].Right).to.equal(8)
			expect(graph[8].Left).to.equal(7)
			expect(graph[7].Up).to.equal(6)
			expect(graph[8].Up).to.equal(6)
		end)
	end)
end
