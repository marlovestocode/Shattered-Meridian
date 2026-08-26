--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Components = StarterPlayer.StarterPlayerScripts.Client.UI.Components
local Stack = require(Components.Stack)
local Layer = require(Components.Layer)
local Inset = require(Components.Inset)

-- Unlike WheelSelection.spec.lua beside it, these three modules are NOT pure -- they build real
-- Instances. That is exactly why they are worth testing here rather than by eye: the properties they
-- set are unchecked by selene and by the Luau type system (see the
-- `roblox-property-names-are-unchecked` note), so a renamed enum or a mistyped property is invisible
-- until someone opens Studio.
--
-- What these assert is STRUCTURE, never rendered geometry. A headless server place has no render
-- pipeline, so AbsoluteSize never resolves and "does Fill actually claim the leftover 300px" cannot
-- be answered here -- that one needs the Storybook and a pair of eyes. What CAN be answered, and is
-- the thing that would silently break everything built on Stack.Fill, is whether UIFlexItem exists
-- in this engine version at all and whether Fill is a real FlexMode.

local function newScope(): any
	return Fusion.scoped(Fusion)
end

return function()
	describe("engine support the layout primitives assume", function()
		it("exposes Enum.UIFlexMode.Fill", function()
			expect(Enum.UIFlexMode).to.be.ok()
			expect(Enum.UIFlexMode.Fill).to.be.ok()
		end)

		it("can instantiate a UIFlexItem", function()
			local item = Instance.new("UIFlexItem")
			item.FlexMode = Enum.UIFlexMode.Fill
			expect(item.FlexMode).to.equal(Enum.UIFlexMode.Fill)
			item:Destroy()
		end)

		it("exposes UIListLayout.Wraps, which Stack passes through", function()
			local layout = Instance.new("UIListLayout")
			layout.Wraps = true
			expect(layout.Wraps).to.equal(true)
			layout:Destroy()
		end)
	end)

	describe("Stack", function()
		it("builds a vertical list layout carrying the requested gap", function()
			local built = Stack.New(newScope(), { Gap = 8, Children = {} })
			local layout = built:FindFirstChildOfClass("UIListLayout")
			expect(layout).to.be.ok()
			expect((layout :: UIListLayout).FillDirection).to.equal(Enum.FillDirection.Vertical)
			expect((layout :: UIListLayout).Padding).to.equal(UDim.new(0, 8))
		end)

		it("sorts by LayoutOrder, never by child order", function()
			-- Load-bearing: a caller that inserts a conditional child mid-list must not silently
			-- renumber every sibling after it.
			local built = Stack.New(newScope(), { Children = {} })
			local layout = built:FindFirstChildOfClass("UIListLayout") :: UIListLayout
			expect(layout.SortOrder).to.equal(Enum.SortOrder.LayoutOrder)
		end)

		it("Stack.Row lays out horizontally", function()
			local built = Stack.Row(newScope(), { Gap = 4, Children = {} })
			local layout = built:FindFirstChildOfClass("UIListLayout") :: UIListLayout
			expect(layout.FillDirection).to.equal(Enum.FillDirection.Horizontal)
		end)

		it("defaults to a transparent background so a container is invisible unless asked for", function()
			local built = Stack.New(newScope(), { Children = {} })
			expect(built.BackgroundTransparency).to.equal(1)
		end)

		it("Fill attaches a Fill-mode UIFlexItem and returns the same instance", function()
			local scope = newScope()
			local child = scope:New("Frame")({ Size = UDim2.fromScale(1, 1) })
			local returned = Stack.Fill(scope, child)
			expect(returned).to.equal(child)
			local item = child:FindFirstChildOfClass("UIFlexItem")
			expect(item).to.be.ok()
			expect((item :: UIFlexItem).FlexMode).to.equal(Enum.UIFlexMode.Fill)
		end)
	end)

	describe("Layer", function()
		it("builds only the slots it was given", function()
			local built = Layer(newScope(), { Content = Stack.New(newScope(), { Children = {} }) })
			expect(built:FindFirstChild("Content")).to.be.ok()
			expect(built:FindFirstChild("Over")).to.never.be.ok()
			expect(built:FindFirstChild("Under")).to.never.be.ok()
		end)

		it("keeps pinned slots free of any layout", function()
			-- THE WHOLE POINT OF THE MODULE. A UIListLayout in either holder would re-introduce the
			-- bug class it exists to close -- see Layer.lua's header for the three times that bug
			-- shipped by hand.
			local scope = newScope()
			local built = Layer(scope, {
				Under = { scope:New("Frame")({ Size = UDim2.fromScale(1, 1) }) },
				Content = Stack.New(scope, { Children = {} }),
				Over = { scope:New("Frame")({ Size = UDim2.new(1, 0, 0, 1) }) },
			})
			expect(built.Under:FindFirstChildOfClass("UIListLayout")).to.never.be.ok()
			expect(built.Over:FindFirstChildOfClass("UIListLayout")).to.never.be.ok()
		end)

		it("orders Under below Content below Over", function()
			local scope = newScope()
			local built = Layer(scope, {
				Under = { scope:New("Frame")({}) },
				Content = Stack.New(scope, { Children = {} }),
				Over = { scope:New("Frame")({}) },
			})
			expect(built.Under.ZIndex < built.Content.ZIndex).to.equal(true)
			expect(built.Content.ZIndex < built.Over.ZIndex).to.equal(true)
		end)

		it("ignores empty slot arrays rather than building dead holders", function()
			local built = Layer(newScope(), { Over = {}, Under = {} })
			expect(built:FindFirstChild("Over")).to.never.be.ok()
			expect(built:FindFirstChild("Under")).to.never.be.ok()
		end)
	end)

	describe("Inset", function()
		it("insets all four sides from a single number", function()
			local pad = Inset(newScope(), 16)
			expect(pad.PaddingTop).to.equal(UDim.new(0, 16))
			expect(pad.PaddingBottom).to.equal(UDim.new(0, 16))
			expect(pad.PaddingLeft).to.equal(UDim.new(0, 16))
			expect(pad.PaddingRight).to.equal(UDim.new(0, 16))
		end)

		it("applies X to the horizontal pair only", function()
			local pad = Inset(newScope(), { X = 20 })
			expect(pad.PaddingLeft).to.equal(UDim.new(0, 20))
			expect(pad.PaddingRight).to.equal(UDim.new(0, 20))
			expect(pad.PaddingTop).to.equal(UDim.new(0, 0))
			expect(pad.PaddingBottom).to.equal(UDim.new(0, 0))
		end)

		it("lets a named side beat the axis shorthand it belongs to", function()
			-- The only reading that makes the shorthand worth having: `{ X = 16, Right = 0 }` is a
			-- gutter on the left and nothing on the right, not an argument about which wins.
			local pad = Inset(newScope(), { X = 16, Right = 0, Top = 12, Bottom = 20 })
			expect(pad.PaddingLeft).to.equal(UDim.new(0, 16))
			expect(pad.PaddingRight).to.equal(UDim.new(0, 0))
			expect(pad.PaddingTop).to.equal(UDim.new(0, 12))
			expect(pad.PaddingBottom).to.equal(UDim.new(0, 20))
		end)

		it("defaults an unspecified side to zero rather than inheriting anything", function()
			local pad = Inset(newScope(), { Top = 10 })
			expect(pad.PaddingBottom).to.equal(UDim.new(0, 0))
			expect(pad.PaddingLeft).to.equal(UDim.new(0, 0))
		end)
	end)
end
