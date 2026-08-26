--!strict
--[[
	WheelSelection.lua

	Owns: every angle/geometry computation the radial emote wheel needs -- which of N equal sectors
	the cursor currently sits nearest to (GetSelectedIndex), where a given sector sits on the circle
	(GetSegmentPosition/GetSegmentAngle), the two helpers the dial's live needle needs to track a
	moving cursor without spinning the long way round the circle (GetCursorAngle/UnwrapAngle), and the
	one conversion that lets a gamepad aim the same wheel a mouse does (CursorFromStick). Kept in
	one pure, Instance-free module (no Fusion, no Players, no UserInputService) so WheelSegment.lua/
	WheelDial.lua/init.lua never do their own trig, and so this math is directly TestEZ-testable with
	no ScreenGui/mouse/camera involved -- see WheelSelection.spec.lua.

	Segment 1 is centered at 12 o'clock ("up"), and segments proceed CLOCKWISE from there, matching
	this feature's own design brief ("top slot first"). segmentCount is always taken as a parameter,
	never assumed to be EmoteConstants.LoadoutSize -- see that constant's own header on why the wheel
	must read the real loadout length at render/selection time, and this module is exactly where a
	future change to that count would first need to keep working correctly without a code change here.

	Screen-space convention: Y increases downward (Roblox GuiObject convention), so "up" is -Y. Every
	Vector2 here is in that same screen-space, offset-pixel coordinate system -- callers convert to/
	from GuiObject Position/AnchorPoint (or the real mouse position) themselves.

	THE DEAD ZONE (2026-08-26). GetSelectedIndex takes an optional inner radius below which it reports
	no selection at all. Before it existed, ANY offset from center -- one pixel, the sub-pixel jitter
	of a cursor that has not really moved -- resolved to some segment, so the wheel was never in a
	"nothing chosen" state and a player who tapped the key and released performed whichever emote the
	cursor happened to be pointing at. That is now a real state: the hub renders its own prompt while
	the cursor is inside it, and releasing there cancels. The radius is the caller's number (the hub's
	own drawn radius, so the affordance and the behaviour are the same circle) and defaults to 0,
	which is exactly the old behaviour for any caller that omits it.

	ANGLE UNWRAPPING. The needle on the dial is a spring chasing the cursor's angle, and a spring
	interpolates through the number line, not around a circle: handed 6.2 rad one frame and 0.1 rad
	the next (a cursor crossing 12 o'clock), it sweeps the whole 6.1 rad the wrong way round instead
	of the 0.18 rad the cursor actually travelled. UnwrapAngle is the fix and lives here rather than in
	the client module because it is exactly this file's kind of thing -- pure, wrap-aware trig with a
	test that can state the crossing case directly.

	Does not own: any Instance, GuiObject, mouse polling, camera/MouseBehavior state, or Fusion state
	-- WheelSegment.lua/WheelDial.lua/init.lua/EmoteWheelClient.lua call into this module with plain
	numbers/Vector2s and do all rendering/input handling themselves.
]]

local WheelSelection = {}

local TAU = 2 * math.pi

WheelSelection.TAU = TAU

-- Angle (radians, [0, TAU)) of `offset` measured clockwise from "up" (-Y). atan2(x, -y) is exactly
-- that: at offset = (0, -1) ("up") this is atan2(0, 1) = 0; at offset = (1, 0) ("right", 90 degrees
-- clockwise from up) this is atan2(1, 0) = pi/2. Wrapped into [0, TAU) since atan2 returns (-pi, pi].
local function angleFromUpClockwise(offset: Vector2): number
	local angle = math.atan2(offset.X, -offset.Y)
	if angle < 0 then
		angle += TAU
	end
	return angle
end

-- The angle (radians, clockwise from "up") at which segment `index` (1-based) of `segmentCount`
-- equal sectors is centered. Returns 0 for a non-positive segmentCount, matching GetSegmentPosition's
-- own defensive return below rather than erroring.
function WheelSelection.GetSegmentAngle(index: number, segmentCount: number): number
	if segmentCount <= 0 then
		return 0
	end
	return (index - 1) * (TAU / segmentCount)
end

-- The screen-space offset (from the wheel's own center) of segment `index` (1-based) out of
-- `segmentCount` equal sectors -- see this file's header for the "segment 1 is up, clockwise"
-- layout. Returns Vector2.zero for a non-positive segmentCount (nothing to place) rather than
-- erroring, the same defensive-decode reflex this codebase's own parsers apply to any input that
-- can't be trusted to be well-formed (see e.g. EmoteRegistry.Validate's own header).
function WheelSelection.GetSegmentPosition(index: number, segmentCount: number, radius: number): Vector2
	if segmentCount <= 0 then
		return Vector2.zero
	end
	local angle = WheelSelection.GetSegmentAngle(index, segmentCount)
	return Vector2.new(radius * math.sin(angle), -radius * math.cos(angle))
