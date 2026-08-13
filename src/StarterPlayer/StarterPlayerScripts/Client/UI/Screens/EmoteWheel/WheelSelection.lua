--!strict
--[[
	WheelSelection.lua

	Owns: every angle/geometry computation the radial emote wheel needs -- which of N equal sectors
	the cursor currently sits nearest to (GetSelectedIndex) and where a given sector sits on the
	circle (GetSegmentPosition). Kept in one pure, Instance-free module (no Fusion, no Players, no
	UserInputService) so WheelSegment.lua/init.lua never do their own trig, and so this math is
	directly TestEZ-testable with no ScreenGui/mouse/camera involved -- see WheelSelection.spec.lua.

	Segment 1 is centered at 12 o'clock ("up"), and segments proceed CLOCKWISE from there, matching
	this feature's own design brief ("top slot first"). segmentCount is always taken as a parameter,
	never assumed to be EmoteConstants.LoadoutSize -- see that constant's own header on why the wheel
	must read the real loadout length at render/selection time, and this module is exactly where a
	future change to that count would first need to keep working correctly without a code change here.

	Screen-space convention: Y increases downward (Roblox GuiObject convention), so "up" is -Y. Every
	Vector2 here is in that same screen-space, offset-pixel coordinate system -- callers convert to/
	from GuiObject Position/AnchorPoint (or the real mouse position) themselves.

	Does not own: any Instance, GuiObject, mouse polling, camera/MouseBehavior state, or Fusion state
	-- WheelSegment.lua/init.lua/EmoteWheelClient.lua call into this module with plain numbers/
	Vector2s and do all rendering/input handling themselves.
]]

local WheelSelection = {}

local TAU = 2 * math.pi

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

-- The screen-space offset (from the wheel's own center) of segment `index` (1-based) out of
-- `segmentCount` equal sectors -- see this file's header for the "segment 1 is up, clockwise"
-- layout. Returns Vector2.zero for a non-positive segmentCount (nothing to place) rather than
-- erroring, the same defensive-decode reflex this codebase's own parsers apply to any input that
-- can't be trusted to be well-formed (see e.g. EmoteRegistry.Validate's own header).
function WheelSelection.GetSegmentPosition(index: number, segmentCount: number, radius: number): Vector2
	if segmentCount <= 0 then
		return Vector2.zero
	end
	local anglePerSegment = TAU / segmentCount
	local angle = (index - 1) * anglePerSegment
	return Vector2.new(radius * math.sin(angle), -radius * math.cos(angle))
end

-- The 1-based index of whichever of `segmentCount` equal sectors `cursor` is nearest to, given the
-- wheel's `center` -- nil when there's no meaningful direction (segmentCount <= 0, or cursor sits
-- exactly on center). Never called with a smoothed/averaged cursor position -- EmoteWheelClient.lua
-- feeds this the raw current mouse position on every relevant InputChanged, and this function alone
-- decides which segment that resolves to.
function WheelSelection.GetSelectedIndex(center: Vector2, cursor: Vector2, segmentCount: number): number?
	if segmentCount <= 0 then
		return nil
	end
	local offset = cursor - center
	if offset.Magnitude == 0 then
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
