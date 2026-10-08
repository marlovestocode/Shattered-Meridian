--!strict
--[[
	ScreenFrame.lua

	Owns: the banded panel frame every full-screen modal in this UI now wears -- a tab strip with the
	close control pinned in its own right-hand zone, a body, and a footer band carrying a wordmark and
	a status line. Plus the tab state those two ends share.

	THIS IS THE CHARACTER MENU'S FRAME, EXTRACTED. Screens/Menus/init.lua's header argues the design at
	length and none of it is repeated here: bands bleed to the panel edge, nothing inside a band draws a
	second box, separation is carried by band backgrounds and one hairline each, and there is no title
	bar because the tab strip already says louder what the panel is. What that header could not say is
	that the argument applied to every other modal too -- Settings, the Live Console and the Storybook
	were each still a heading, a row of bordered chips, and a stack of bordered Panels each drawing a
	border inside a border. Four screens agreeing by copy-paste is how the three layout bugs in that
	header's own list happened, so the agreement lives here instead.

		local BODY_WIDTH, BODY_HEIGHT = ScreenFrame.BodySize(ROOT_WIDTH, ROOT_HEIGHT)
		local tabs = ScreenFrame.NewTabState(scope, { "Keybinds", "Gameplay" })

		ScreenFrame.Mount(scope, playerGui, {
			Name = "Settings",
			Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
			IsOpen = isOpen,
			Tabs = tabs,
			Wordmark = "SETTINGS",
			StatusText = statusText,
			OnClose = function() isOpen:set(false) end,
			Body = Stack.New(scope, { Children = { keybindsTab, gameplayTab } }),
		})

	A SCREEN WITH NO TABS PUTS ITS NAME IN THE STRIP INSTEAD, and that is not the title bar coming
	back. The three authoring tools (Dev Menu, Move Editor, Kit Editor) are shaped around a persistent
	sidebar rather than around tabs -- there is nothing for a strip of tabs to switch between, and
	nothing else on the panel that says which tool it is. So Title fills the band the close control
	already had to occupy: no extra chrome, no second rule, no 36px spent. What the character menu
	deleted was a band that RESTATED the highlighted tab beneath it; a band that is the only thing
	naming the panel is a different object with the same pixel height. Tabs and Title are mutually
	exclusive, and passing neither is an error rather than a bare strip -- a frame that names itself
	nowhere is the one outcome this component should not make easy.

	A STRIP WHOSE TABS COME AND GO (2026-10-01, NewTabState's optional `availability`). The Move Editor's tabs
	depend on what kind of move is open -- a realm has no hitbox to place and a swing has no boundary to
	draw -- so a tab can be given a boolean it is shown by. A hidden tab holds no space and the rest share
	the strip (a flex fill, not 1/N of the names the caller listed). What is SHOWN is then derived, not
	written: the tab asked for (Current) while it is on offer, else the first one that is (Shown). So the
	body never sits on a page the strip no longer offers, and when the asked-for tab comes back (the move
	turned back into a swing), so does the author's place on it. It is a Computed rather than an observer
	that rewrites Current because an observer writing the very Value its own Computed reads is a cycle
	Fusion refuses (Graph/change: a "busy" dependent is an infinite loop). A state with no availability
	behaves exactly as it always did: Shown is Current.

	TAB STATE IS ONE OBJECT, not a Value plus a bag of Computeds the caller assembles. The strip's
	buttons and the body's panels are asking the same question -- which tab is showing -- and when each
	built its own Computed to ask it there were two answers in the tree that could in principle
	disagree. NewTabState builds one Computed per tab, the strip reads it for Selected and the caller
	reads the same one for its body's Visible.

	BodySize is a FUNCTION OF THIS MODULE'S OWN BAND HEIGHTS rather than a constant each screen sums by
	hand. That is the whole of docs/architecture/2026-08-20-ui-velocity-plan.md section 2.1 applied to
	the frame itself: raising the footer by two pixels used to be a four-file change with no compiler
	help and a silent clipping failure at the end of it.

	WHAT IT DOES NOT OWN:
	- What is in the body. One instance, sized however the caller likes -- typically a Stack (all tabs
	  mounted, each toggling its own Visible) or a Stack.Row (a pinned rail beside the tab content, the
	  way Screens/Menus/init.lua does it).
	- Whether the panel is open. IsOpen belongs to the screen; OnClose is a callback rather than a
	  Value this module writes, because a close is a thing some screens do more than set a flag for
	  (Screens/DevTools/LiveConsole has to unsubscribe) -- see LiveConsoleClient.lua's own setOpen.
	- Scaling, brackets, the surface texture, the modal-open Attribute: all Components/ModalScreen.lua's,
	  which this wraps rather than replaces. A screen that wants a differently-shaped frame should call
	  ModalScreen directly, exactly as Screens/BugReport does (a form sized by its own content,
	  AutomaticSize.Y, so there is no fixed body band for a frame to divide). Screens/Onboarding is a
	  third shape again and calls Components/Panel.lua directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local ModalScreen = require(script.Parent.ModalScreen)
local Label = require(script.Parent.Label)
local TrackedLabel = require(script.Parent.TrackedLabel)
local Button = require(script.Parent.Button)
local Tab = require(script.Parent.Tab)
local Stack = require(script.Parent.Stack)
local Layer = require(script.Parent.Layer)
local Inset = require(script.Parent.Inset)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local ScreenFrame = {}

-- Band metrics. Public because a caller has to size its body against them, and a caller that
-- re-typed the numbers instead would be back to the arithmetic this module exists to delete.
ScreenFrame.TabStripHeight = 46
ScreenFrame.FooterHeight = 34
-- The horizontal inset shared by both bands, so the wordmark, the status line and the close control
-- all sit on one margin.
ScreenFrame.BandPaddingX = 20

local CLOSE_BUTTON_SIZE = 28
-- The slice of the tab strip reserved for the close control (the button plus the band inset on either
-- side of it), so the tab run can never grow underneath it however many tabs a screen declares.
local CLOSE_ZONE_WIDTH = CLOSE_BUTTON_SIZE + ScreenFrame.BandPaddingX * 2

export type TabState = {
	Names: { string },
	-- The currently selected tab name. Writable -- a screen that wants to open on a specific tab sets
	-- it, and "jump to the tab that owns this thing" navigation (the Move Editor does it when a save is
	-- refused over a field on another tab) is just a set.
	Current: Fusion.Value<string>,
	-- The tab actually showing: Current while it is on offer, else the first tab that is (see this file's
	-- header). Equal to Current for a state with no availability.
	Shown: Fusion.Computed<string>,
	-- One shared Computed per tab name, true for the SHOWN tab -- see this file's header on why the caller
	-- must read these rather than build its own.
	Selected: { [string]: Fusion.Computed<boolean> },
	-- Which tabs are on offer, by name (a missing name is always available), or nil when every tab is.
	Available: { [string]: UsedAs<boolean> }?,
}

export type ScreenFrameProps = {
	Name: string,
	-- The panel's authored pixel size. Pass the same numbers BodySize was given.
	Size: UsedAs<UDim2>,
	IsOpen: UsedAs<boolean>,
	-- Grows the panel with the viewport (ModalScreen.AutoScale). Off by default, matching that
	-- component's own default -- a screen sized against its own content is not automatically safe to
	-- scale, so it stays a per-screen opt-in.
	AutoScale: boolean?,
	-- AutoScale that also shrinks the panel to stay on screen (ModalScreen.FitSize), for a panel larger than
	-- the reference resolution leaves room for. Size must then be an offset UDim2.
	FitToViewport: boolean?,
	-- The tab strip's contents. Exactly one of Tabs/Title -- see this file's header.
	Tabs: TabState?,
	-- The panel's name, for a screen with no tabs.
	Title: string?,
	-- Optional instance pinned to the strip's right, clear of the close zone -- a live readout that
	-- belongs to the whole panel rather than to anything in its body (the Dev Menu's resolved target).
	-- Positions itself against the strip's own box; nothing lays it out.
	HeaderAccessory: Instance?,
	-- Left-aligned footer text. Defaults to the game wordmark; a screen whose identity used to live in
	-- a title bar should pass its own name here instead, which is where that identity went.
	Wordmark: string?,
	-- Right-aligned transient line -- the answer to the last action ("Saved.", "Not enough Qi."). The
	-- footer band, not the tab that raised it: an action's answer belongs at the frame's edge.
	StatusText: UsedAs<string>?,
	OnClose: () -> (),
	-- Exactly one instance, filling the body band. See this file's header.
	Body: Instance,
}

-- The panel's body height, once both bands are removed. Width passes through unchanged -- the bands
-- are horizontal, so nothing is taken off the sides -- and is returned anyway so a caller writes one
-- line rather than one line and a separate `local BODY_WIDTH = ROOT_WIDTH`.
function ScreenFrame.BodySize(rootWidth: number, rootHeight: number): (number, number)
	return rootWidth, rootHeight - ScreenFrame.TabStripHeight - ScreenFrame.FooterHeight
end

-- Builds the shared tab state. `names` is the strip order; the first is selected on mount. `availability`
-- (optional, see this file's header) maps a name to the boolean it is offered by.
function ScreenFrame.NewTabState(
	scope: Scope,
	names: { string },
	availability: { [string]: UsedAs<boolean> }?
): TabState
	assert(#names > 0, "ScreenFrame.NewTabState needs at least one tab name")

	local current = scope:Value(names[1])
	local function isOffered(use: Fusion.Use, name: string): boolean
		local offered = if availability then availability[name] else nil
		return offered == nil or use(offered) == true
	end
	local shown = scope:Computed(function(use): string
		local asked = use(current)
		if availability == nil or isOffered(use, asked) then
			return asked
		end
		for _, name in ipairs(names) do
			if isOffered(use, name) then
				return name
			end
		end
		-- Nothing on offer at all: show what was asked rather than nothing.
		return asked
	end)
	local selected: { [string]: Fusion.Computed<boolean> } = {}
	for _, name in ipairs(names) do
		selected[name] = scope:Computed(function(use)
			return use(shown) == name
		end)
	end

	return { Names = names, Current = current, Shown = shown, Selected = selected, Available = availability }
end

-- A band's closing hairline. Bands are flush against each other, so the seam between two of them is
-- one rule owned by one band -- never one drawn by each, which is how a 1px seam becomes a visibly
-- heavier 2px one. Lives in a Layer's Over slot, so no layout can sweep it into the band's content.
local function bandRule(scope: Scope, edge: "Top" | "Bottom"): Frame
	local atTop = edge == "Top"
	return scope:New "Frame" {
		Name = `{edge}Rule`,
		AnchorPoint = Vector2.new(0, if atTop then 0 else 1),
		Position = UDim2.fromScale(0, if atTop then 0 else 1),
		Size = UDim2.new(1, 0, 0, Tokens.Control.DividerThickness),
		BackgroundColor3 = Tokens.Border.Standard.Color,
		BackgroundTransparency = Tokens.Border.Standard.Transparency,
		BorderSizePixel = 0,
	} :: Frame
end

-- A band's inset content holder: full-size, transparent, layout-free, so the two anchored labels a
-- footer holds land on the band's own edges. Not a Stack -- both of its children are pinned rather
-- than arranged, which is the one thing a Stack must never be asked to do.
local function bandContent(scope: Scope, name: string, contents: { Instance }): Frame
	return scope:New "Frame" {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,

		[Children] = {
			Inset(scope, { X = ScreenFrame.BandPaddingX }),
			contents,
		},
	} :: Frame
end

-- The tabbed strip content: one Underline tab per name, butted against each other.
local function tabRun(scope: Scope, tabs: TabState): Frame
	local names = tabs.Names
	local available = tabs.Available
	local buttons: { Instance } = {}
	for index, name in ipairs(names) do
		local tab = Tab(scope, {
			Text = name,
			Variant = "Underline",
			-- Tab names are static strings from the caller's own literal list, which is the one
			-- case Tab.lua allows the tracked-caps treatment for -- see its header.
			TrackedCaps = true,
			Size = UDim2.fromScale(1 / #names, 1),
			LayoutOrder = index,
			Selected = tabs.Selected[name],
			Visible = if available then available[name] else nil,
			OnActivated = function()
				tabs.Current:set(name)
			end,
		})
		-- With tabs that come and go, 1/#names of the strip would leave a gap where a hidden one was: the
		-- visible tabs share it out instead.
		table.insert(buttons, if available then Stack.Fill(scope, tab) else tab)
	end

	return Stack.Row(scope, {
		Name = "StripContent",
		-- Stops short of the close zone rather than running the full width -- see CLOSE_ZONE_WIDTH.
		Size = UDim2.new(1, -CLOSE_ZONE_WIDTH, 1, 0),
		-- No Gap: the tabs butt against each other so the strip reads as one continuous band rather
		-- than as chips floating in it. Tab's Underline variant draws its own separating hairline.
		Children = buttons,
	})
end

-- The untabbed strip content: the panel's name on the band's own left margin, in the same tracked
-- caps a selected tab is set in, so a tool panel and a tabbed one read as the same family rather
-- than as a heading and a tab strip.
local function titleRun(scope: Scope, title: string): Frame
	return bandContent(scope, "StripContent", {
		TrackedLabel(scope, {
			Text = title,
			Scale = "Eyebrow",
			Color = Tokens.Color.TextPrimary,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
		}),
	})
end

local function tabStrip(scope: Scope, props: ScreenFrameProps): Frame
	local tabs = props.Tabs
	assert(
		(tabs ~= nil) ~= (props.Title ~= nil),
		"ScreenFrame needs exactly one of Tabs/Title -- a frame that names itself nowhere has no title bar to fall back on"
	)

	local over: { Instance } = {
		bandRule(scope, "Bottom"),
		Button(scope, {
			Text = "X",
			Variant = "Secondary",
			Size = UDim2.fromOffset(CLOSE_BUTTON_SIZE, CLOSE_BUTTON_SIZE),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -ScreenFrame.BandPaddingX, 0.5, 0),
			OnActivated = props.OnClose,
		}),
	}
	if props.HeaderAccessory then
		table.insert(over, props.HeaderAccessory)
	end

	return Layer(scope, {
		Name = "TabStrip",
		Size = UDim2.new(1, 0, 0, ScreenFrame.TabStripHeight),
		LayoutOrder = 1,
		-- Transparent, not Surface-filled: the panel's own surface texture runs continuously behind the
		-- strip and the body, and painting the strip would cut a flat notch through it across the top.
		Content = if tabs then tabRun(scope, tabs) else titleRun(scope, props.Title :: string),
		Over = over,
	})
end

local function footer(scope: Scope, props: ScreenFrameProps): Frame
	return Layer(scope, {
		Name = "Footer",
		Size = UDim2.new(1, 0, 0, ScreenFrame.FooterHeight),
		LayoutOrder = 3,
		BackgroundColor3 = Tokens.Color.SurfaceElevated,
		BackgroundTransparency = 0,
		Content = bandContent(scope, "FooterContent", {
			TrackedLabel(scope, {
				Text = props.Wordmark or "SHATTERED MERIDIAN",
				Scale = "Chip",
				Color = Tokens.Color.TextDisabled,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
			}),
			Label(scope, {
				Text = props.StatusText or "",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromScale(0.7, 1),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
		}),
		Over = { bandRule(scope, "Top") },
	})
end

function ScreenFrame.Mount(scope: Scope, playerGui: PlayerGui, props: ScreenFrameProps): Frame
	local authored = Fusion.peek(props.Size)
	local fitSize = if props.FitToViewport then Vector2.new(authored.X.Offset, authored.Y.Offset) else nil
	return ModalScreen(scope, playerGui, {
		Name = props.Name,
		Size = props.Size,
		IsOpen = props.IsOpen,
		AutoScale = props.AutoScale,
		FitSize = fitSize,
		-- Flush bands: a band with a 16px margin around it is not a band, it's a card.
		Padding = 0,
		Gap = 0,
		-- The panel body is the base Surface so the two bands can be the elevated ones; Elevated
		-- everywhere would flatten the frame into a single tone.
		Elevated = false,
		SurfaceTexture = true,
		-- The redesign's 16px unornamented brackets in bronze -- see Panel.lua's own prop comments on
		-- why each of these is an explicit opt-in rather than a changed default.
		BracketArmLength = 16,
		CornerAccentColor = Tokens.Color.AccentSecondary,
		CornerAccentRivets = false,

		Children = {
			tabStrip(scope, props),
			-- The body takes whatever the two bands left, via the flex item rather than via
			-- `1, -(TabStripHeight + FooterHeight)`. Both numbers are this module's own, so the
			-- subtraction would have been safe here in a way it never was in a screen -- but this frame
			-- is the first thing anyone reads when they copy the pattern, and what it demonstrates
			-- should be the thing Components/Stack.lua exists to make possible.
			Stack.Fill(
				scope,
				Layer(scope, {
					Name = "Body",
					LayoutOrder = 2,
					-- The structural backstop for everything a screen draws. Every body sizes itself
					-- from BodySize, but a row that mis-measures -- a long art name, another player's
					-- display name -- must be clipped at the band edge rather than painting over the
					-- panel border.
					ClipsDescendants = true,
					Content = props.Body,
				})
			),
			footer(scope, props),
		},
	})
end

return ScreenFrame
