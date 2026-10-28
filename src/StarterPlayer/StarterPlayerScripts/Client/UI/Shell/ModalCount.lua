--!strict
--[[
	Shell/ModalCount.lua

	Owns: the client's count of open modal surfaces, the UiModalOpen Attribute it publishes (the hard gate combat and
	InputRouter read), and the z nudge that puts the last-opened modal on top.

	Lifted out of Components/ModalScreen.lua (2026-10-28), which still calls Track for every panel it builds, so the
	World Architect's docked console -- a full-bleed surface that must leave the world visible, so not a centred
	ModalScreen panel -- can be counted by the SAME counter instead of a second writer of the Attribute. Nothing about
	how a ModalScreen panel counts changed; the state and its comments moved verbatim.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local Layers = require(script.Parent.Layers)

type Scope = Fusion.Scope<typeof(Fusion)>

local ModalCount = {}

-- How many modals are open right now, across every screen Components/ModalScreen.lua has ever built. Module
-- scope, not per-instance: the published Attribute is a property of the CLIENT, not of any one
-- panel, and two panels open at once must both be closed before the player's fists come back.
local openModalCount = 0

-- LAST-OPENED RENDERS ON TOP, and this counter is how. Every modal is in Layers.Modal, so without a
-- nudge two open at once would z-fight and the winner would be PlayerGui insertion order -- which for
-- the Lazy-deferred screens (DevMenu, MoveEditor, KitEditor, LiveConsole, Storybook) is FIRST-OPEN
-- order, so which panel covered which would vary between sessions depending on what the player
-- happened to open first that day. Two modals open at once is documented behaviour, not a
-- hypothetical: AttributeConstants.UiModalOpen's own comment cites the Move Editor over the
-- character menu, and it is why openModalCount above is module-scope rather than per-instance.
--
-- Bumped on each OPEN edge, beside the count, and reset when the count returns to zero -- so it
-- cannot climb across a session into the debug band above. Clamped as well as reset, because "reset
-- when nothing is open" is only a bound if the player ever closes everything: a session that opened
-- 100 modals without the count ever reaching zero would otherwise promote one into Layers.Debug, and
-- a debug overlay a panel can cover is the exact failure the ladder's spacing exists to prevent.
local modalOrderCounter = 0
local MAX_MODAL_NUDGE = Layers.Spacing - 1

-- How many of the open modals asked to keep the world visible (Track's KeepWorldVisible): a docked editor gates input
-- like any modal, but dimming the world behind it would hide the thing being edited. Chrome reads the published
-- Attribute and skips its scrim only while EVERY open modal is one of these -- a centred menu opened over the editor
-- still dims.
local worldVisibleCount = 0

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
	player:SetAttribute(AttributeConstants.UiModalOpen, openModalCount > 0)
	player:SetAttribute(
		AttributeConstants.UiModalWorldVisible,
		openModalCount > 0 and worldVisibleCount >= openModalCount
	)
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
local function trackModalOpenState(screenGui: ScreenGui, wasOpen: boolean, keepsWorld: boolean): boolean
	local isOpen = screenGui.Enabled
	if isOpen == wasOpen then
		return wasOpen
	end
	openModalCount = math.max(openModalCount + (if isOpen then 1 else -1), 0)
	if keepsWorld then
		worldVisibleCount = math.max(worldVisibleCount + (if isOpen then 1 else -1), 0)
	end
	if isOpen then
		screenGui.DisplayOrder = nextModalOrder()
	end
	noteCountChanged()
	return isOpen
end

-- Counts `screenGui` as a modal while it is Enabled -- the same count, z nudge and teardown as a panel built by
-- Components/ModalScreen.lua. For a surface whose own shape is not a centred panel (the World Architect's docked console, which
-- must leave the world visible) but which still owns the player's input while open. `KeepWorldVisible` keeps Chrome's
-- scrim off while this is the only kind of modal open (see worldVisibleCount).
function ModalCount.Track(scope: Scope, screenGui: ScreenGui, options: { KeepWorldVisible: boolean? }?): ()
	local keepsWorld = options ~= nil and options.KeepWorldVisible == true
	-- Seeded from the CURRENT value rather than assumed closed: every caller mounts with IsOpen false
	-- today, but a screen that mounted already-open would otherwise leave the count one short forever.
	local wasOpen = screenGui.Enabled
	if wasOpen then
		openModalCount += 1
		if keepsWorld then
			worldVisibleCount += 1
		end
		screenGui.DisplayOrder = nextModalOrder()
		noteCountChanged()
	end
	table.insert(
		scope,
		screenGui:GetPropertyChangedSignal("Enabled"):Connect(function()
			wasOpen = trackModalOpenState(screenGui, wasOpen, keepsWorld)
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
			if keepsWorld then
				worldVisibleCount = math.max(worldVisibleCount - 1, 0)
			end
			noteCountChanged()
		end
	end)
end

return ModalCount
