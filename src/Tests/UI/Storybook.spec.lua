--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Screens = StarterPlayer.StarterPlayerScripts.Client.UI.Screens
local Storybook = require(Screens.DevTools.Storybook)

local peek = Fusion.peek

-- THE CONSTRUCTION SMOKE TEST, in the permanent home docs/architecture/2026-08-20-ui-velocity-plan.md
-- section 2.3 asked for. Its predecessor was a throwaway run-in-roblox script that built all 24 new
-- components once and was deleted the same session; this asserts strictly more and runs on every
-- suite invocation.
--
-- WHY IT IS WORTH ANYTHING: Roblox property names are unchecked by selene and by the Luau type
-- system (see this repo's `roblox-property-names-are-unchecked` note), so `TextXAlingment = ...` or
-- an enum that was renamed between releases is invisible until the code RUNS. Mounting the gallery
-- runs every component in the tree at least once, in several states each, which is the only cheap
-- way to make that class of typo fail a build instead of a playtest.
--
-- WHAT IT STILL CANNOT ANSWER is anything about how the result LOOKS -- a headless place has no
-- render pipeline, so no AbsoluteSize ever resolves and Stack.Fill claiming its leftover space is
-- exactly as unverifiable here as it is in LayoutPrimitives.spec.lua. That is what the panel itself
-- is for; this is the half a machine can check.

-- Mount() wants a PlayerGui and there is no LocalPlayer in a headless server place. A Folder is
-- structurally sufficient -- a ScreenGui parents to it happily, and every consumer of the real
-- PlayerGui in this tree already guards for a nil LocalPlayer (ModalScreen's own modal-gate publish
-- does exactly this). Cast rather than faked: nothing here reads a PlayerGui-specific member.
local function fakePlayerGui(): PlayerGui
	return Instance.new("Folder") :: any
end

return function()
	describe("the gallery", function()
		it("constructs every page without erroring", function()
			local scope = Fusion.scoped(Fusion)
			local handle = Storybook.Mount(scope, fakePlayerGui())
			expect(handle).to.be.ok()
			expect(peek(handle.IsOpen)).to.equal(false)
		end)

		it("builds a ScreenGui that starts disabled", function()
			-- Closed on mount matters more than it looks: this screen is deferred behind a Lazy, and a
			-- gallery that mounted already-visible would put itself on screen the instant anything
			-- forced that Lazy for an unrelated reason.
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			Storybook.Mount(scope, parent)

			local screenGui = parent:FindFirstChildOfClass("ScreenGui")
			expect(screenGui).to.be.ok()
			expect((screenGui :: ScreenGui).Enabled).to.equal(false)
		end)

		it("opens and closes off its handle", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			local handle = Storybook.Mount(scope, parent)
			local screenGui = parent:FindFirstChildOfClass("ScreenGui") :: ScreenGui

			handle.IsOpen:set(true)
			expect(screenGui.Enabled).to.equal(true)
			handle.IsOpen:set(false)
			expect(screenGui.Enabled).to.equal(false)
		end)
	end)
end
