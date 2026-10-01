--!strict
--[[
	Admin/AdminFormat.lua

	Owns: turning the admin panel's raw wire values (Shared/Admin/AdminTypes.lua) into the text the
	panel shows -- durations, counts, pings, dates, positions, and the short flag words a roster row
	carries. Pure functions of their arguments (the clock is always passed in), so every rule here is
	pinned by Tests/Admin/AdminFormat.spec.lua rather than by opening the panel.

	Lives in Shared rather than beside the screen because the driver (Client/DevTools/DevMenu/
	DevMenuClient.lua) and the screen both format, and a spec needs to reach it from the test place.

	Does not own: what any of these values mean, or which of them are shown where.
]]

local AdminTypes = require(script.Parent.AdminTypes)

local AdminFormat = {}

-- "4d 2h", "2h 14m", "3m 05s", "12s". Two units at most: a duration on this panel answers "how long,
-- roughly", and a third unit is noise at every scale.
function AdminFormat.Duration(seconds: number): string
	local whole = math.max(0, math.floor(seconds))
	local days = whole // 86400
	local hours = (whole % 86400) // 3600
	local minutes = (whole % 3600) // 60
	local secs = whole % 60
	if days > 0 then
		return `{days}d {hours}h`
	elseif hours > 0 then
		return `{hours}h {minutes}m`
	elseif minutes > 0 then
		return string.format("%dm %02ds", minutes, secs)
	end
	return `{secs}s`
end

-- "12,345". Whole numbers only; a fraction is rounded, since every count here is a count.
function AdminFormat.Count(value: number): string
	local rounded = math.floor(value + 0.5)
	local negative = rounded < 0
	local digits = tostring(math.abs(rounded))
	local grouped = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return if negative then "-" .. grouped else grouped
end

function AdminFormat.Ping(ms: number): string
	return `{math.floor(ms + 0.5)} ms`
end

-- "123 / 500".
function AdminFormat.Pair(current: number, maximum: number): string
	return `{math.floor(current + 0.5)} / {math.floor(maximum + 0.5)}`
end

-- "0.42" -> "42%".
function AdminFormat.Percent(fraction: number): string
	return `{math.floor(math.clamp(fraction, 0, 1) * 100 + 0.5)}%`
end

-- "2026-09-29 14:02", in the viewer's local time.
function AdminFormat.Date(timestamp: number): string
	return os.date("%Y-%m-%d %H:%M", timestamp) :: string
end

function AdminFormat.Position(position: Vector3): string
	return string.format(
		"%d, %d, %d",
		math.floor(position.X + 0.5),
		math.floor(position.Y + 0.5),
		math.floor(position.Z + 0.5)
	)
end

-- "in 3d 4h" / "expired". `now` is passed in (os.time() at the caller) so this stays pure.
function AdminFormat.Until(timestamp: number, now: number): string
	local remaining = timestamp - now
	if remaining <= 0 then
		return "expired"
	end
	return `in {AdminFormat.Duration(remaining)}`
end

-- The short words a roster row appends after its tier and ping, most consequential first. Words, not
-- colours alone (docs/ui-ux-philosophy.md): the row tints them, but "FROZEN" still reads as frozen on
-- a monitor that renders the tint as grey.
function AdminFormat.RosterFlags(entry: AdminTypes.RosterEntry): { string }
	local flags: { string } = {}
	if not entry.Alive then
		table.insert(flags, "DEAD")
	end
	if entry.InCombat then
		table.insert(flags, "COMBAT")
	end
	if entry.Flagged then
		table.insert(flags, "FLAGGED")
	end
	if entry.Muted then
		table.insert(flags, "MUTED")
	end
	if entry.Godmode then
		table.insert(flags, "GOD")
	end
	if entry.Flying then
		table.insert(flags, "FLY")
	end
	if entry.Frozen then
		table.insert(flags, "FROZEN")
	end
	if entry.Invisible then
		table.insert(flags, "HIDDEN")
	end
	if entry.SpeedMultiplier ~= 1 then
		table.insert(flags, `x{entry.SpeedMultiplier}`)
	end
	if entry.Marked then
		table.insert(flags, "BOUNTY")
	end
	return flags
end

-- Case-insensitive match of a roster filter against every name a player goes by, and their UserId --
-- an admin working a report has whichever one the reporter typed.
function AdminFormat.RosterMatches(entry: AdminTypes.RosterEntry, filter: string): boolean
	local query = string.lower((string.gsub(filter, "^%s+", "")))
	query = (string.gsub(query, "%s+$", ""))
	if query == "" then
		return true
	end
	local haystack = string.lower(`{entry.Name} {entry.DisplayName} {entry.CharacterName or ""} {entry.UserId}`)
	return string.find(haystack, query, 1, true) ~= nil
end

-- Reads a typed UserId. nil for anything that is not a plausible one -- the server re-validates.
function AdminFormat.ParseUserId(text: string): number?
	local trimmed = (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", ""))
	if not string.match(trimmed, "^%d+$") then
		return nil
	end
	local value = tonumber(trimmed)
	if not value or value <= 0 or value >= 2 ^ 53 then
		return nil
	end
	return value
end

return AdminFormat
