--!strict
--[[
	Storybook/init.lua

	Owns: the component gallery -- one scrollable panel holding every shared component in the states
	that actually differ, the full token set at real size, and live proof that the layout primitives
	do what their headers claim. Studio-only, on F7.

	THIS IS THE FIRST ITEM IN docs/architecture/2026-08-20-ui-velocity-plan.md's ORDER, and the plan
	says why at length: 36 components existed and not one of them could be LOOKED at without building
	a place and opening Studio to squint at a real screen that happened to use it. Three of the bugs
	the character menu rebuild spent time on were visual-only -- a rule swept into a text run, a badge
	that stopped reading as a badge, a heading whose accessory overlapped its note -- and none of them
	were reachable by any test in this repo. They were reachable by eye in about four seconds, which is
	the entire argument for this screen.

	It is also where the throwaway construction smoke test went. That script built all 24 new
	components once so the engine would validate every property name (see this repo's own "Roblox
	property names are unchecked" note), rendered nothing, and was deleted the same session. This page
	constructs strictly more than it did, and a run-in-roblox script that walks it gets the same
	assertion for free -- except that this one a human also reads.

	MOUNTED LAZILY AND ONLY IN STUDIO. The Lazy (Client/UI/init.lua's own handle table) is the same
	deferral the three admin screens already use -- it builds several hundred Instances and belongs
	nowhere near a player's boot path. Client/DevTools/Storybook/StorybookClient.lua declines to bind the key at
	all outside Studio, so on a live client the panel is never built and the key is never claimed.

	NO SERVER STATE, NO REMOTES, NO DRIVER-OWNED VALUES -- unlike every other Screens/ module here,
	which exists to render something the server owns. Everything on these pages is either a literal or
	a scope-local Value that goes nowhere, deliberately: a gallery that needed real data would only be
	viewable in the situations that already produce that data, which is the problem it exists to fix.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local ScreenFrame = require(script.Parent.Parent.Parent.Components.ScreenFrame)
local ScrollArea = require(script.Parent.Parent.Parent.Components.ScrollArea)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)

local TokenPage = require(script.TokenPage)
local ComponentPage = require(script.ComponentPage)
local PrimitivePage = require(script.PrimitivePage)

type Scope = Fusion.Scope<typeof(Fusion)>

export type StorybookHandle = {
	-- The only state this screen has. Written by Client/DevTools/Storybook/StorybookClient.lua's toggle and by
	-- the frame's own close button -- the same one exception every other screen's close button is.
	IsOpen: Fusion.Value<boolean>,
}

-- Wider and taller than any other modal here, and it should be: this is a reference sheet read at
-- length, not a dialog. AutoScale is on for the same reason the character menu turned it on.
local ROOT_WIDTH = 900
local ROOT_HEIGHT = 640

local TAB_NAMES = { "Tokens", "Components", "Primitives" }

local BODY_WIDTH, BODY_HEIGHT = ScreenFrame.BodySize(ROOT_WIDTH, ROOT_HEIGHT)
-- What a page actually gets to draw in: the body less its own inset on both sides, less the gutter
-- the scrollbar sits in. Specimens are full-width, so a page that ignored the scrollbar would have
-- its right edge permanently under it.
local SCROLLBAR_GUTTER = Tokens.Space.M
local PAGE_WIDTH = BODY_WIDTH - Tokens.Space.L * 2 - SCROLLBAR_GUTTER

local Storybook = {}

function Storybook.Mount(scope: Scope, playerGui: PlayerGui): StorybookHandle
	local isOpen = scope:Value(false)
	local tabs = ScreenFrame.NewTabState(scope, TAB_NAMES)

	-- All three pages mount up front and toggle on their own Visible -- the same idiom every other
	-- tabbed screen here uses, and the reason it is right for THIS screen specifically is that the
	-- live specimens (a pressed toggle, a stepped number, a selected tab) keep their state when you
	-- leave the page and come back, which is what you want while comparing two of them.
	local pages: { Instance } = {
		-- The layout has to be a direct child of the ScrollingFrame for AutomaticCanvasSize to see it,
		-- so this is one of the few places a bare UIListLayout is still correct rather than a
		-- Components/Stack.lua -- a Stack is a Frame, and a Frame here would be the thing that scrolls
		-- instead of the thing that grows. Same reason ScrollArea.lua deliberately doesn't own it.
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			Padding = UDim.new(0, Tokens.Space.L),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
		Inset(scope, {
			Top = Tokens.Space.M,
			Bottom = Tokens.Space.L,
			Left = Tokens.Space.L,
			Right = Tokens.Space.L + SCROLLBAR_GUTTER,
		}),
		TokenPage(scope, 1, tabs.Selected["Tokens"], PAGE_WIDTH),
		ComponentPage(scope, 2, tabs.Selected["Components"], PAGE_WIDTH),
		PrimitivePage(scope, 3, tabs.Selected["Primitives"], PAGE_WIDTH),
	}

	ScreenFrame.Mount(scope, playerGui, {
		Name = "Storybook",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		IsOpen = isOpen,
		AutoScale = true,
		Tabs = tabs,
		-- The screen's own name in the footer, where the removed title bar's identity went -- see
		-- ScreenFrame.lua's Wordmark comment.
		Wordmark = "STORYBOOK",
		StatusText = `Studio only -- F7. {#TAB_NAMES} pages, {BODY_HEIGHT}px body.`,
		OnClose = function()
			isOpen:set(false)
		end,
		Body = ScrollArea(scope, {
			Name = "Pages",
			Size = UDim2.fromScale(1, 1),
			Children = pages,
		}),
	})

	return { IsOpen = isOpen }
end

return Storybook
