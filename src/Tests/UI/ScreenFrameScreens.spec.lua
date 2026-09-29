--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UI = StarterPlayer.StarterPlayerScripts.Client.UI
local Screens = UI.Screens

local Settings = require(Screens.Settings)
local LiveConsole = require(Screens.DevTools.LiveConsole)
local DevMenu = require(Screens.DevTools.DevMenu)
local MoveEditor = require(Screens.DevTools.MoveEditor)
local KitEditor = require(Screens.DevTools.KitEditor)

-- Every screen that wears Components/ScreenFrame.lua, mounted once. Same argument as
-- Storybook.spec.lua beside it -- Roblox property names are unchecked until the code runs, and the
-- ScreenFrame migration rewrote the outermost layout of all six of these at once -- with one
-- addition that matters more here: ScreenFrame ASSERTS that exactly one of Tabs/Title is passed, and
-- an assert that no test ever reaches is an assert that fires for the first time in front of whoever
-- opens the panel.
--
-- Structure only, again. That every band is where it should look is not answerable in a place with no
-- render pipeline; that every band EXISTS, in the right order, under the right names, is.

local function fakePlayerGui(): PlayerGui
	return Instance.new("Folder") :: any
end

return function()
	-- Inside the returned function, not beside fakePlayerGui above it: TestEZ injects `expect` into
	-- the environment of THIS function, so a helper declared at module scope sees it as nil and fails
	-- with "attempt to call a nil value" pointing at its own declaration line.
	--
	-- The three bands, by name. Asserted by NAME rather than by position in the child list because the
	-- whole point of the component is that a screen no longer places these itself -- a test that
	-- checked coordinates would be re-asserting the arithmetic this replaced. Searched recursively:
	-- how deeply ModalScreen nests its Panel is that component's business, not this one's.
	--
	-- BY NAME, not FindFirstChildOfClass: a screen may mount more than one ScreenGui into the same
	-- parent (a sibling overlay), and a class lookup would find whichever came first and report the
	-- screen as missing its bands.
	local function expectFrameBands(parent: Instance, screenName: string): ()
		local screenGui = parent:FindFirstChild(screenName)
		expect(screenGui).to.be.ok()
		expect((screenGui :: ScreenGui):FindFirstChild("TabStrip", true)).to.be.ok()
		expect((screenGui :: ScreenGui):FindFirstChild("Body", true)).to.be.ok()
		expect((screenGui :: ScreenGui):FindFirstChild("Footer", true)).to.be.ok()
	end

	describe("the tabbed screens", function()
		-- THE CHARACTER MENU IS NOT HERE, and it is the one screen that cannot be: BountyTab.Mount
		-- reads Players.LocalPlayer.UserId at construction time (it needs to know which board row is
		-- yours), and a headless server place has no LocalPlayer to read. Not a defect in either --
		-- that tab is client-only by nature -- but it does mean the menu this frame was extracted FROM
		-- is the one screen whose construction still has to be checked by opening it. The five below
		-- exercise every path through ScreenFrame regardless: three tabbed, two titled.

		it("mounts Settings", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			expect(Settings.Mount(scope, parent)).to.be.ok()
			expectFrameBands(parent, "Settings")
		end)

		it("mounts the Live Console", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			expect(LiveConsole.Mount(scope, parent)).to.be.ok()
			expectFrameBands(parent, "LiveConsole")
		end)
	end)

	describe("the untabbed authoring tools", function()
		it("mounts the Dev Menu", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			expect(DevMenu.Mount(scope, parent)).to.be.ok()
			expectFrameBands(parent, "DevMenu")
		end)

		it("mounts the Move Editor", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			expect(MoveEditor.Mount(scope, parent)).to.be.ok()
			expectFrameBands(parent, "MoveEditor")
		end)

		it("mounts the Kit Editor", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			expect(KitEditor.Mount(scope, parent)).to.be.ok()
			expectFrameBands(parent, "KitEditor")
		end)
	end)
end