end

-- The raw angle (radians, [0, TAU), clockwise from "up") the cursor currently sits at relative to
-- the wheel's center -- nil when the cursor is exactly on center and there is therefore no direction
-- to report. Deliberately NOT deadzone-aware: the needle keeps pointing where the player is pointing
-- even while the offset is too small to commit to a segment, and it is the caller that decides
-- whether to show it (init.lua fades the needle out on a nil SelectedIndex).
function WheelSelection.GetCursorAngle(center: Vector2, cursor: Vector2): number?
	local offset = cursor - center
	if offset.Magnitude == 0 then
		return nil
	end
	return angleFromUpClockwise(offset)
end

-- `angle` shifted by whole turns to whichever equivalent value sits nearest `previous`, so a
-- continuously-updated angle stream never jumps a full turn when it crosses the 0/TAU seam. Feeding
-- the result back in as the next call's `previous` accumulates freely (it is NOT re-wrapped into
-- [0, TAU)), which is the point -- see this file's header.
function WheelSelection.UnwrapAngle(previous: number, angle: number): number
	local delta = (angle - previous) % TAU
	if delta > math.pi then
		delta -= TAU
	end
	return previous + delta
end

-- Pixels past the dead zone at which CursorFromStick places its synthesised cursor.
-- Any positive value resolves the same segment (GetSelectedIndex reads the DIRECTION, and only tests
-- the distance against the dead zone), so this is deliberately the smallest unambiguously-outside
-- one rather than a second radius somebody could mistake for layout.
local STICK_CURSOR_REACH = 1

-- A gamepad thumbstick's throw, expressed as a cursor position the two functions above already
-- understand -- so a controller selects through the SAME selection rule the mouse does, rather than
-- through a parallel angle-to-index path that could drift from it.
--
-- Y IS NEGATED. A thumbstick reports +Y as up; screen space (and every Vector2 in this file) has +Y
-- going down. Without the flip, a wheel would select the segment OPPOSITE the one the player is
-- pushing toward -- which reads in play as "the gamepad is inverted" rather than as a sign error.
--
-- A stick inside `threshold` returns `center` itself, and both readers already handle that exactly
-- right: GetSelectedIndex reports no selection at zero distance and GetCursorAngle reports no angle,
-- so the needle holds wherever it last pointed instead of snapping to 12 o'clock. That threshold is
-- the caller's number, not this file's, because it is an INPUT tuning (how hard a stick must be
-- pushed) rather than a geometric one -- see EmoteWheelClient.STICK_SELECT_THRESHOLD.
function WheelSelection.CursorFromStick(
	center: Vector2,
	stick: Vector2,
	deadZoneRadius: number,
	threshold: number
): Vector2
	local direction = Vector2.new(stick.X, -stick.Y)
	if direction.Magnitude < threshold then
		return center
	end
	return center + direction.Unit * (deadZoneRadius + STICK_CURSOR_REACH)
end

-- The 1-based index of whichever of `segmentCount` equal sectors `cursor` is nearest to, given the
-- wheel's `center` -- nil when there's no meaningful direction (segmentCount <= 0, cursor sits
-- exactly on center, or cursor sits inside the optional `deadZoneRadius`; see this file's header on
-- that last one). Never called with a smoothed/averaged cursor position -- EmoteWheelClient.lua
-- feeds this the raw current mouse position on every relevant InputChanged, and this function alone
-- decides which segment that resolves to.
function WheelSelection.GetSelectedIndex(
	center: Vector2,
	cursor: Vector2,
	segmentCount: number,
	deadZoneRadius: number?
): number?
	if segmentCount <= 0 then
		return nil
	end
	local offset = cursor - center
	local distance = offset.Magnitude
	if distance == 0 or distance < (deadZoneRadius or 0) then
		return nil
	end

	local anglePerSegment = TAU / segmentCount
	local angle = angleFromUpClockwise(offset)
	-- Nearest segment center: round to the nearest multiple of anglePerSegment, then wrap into
	-- [0, segmentCount) so a cursor angle just past the wrap point (e.g. just short of 360 degrees,
	-- segment 1's other edge) still resolves to segment 1 instead of an out-of-range index.
	local rawIndex = math.floor(angle / anglePerSegment + 0.5) % segmentCount
	return rawIndex + 1
end

return WheelSelection
