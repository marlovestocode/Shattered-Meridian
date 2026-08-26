--!strict
--[[
	Shell/Focus.lua

	Owns: gamepad SELECTION for a panel -- which control is focused when it opens, how the four
	D-pad/stick directions move between its controls, that selection cannot escape the panel into
	one behind it, and what gets focus back when the panel closes.

	Before this module, exactly one of nine panels (Screens/BugReport/init.lua) was navigable with a
	gamepad at all, and it got there by hand-assigning four NextSelection* properties per control --
	twenty-one assignments for eleven controls, every one of which had to name a local that already
	existed, which is why that file's own header explains that every control must be a named local
	rather than an inline child. That wiring is correct today and silently wrong the moment a row is
	added: nothing errors, nothing warns, the new control is simply unreachable. Focus.Group replaces
	it with a graph DERIVED from where the controls actually are.

	BuildGraph BELOW IS PURE, AND TAKES RECTS RATHER THAN INSTANCES, for the same reason
	Input/Analog.lua's ApplyStick takes a Vector2 rather than an InputObject: a headless suite has no
	render pass, so AbsolutePosition/AbsoluteSize on an unrendered GuiObject are not the numbers a
	real screen would produce, and a spec that built real Frames would be asserting against the
	layout engine rather than against this file's traversal rule. Group below reads the rects off
	real Instances and hands them to the same function, so the live path and the spec path cannot
	drift -- the same seam reasoning Shell/Chrome.lua's HandleEscape and Input/InputDevice.lua's
	ResolveDevice already document for themselves.

	THE COST FUNCTION IS DIRECTIONAL DISTANCE PLUS A PERPENDICULAR PENALTY, not nearest-centre.
	Nearest-centre alone makes a wide control one row down lose to a narrow control far to the side
	but marginally closer, which is the failure that makes spatial navigation feel arbitrary. A
	candidate must first be STRICTLY in the direction asked for (its centre beyond ours on that axis,
	by more than a pixel of float noise), and among those the winner minimises
	`along + PERPENDICULAR_PENALTY * across`, where `along` is centre-to-centre on the axis travelled
	and `across` is the GAP BETWEEN THE RECTANGLES on the other one -- so "directly below, further
	away" beats "barely below, far to the left". PERPENDICULAR_PENALTY is 2 rather than 1 because a
	UI laid out in rows and columns wants the axis it was asked for to dominate; at 1 the two axes
	tie and a diagonal neighbour can win a vertical press. See acrossFor below for why that half is
	an edge gap rather than a second centre distance -- it is the difference between a full-width
	field being reachable from the buttons above it and being skipped entirely.

	WRAPPING IS THIS FILE'S OWN, NOT GuiObject.SelectionGroup'S. Setting SelectionGroup = true on the
	root is still done below and still matters -- it is what stops selection escaping into a panel
	underneath -- but its wrap behaviour only applies where the engine is choosing the next control
	itself, and every control in a Group has explicit NextSelection* properties, which take
	precedence. So a direction with no candidate wraps HERE, to the furthest control in the opposite
	direction along the same axis, and a spec can assert it.

	Order IS AN OVERRIDE, NOT THE MECHANISM. Passing it fixes which controls are in the group and in
	what index order they appear to BuildGraph; it does NOT make traversal linear, because the graph
	is still geometric. It exists for the case where the derived set is wrong -- a control that is
	present but should not be reachable, or one mounted outside the root -- not as the normal path.
	Omit it and the group is every visible, selectable GuiButton/TextBox under `root`.

	RESTORING SELECTION ON CLOSE IS GUARDED ON STILL OWNING IT. Screens/BugReport/init.lua's own
	header already stated this rule for the panel-over-panel case ("only if this screen still owns
	whatever is currently selected, so it never steals focus back from some other panel that opened
	in the meantime") and it is preserved exactly: on close, this file writes GuiService.SelectedObject
	only when the current selection is a descendant of ITS root. A panel that closed underneath a
	newer one leaves the newer one's focus alone.

	SELECTION IS ONLY EVER CLAIMED ON A GAMEPAD, AND THAT IS THE WHOLE KEYBOARD/MOUSE REGRESSION
	STORY. Writing GuiService.SelectedObject draws Roblox's selection box around the control, so a
	Group that claimed focus unconditionally would put a highlight on every panel a MOUSE player
	opened -- a visible change to nine screens for players who will never press a D-pad. So the
	graph (the NextSelection* properties) is always applied, because it is inert until something
	navigates, and the SELECTION itself is claimed only while Input/InputDevice.lua reads "Gamepad".
	The device is also watched for as long as the panel is open: picking a pad up mid-panel claims
	focus, and putting it down releases it, so neither leaves the player with a highlight that no
	longer matches what is in their hands.

	ROBLOX'S OWN SELECTION BOX IS DELIBERATELY LEFT ON, even though the interactive primitives now
	light up on SelectionGained themselves (Components/Selection.lua) and the box is therefore
	redundant on any control that went through them. Suppressing it -- a transparent
	SelectionImageObject on each member -- would leave every control that did NOT get that wiring
	(a raw TextBox, a screen that hand-rolls its own button) with no selection feedback of any kind,
	which is a worse failure than a redundant outline and an invisible one to test for. It stays
	until every selectable control in the tree is a migrated primitive.

	DOES NOT OWN ButtonB / "back". That is one press meaning "dismiss the topmost thing", which is
	already Shell/Chrome.lua's Escape stack, and Chrome's own header is explicit that the stack is
	the arbiter and that four independent handlers for one dismissal is the bug it exists to close.
	ButtonB is therefore a second KeyCode on Chrome's OWN existing connection -- one line, in the file
	that already owns the gameProcessed check, the focused-TextBox rule and the ordering -- rather
	than a binding registered here. Registering it here would have made this file a second arbiter of
	dismissal, which is precisely the shape Chrome exists to prevent.

	DOES NOT OWN how a selected control LOOKS. That is each primitive's own business (the shared
	`isSelected` Value folded into the hover Computeds every interactive component already has), per
	docs/ui-ux-philosophy.md's rule that accessibility behaviour is baked into the primitive rather
	than remembered per screen.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Logger = require(ReplicatedStorage.Shared.Logger)

local InputDevice = require(script.Parent.Parent.Parent.Input.InputDevice)

local peek = Fusion.peek

local logger = Logger.scope("Focus")

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

-- An axis-aligned rectangle in absolute screen space. Deliberately NOT a GuiObject -- see file
-- header for why BuildGraph takes these instead.
export type Rect = {
	Position: Vector2,
	Size: Vector2,
}

-- Indices into the same array that was handed to BuildGraph, or nil where a direction leads
-- nowhere at all (a single-control group, or an axis with exactly one occupied row).
export type Edges = {
	Up: number?,
	Down: number?,
	Left: number?,
	Right: number?,
}

export type GroupProps = {
	-- The controls in this group, in the order BuildGraph should index them. Omit to derive the set
	-- from `root`'s own descendants -- see the Order note in this file's header.
	Order: { GuiObject }?,
	-- What receives focus when the panel opens. Defaults to the first control in the group.
	Default: GuiObject?,
	-- The panel's own open state. Focus is claimed on the rising edge and released on the falling
	-- one, exactly like Chrome.BindEscape drives the Escape stack off this same kind of value.
	IsOpen: UsedAs<boolean>,
}

export type GroupHandle = {
	-- Recomputes the graph from the controls' CURRENT rects. Called automatically on layout changes;
	-- exposed for a caller that rebuilds its own children and knows it changed the set.
	Refresh: (self: GroupHandle) -> (),
	-- The group's controls in index order -- a copy, for specs and for a caller that wants to know
	-- what was actually derived.
	Members: (self: GroupHandle) -> { GuiObject },
}

local Focus = {}

-- See the cost-function note in this file's header for why this is 2 and not 1.
local PERPENDICULAR_PENALTY = 2

-- Float noise guard: two controls laid out in the same row can differ by a fraction of a pixel in
-- AbsolutePosition, and "strictly beyond on this axis" must not treat that as a real direction. Both
-- edges of a candidate have to clear this before it counts as being in a direction at all -- see
-- directionSignFor below.
local AXIS_EPSILON = 0.5

type Direction = "Up" | "Down" | "Left" | "Right"

local DIRECTIONS: { Direction } = { "Up", "Down", "Left", "Right" }

local function centreOf(rect: Rect): Vector2
	return rect.Position + rect.Size / 2
end

-- Centre-to-centre distance along the axis a direction travels, positive when `to`'s centre is in
-- that direction. Used for the COST only; whether a candidate counts as being in the direction at
-- all is directionSignFor's job below.
local function alongFor(direction: Direction, from: Vector2, to: Vector2): number
	if direction == "Up" then
		return from.Y - to.Y
	elseif direction == "Down" then
		return to.Y - from.Y
	elseif direction == "Left" then
		return from.X - to.X
	end
	return to.X - from.X
end

-- The two edges of `rect` on the axis `direction` travels, ordered so that "further in the
-- direction" is always "larger".
local function edgesFor(direction: Direction, rect: Rect): (number, number)
	local low, high
	if direction == "Up" or direction == "Down" then
		low, high = rect.Position.Y, rect.Position.Y + rect.Size.Y
	else
		low, high = rect.Position.X, rect.Position.X + rect.Size.X
	end
	if direction == "Up" or direction == "Left" then
		return -high, -low
	end
	return low, high
end

-- +1 when `to` lies in `direction` from `from`, -1 when it lies opposite, 0 when the two are level
-- on this axis and neither is.
--
-- CLASSIFIED FROM EDGES RATHER THAN CENTRES, for the same reason acrossFor measures edges -- and
-- the failure it fixes is the exact mirror of that one. A full-width description field sitting
-- ABOVE a half-width Submit button has a centre further right than Submit's, purely because it is
-- wider, so a centre test reports the field as being "to the right" of Submit -- and Right out of
-- Submit goes UP to the field instead of across to Cancel. Requiring BOTH edges to have moved in
-- the direction asked for means a candidate that merely contains us on this axis is level with us,
-- which is what it actually is.
local function directionSignFor(direction: Direction, from: Rect, to: Rect): number
	local fromLow, fromHigh = edgesFor(direction, from)
	local toLow, toHigh = edgesFor(direction, to)

	if toLow - fromLow > AXIS_EPSILON and toHigh - fromHigh > AXIS_EPSILON then
		return 1
	end
	if toLow - fromLow < -AXIS_EPSILON and toHigh - fromHigh < -AXIS_EPSILON then
		return -1
	end
	return 0
end

-- The gap between two 1-D intervals, or 0 where they overlap at all.
local function gapBetween(minA: number, maxA: number, minB: number, maxB: number): number
	if maxA < minB then
		return minB - maxA
	end
	if maxB < minA then
		return minA - maxB
	end
	return 0
end

-- Separation on the axis the direction does NOT travel -- what the penalty multiplies.
--
-- MEASURED BETWEEN THE RECTANGLES' EDGES, NOT BETWEEN THEIR CENTRES, and the difference is not a
-- refinement -- centres are simply wrong for controls of unequal width. A full-width description
-- field sitting directly under a four-button category row has its centre at the row's midpoint, so
-- centre-distance reports the first category button as far from the field it is DIRECTLY BENEATH,
-- and Down out of that button skips the field entirely and lands on the Submit button below it.
-- (Tests/UI/Focus.spec.lua's bug-report-form case is exactly that layout, and caught exactly that.)
-- Two rects that overlap at all on this axis are "in line" and score 0, which is what makes a wide
-- control reachable from every narrow control above it.
local function acrossFor(direction: Direction, from: Rect, to: Rect): number
	if direction == "Up" or direction == "Down" then
		return gapBetween(from.Position.X, from.Position.X + from.Size.X, to.Position.X, to.Position.X + to.Size.X)
	end
	return gapBetween(from.Position.Y, from.Position.Y + from.Size.Y, to.Position.Y, to.Position.Y + to.Size.Y)
end

-- The pure traversal rule -- see file header. `rects` is indexed 1..n and the returned array is
-- indexed identically, so a caller maps an edge back to its control by index alone.
function Focus.BuildGraph(rects: { Rect }): { Edges }
	local centres: { Vector2 } = table.create(#rects)
	for index, rect in rects do
		centres[index] = centreOf(rect)
	end

	local graph: { Edges } = table.create(#rects)

	for index, fromRect in rects do
		local from = centres[index]
		local edges: Edges = {}

		for _, direction in DIRECTIONS do
			local bestIndex: number? = nil
			local bestCost = math.huge
			-- Tracked in the same pass as the winner so a direction with no candidate can wrap
			-- without a second walk -- see the wrapping note in this file's header.
			local wrapIndex: number? = nil
			local wrapDistance = -math.huge

			for otherIndex, toRect in rects do
				if otherIndex == index then
					continue
				end

				local to = centres[otherIndex]
				local sign = directionSignFor(direction, fromRect, toRect)
				local along = math.abs(alongFor(direction, from, to))
				if sign > 0 then
					local cost = along + PERPENDICULAR_PENALTY * acrossFor(direction, fromRect, toRect)
					-- Strictly less-than, so an exact tie keeps the LOWER index -- which, because
					-- Group hands its members in reading order, means a tie resolves toward the
					-- earlier control. Ties are real (Submit and Cancel are equidistant below a
					-- full-width field) and the rule is arbitrary but must be stable.
					if cost < bestCost then
						bestCost = cost
						bestIndex = otherIndex
					end
				elseif sign < 0 then
					-- Furthest in the OPPOSITE direction, tie-broken toward the nearest across-axis
					-- neighbour so wrapping a column lands back in the same column.
					local distance = along - PERPENDICULAR_PENALTY * acrossFor(direction, fromRect, toRect)
					if distance > wrapDistance then
						wrapDistance = distance
						wrapIndex = otherIndex
					end
				end
			end

			edges[direction] = bestIndex or wrapIndex
		end

		graph[index] = edges
	end

	return graph
end

-- Whether a control belongs in a derived group at all. Visible is checked up the ancestor chain
-- because a control inside a hidden band is not reachable even though its own Visible is true.
local function isSelectableNow(object: Instance, root: GuiObject): boolean
	if not object:IsA("GuiButton") and not object:IsA("TextBox") then
		return false
	end
	local gui = object :: GuiObject
	if not gui.Visible or not gui.Selectable then
		return false
	end

	local ancestor: Instance? = gui.Parent
	while ancestor ~= nil and ancestor ~= root do
		if ancestor:IsA("GuiObject") and not (ancestor :: GuiObject).Visible then
			return false
		end
		ancestor = ancestor.Parent
	end
	return true
end

-- The derived set, in a STABLE order: reading order (top-to-bottom, then left-to-right) rather than
-- GetDescendants' own traversal order, which reflects instance-creation order and would reshuffle
-- the group's indices whenever a screen reordered its children without moving anything on screen.
-- Order only fixes which control gets index 1 (and so the default focus); traversal itself is
-- geometric regardless.
local function deriveMembers(root: GuiObject): { GuiObject }
	local members: { GuiObject } = {}
	for _, descendant in root:GetDescendants() do
		if isSelectableNow(descendant, root) then
			table.insert(members, descendant :: GuiObject)
		end
	end

	table.sort(members, function(a: GuiObject, b: GuiObject): boolean
		local aPosition, bPosition = a.AbsolutePosition, b.AbsolutePosition
		if math.abs(aPosition.Y - bPosition.Y) > AXIS_EPSILON then
			return aPosition.Y < bPosition.Y
		end
		return aPosition.X < bPosition.X
	end)

	return members
end

-- Builds and maintains a selection group over `root`. Returns a handle; a caller that never needs to
-- force a rebuild can discard it.
function Focus.Group(scope: Scope, root: GuiObject, props: GroupProps): GroupHandle
	-- What stops selection escaping into a panel underneath this one. Explicitly NOT what provides
	-- wrapping here -- see the wrapping note in this file's header.
	root.SelectionGroup = true

	local members: { GuiObject } = {}
	-- What was selected before this panel claimed focus, restored on close if this panel still owns
	-- the selection at that point -- see file header.
	local restoreTo: GuiObject? = nil

	local function applyGraph(): ()
		local rects: { Rect } = table.create(#members)
		for index, member in members do
			rects[index] = { Position = member.AbsolutePosition, Size = member.AbsoluteSize }
		end

		local graph = Focus.BuildGraph(rects)
		for index, member in members do
			local edges = graph[index]
			-- Assigned even when nil: a stale edge from a previous layout pointing at a control that
			-- is now hidden or destroyed is worse than no edge, because Roblox will happily select an
			-- invisible control and leave the player with no visible cursor.
			member.NextSelectionUp = if edges.Up then members[edges.Up] else nil
			member.NextSelectionDown = if edges.Down then members[edges.Down] else nil
			member.NextSelectionLeft = if edges.Left then members[edges.Left] else nil
			member.NextSelectionRight = if edges.Right then members[edges.Right] else nil
		end
	end

	local function rebuild(): ()
		members = props.Order or deriveMembers(root)
		applyGraph()
	end

	local handle: GroupHandle = {
		Refresh = function(_self): ()
			rebuild()
		end,
		Members = function(_self): { GuiObject }
			return table.clone(members)
		end,
	}

	rebuild()

	-- A layout pass lands a frame after the children exist, so the rects read during the synchronous
	-- rebuild above are frequently all zero. Recomputing on the root's own AbsoluteSize covers the
	-- first real layout and every resize after it; DescendantAdded/Removing covers a screen that
	-- builds its rows dynamically. All three are deferred into one rebuild rather than run inline,
	-- so a screen adding twenty children costs one graph build and not twenty.
	local rebuildQueued = false
	local function queueRebuild(): ()
		if rebuildQueued then
			return
		end
		rebuildQueued = true
		task.defer(function()
			rebuildQueued = false
			-- The screen may have been torn down between the defer and here.
			if root.Parent == nil then
				return
			end
			rebuild()
		end)
	end

	table.insert(scope, root:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueRebuild))
	table.insert(scope, root.DescendantAdded:Connect(queueRebuild))
	table.insert(scope, root.DescendantRemoving:Connect(queueRebuild))

	local function claimFocus(): ()
		-- See the gamepad-only note in this file's header: the graph is always live, the SELECTION is
		-- not.
		if InputDevice.Current() ~= "Gamepad" then
			return
		end

		rebuild()

		local current = GuiService.SelectedObject
		-- Only remember a selection that is NOT already ours -- reopening a panel that never released
		-- focus would otherwise record one of its own controls as the thing to restore to.
		if current == nil or not current:IsDescendantOf(root) then
			restoreTo = current
		end

		local target = props.Default or members[1]
		if target == nil then
			logger:debug("Focus group opened with no selectable members", { root = root.Name })
			return
		end
		GuiService.SelectedObject = target
	end

	local function releaseFocus(): ()
		local current = GuiService.SelectedObject
		-- Guarded on still owning it -- see file header. A panel closed underneath a newer one must
		-- not yank the newer one's focus away.
		if current ~= nil and not current:IsDescendantOf(root) then
			return
		end
		GuiService.SelectedObject = restoreTo
		restoreTo = nil
	end

	local function sync(): ()
		if peek(props.IsOpen) then
			claimFocus()
		else
			releaseFocus()
		end
	end

	-- A pad picked up or put down while this panel is already open -- see the gamepad-only note in
	-- this file's header. Nothing happens for a closed panel, so every panel in the tree can hold
	-- this subscription cheaply.
	table.insert(
		scope,
		InputDevice.OnChanged(function()
			if not peek(props.IsOpen) then
				return
			end
			if InputDevice.Current() == "Gamepad" then
				claimFocus()
			else
				releaseFocus()
			end
		end)
	)

	-- Before the Observer as well as after it, for the reason Chrome.BindEscape documents: a Lazy
	-- screen resolves its handle on first open, so this is frequently called with the panel already
	-- open, and waiting for the next change would leave that first opening unfocused.
	sync()
	scope:Observer(props.IsOpen):onChange(sync)

	return handle
end

return Focus
