--!strict
--[[
	ModalScreen.lua

	Owns: the ScreenGui > centered elevated Panel shell every top-level admin/menu screen in this UI
	mounts itself into -- DevMenu, LiveConsole, MoveEditor, BugReport, Menus (the Character Menu), and
	Settings all hand-built the identical six-property ScreenGui plus the identical AnchorPoint/
	Position/Elevated/CornerAccent Panel plus the identical Tokens.Space.L UIPadding/Tokens.Space.M
	vertical UIListLayout wrapper before this existed -- ~15 lines duplicated six times, per the
	structure audit that found it (2026-08-19).

	Callers pass their own Header/Body/Footer (or equivalent) as Children; this component owns
	everything OUTSIDE that content, never what's inside it. Returns the Root Panel Instance, not the
	ScreenGui, because two of the six callers (BugReport/Menus) need it afterward for their own
	gamepad-focus `GuiService.SelectedObject:IsDescendantOf(root)` check -- the ScreenGui itself is
	never referenced again by any caller once mounted.

	THE INSET IS A DEFAULT, NOT A LAW. Padding/Gap were originally hardcoded to Space.L/Space.M here,
	which is right for a screen whose content is a stack of free-floating rows -- and wrong for one
	whose chrome bleeds to the panel edge. The character menu's header band, tab strip, column rule
	and footer band all have to touch the border (a header with a 16px margin around it is not a
	header, it's a card), so those two numbers are props with the original values as defaults. Every
	pre-existing caller passes neither and renders byte-for-byte as before.

	The Panel-shape props below (CornerAccent color/rivets, bracket length, surface texture) are pure
	pass-throughs to Panel.lua rather than a second opinion about how a panel looks -- this file
	decides WHERE the panel goes, never WHAT it is.

	AN OPEN MODAL SWALLOWS INPUT, AND IT TAKES BOTH HALVES BELOW TO DO IT (user, 2026-08-20: "add game
	processed event detection so im not punching everytime im in my menu"). A click anywhere while the
	character menu was open threw a punch, because:

	  1. A plain Frame does not consume mouse input. Roblox only marks an input as handled by the GUI
	     -- which is what sets `gameProcessedEvent`, which Client/Combat/AttackInputClient.lua has
	     always checked -- when it lands on a GuiButton, a TextBox, or a GuiObject with `Active` set.
	     A panel built out of Frames is, to the input system, a picture painted over the game.
	     Fixed by making the root Panel `Active`, so every click that lands ON a panel is reported as
	     already handled and every existing gameProcessed check starts working as intended.
	  2. A modal does not fill the screen. This panel is 760x620 centred; the rest of the viewport is
	     still the world, and clicking there is still a click on nothing. `Active` cannot help with
	     that, because the input genuinely did not touch the GUI. Fixed by publishing
	     Constants.Attributes.UiModalOpen, which combat input reads as a hard gate -- see that
	     constant's own comment for why it lives on the Player and why it is count-backed.

	This file owns the count because it is the only thing in the codebase that creates a modal, and
	the count is driven off the ScreenGui's OWN `Enabled` property rather than off props.IsOpen: that
	is the rendered truth, it works whether a caller passed a Fusion Value or a plain boolean, and it
	cannot drift from what the player is actually looking at.

	AUTOSCALE IS THE REAL ANSWER TO "I CAN'T READ THIS" (user, 2026-08-20, twice). A panel authored at
	760x620 is a fixed number of PIXELS, so on a 1440p or 4K monitor it is physically small no matter
	what Tokens.Type says -- and every extra point of type size spent chasing that costs layout room
	inside a frame that is already too small for the screen it is on. Growing the whole panel with the
	viewport fixes the actual cause, costs no layout risk at all (a UIScale reflows nothing, it just
	multiplies), and leaves the type scale free to be sized for its own boxes rather than for the
	monitor.

	Opt-in per caller, and clamped at both ends: MIN_SCALE keeps a big panel on a small screen from
	overflowing it, MAX_SCALE keeps a 4K display from rendering the chrome as billboard art. The
	reference resolution is the size the panels were actually authored against.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local ViewportScale = require(script.Parent.Parent.ViewportScale)
local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Panel)
local Layers = require(script.Parent.Parent.Shell.Layers)
local Surface = require(script.Parent.Parent.Shell.Surface)
local Focus = require(script.Parent.Parent.Shell.Focus)
local Inset = require(script.Parent.Inset)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ModalScreenProps = {
	Name: string,
	Size: UsedAs<UDim2>,
	-- BugReport.lua's Root is the one caller sized by content (fromOffset(WIDTH, 0) + AutomaticSize.Y)
	-- rather than a fixed (width, height) -- every other caller omits this.
	AutomaticSize: Enum.AutomaticSize?,
	IsOpen: UsedAs<boolean>,
	-- Inset between the panel border and the caller's content, in pixels. Defaults to Tokens.Space.L.
	-- Pass 0 for a screen whose own bands draw to the edge -- see file header.
	Padding: number?,
	-- Vertical gap between the caller's top-level Children. Defaults to Tokens.Space.M; pass 0 for
	-- flush bands whose own hairline borders are the seam.
	Gap: number?,
	-- Defaults to true (the elevated surface every existing caller renders on).
	Elevated: boolean?,
	-- Grows the whole panel (and everything in it) with the viewport -- see file header. The curve,
	-- the reference resolution and the clamps moved to Client/UI/ViewportScale.lua once the hotbar
	-- dock wanted the same numbers; see that file's header. Off by default: the other five modals were
	-- each sized by hand against their own content and are not re-measured for this, so they keep
	-- rendering at their literal pixel size until someone opts them in deliberately.
	AutoScale: boolean?,
	-- Which control a gamepad focuses when this panel opens. Defaults to the first selectable
	-- control in reading order -- see Shell/Focus.lua. Ignored on keyboard/mouse, where no selection
	-- is claimed at all.
	FocusDefault: GuiObject?,
	-- Opts this panel out of gamepad selection entirely. Defaults to false; the only reason to pass
	-- true is a panel with no selectable controls at all, where a group would be an empty one.
	NoFocus: boolean?,
	-- Pass-throughs to Panel.lua -- see that file's own prop comments.
	BracketArmLength: number?,
	CornerAccentColor: UsedAs<Color3>?,
	CornerAccentRivets: boolean?,
	SurfaceTexture: boolean?,
	SurfaceTextureIntensity: number?,
	Children: UsedAs<{ any }>?,
}

-- How many modals are open right now, across every screen this component has ever built. Module
-- scope, not per-instance: the published Attribute is a property of the CLIENT, not of any one
-- panel, and two panels open at once must both be closed before the player's fists come back.
local openModalCount = 0

-- LAST-OPENED RENDERS ON TOP, and this counter is how. Every modal is in Layers.Modal, so without a
-- nudge two open at once would z-fight and the winner would be PlayerGui insertion order -- which for
-- the Lazy-deferred screens (DevMenu, MoveEditor, KitEditor, LiveConsole, Storybook) is FIRST-OPEN
-- order, so which panel covered which would vary between sessions depending on what the player
-- happened to open first that day. Two modals open at once is documented behaviour, not a
-- hypothetical: Constants.Attributes.UiModalOpen's own comment cites the Move Editor over the
-- character menu, and it is why openModalCount above is module-scope rather than per-instance.
--
-- Bumped on each OPEN edge, beside the count, and reset when the count returns to zero -- so it
-- cannot climb across a session into the debug band above. Clamped as well as reset, because "reset
-- when nothing is open" is only a bound if the player ever closes everything: a session that opened
-- 100 modals without the count ever reaching zero would otherwise promote one into Layers.Debug, and
-- a debug overlay a panel can cover is the exact failure the ladder's spacing exists to prevent.
local modalOrderCounter = 0
local MAX_MODAL_NUDGE = Layers.Spacing - 1

-- Called wherever openModalCount changes. Folded together with the z counter's reset rather than
-- left as two calls at three sites: "the count went to zero" and "the z nudge starts again" are one
-- fact, and the one time they were allowed to drift apart is the bug this whole block is about.
local function publishModalGate(): ()
	local player = Players.LocalPlayer
	if not player then
		-- Nothing to publish to. Reachable in a headless test place, and not an error there: the
		-- Attribute exists to gate a local player's own input, and there is no local player.
		return
	end
	player:SetAttribute(Constants.Attributes.UiModalOpen, openModalCount > 0)
end

local function noteCountChanged(): ()
	if openModalCount == 0 then
		modalOrderCounter = 0
	end
	publishModalGate()
end

-- The DisplayOrder a modal takes on the open edge. See modalOrderCounter above.
local function nextModalOrder(): number
	modalOrderCounter = math.min(modalOrderCounter + 1, MAX_MODAL_NUDGE)
	return Layers.Modal + modalOrderCounter
end

-- Called on every Enabled edge. Takes the edge rather than the level so the count can never be
-- double-incremented by a redundant property write -- and so the z nudge is only spent on a real
-- open, rather than climbing every time a caller re-sets Enabled to the value it already had.
local function trackModalOpenState(screenGui: ScreenGui, wasOpen: boolean): boolean
	local isOpen = screenGui.Enabled
	if isOpen == wasOpen then
		return wasOpen
	end
	openModalCount = math.max(openModalCount + (if isOpen then 1 else -1), 0)
	if isOpen then
		screenGui.DisplayOrder = nextModalOrder()
	end
	noteCountChanged()
	return isOpen
end

local function ModalScreen(scope: Scope, playerGui: PlayerGui, props: ModalScreenProps): Frame
	local padding = props.Padding or Tokens.Space.L
	local gap = props.Gap or Tokens.Space.M

	local root = Panel(scope, {
		Name = "Root",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = props.Size,
		AutomaticSize = props.AutomaticSize,
		-- See this file header, point 1: without this the whole panel is a picture the input system
		-- looks straight through.
		Active = true,
		Scale = if props.AutoScale then ViewportScale.Compute(scope) else nil,
		Elevated = if props.Elevated == nil then true else props.Elevated,
		CornerAccent = true,
		BracketArmLength = props.BracketArmLength,
		CornerAccentColor = props.CornerAccentColor,
		CornerAccentRivets = props.CornerAccentRivets,
		SurfaceTexture = props.SurfaceTexture,
		SurfaceTextureIntensity = props.SurfaceTextureIntensity,

		Children = {
			Inset(scope, padding),
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, gap),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			props.Children,
		},
	})

	-- Scaled = false, and that is not an omission. This component has owned modal autoscale since
	-- before Shell/Surface.lua existed: AutoScale is a per-caller prop above, applied to the Panel's
	-- own UIScale, and off by default because the other five modals were each sized by hand against
	-- their own content. Letting the surface scale them too would resize five hand-measured panels
	-- for a plan whose stated risk is "mechanical, one property set per site".
	local screenGui = Surface.New(scope, {
		Name = props.Name,
		-- The base of the band. The open edge below replaces this with Layers.Modal + n, so a modal
		-- that has never been opened sits at the bottom of its own band rather than at an arbitrary
		-- point in it.
		Layer = Layers.Modal,
		Parent = playerGui,
		Scaled = false,
		Enabled = props.IsOpen,
		Children = root,
	})

	-- Seeded from the CURRENT value rather than assumed closed: every caller mounts with IsOpen false
	-- today, but a screen that mounted already-open would otherwise leave the count one short forever.
	local wasOpen = screenGui.Enabled
	if wasOpen then
		openModalCount += 1
		screenGui.DisplayOrder = nextModalOrder()
		noteCountChanged()
	end
	table.insert(
		scope,
		screenGui:GetPropertyChangedSignal("Enabled"):Connect(function()
			wasOpen = trackModalOpenState(screenGui, wasOpen)
		end)
	)
	-- A screen torn down WHILE OPEN (Studio hot-reload, a future scope teardown) would otherwise
	-- leave the count permanently one too high, and a stuck gate means a player who can never punch
	-- again with nothing on screen to explain why. Fusion calls a plain function left in a scope on
	-- cleanup, so this is the same teardown path the connection above uses.
	--
	-- THE Z COUNTER RIDES ALONG HERE, and has to. It is the second piece of module-scope state in
	-- this file, and the plan's Phase 1 left both to be audited together for exactly that reason.
	-- Destroying a ScreenGui does not fire its own Enabled changed signal, so without this the
	-- teardown of an open modal is invisible to both numbers -- and noteCountChanged is what turns
	-- "the last one closed" into "the nudge starts from 1 again" rather than from wherever the
	-- previous session's tree left it.
	table.insert(scope, function()
		if wasOpen then
			wasOpen = false
			openModalCount = math.max(openModalCount - 1, 0)
			noteCountChanged()
		end
	end)

	-- EVERY modal is a focus group, wired ONCE here rather than per screen -- which is what makes
	-- "all nine panels are navigable on a pad" a property of the shared frame instead of nine
	-- separate things to remember. Components/ScreenFrame.lua reaches this through its own
	-- ModalScreen call, so the six screens wearing the shared frame are covered by this line too.
	-- Nothing is claimed on keyboard/mouse; see Shell/Focus.lua's header.
	if not props.NoFocus then
		Focus.Group(scope, root :: Frame, {
			Default = props.FocusDefault,
			IsOpen = props.IsOpen,
		})
	end

	return root :: Frame
end

return ModalScreen
