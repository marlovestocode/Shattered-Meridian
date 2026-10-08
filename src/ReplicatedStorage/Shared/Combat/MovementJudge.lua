--!strict
--[[
	MovementJudge.lua

	Owns: the pure arithmetic of Server/Combat/MovementGuard.lua -- given one body's running track, a new position,
	the time and the horizontal speed that body may legitimately cover, is this sample a speed violation, a climb no
	movement allows, or a teleport? No Instances and no clock of its own, so it is specced headless; MovementGuard
	does every read and decides who is judged at all (MovementGuardConstants has the numbers and the reasons).

	Does not own: who is judged or excused, or any consequence of a verdict (MovementGuard).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementGuardConstants = require(ReplicatedStorage.Shared.Combat.MovementGuardConstants)

local MovementJudge = {}

local CONFIG = MovementGuardConstants

-- One body's running sample. Reset whenever the body is excused, so the next window starts from where the
-- server last let it move freely.
export type Track = {
	-- The start of the current speed window.
	WindowPosition: Vector3?,
	WindowStartedAt: number,
	-- The last position the server saw CHANGE, and when -- what a teleport step is judged against.
	LastPosition: Vector3?,
	LastChangeAt: number,
}

export type Verdict = "Ok" | "Speed" | "Rise" | "Teleport"

function MovementJudge.NewTrack(): Track
	return { WindowPosition = nil, WindowStartedAt = 0, LastPosition = nil, LastChangeAt = 0 }
end

function MovementJudge.ResetTrack(track: Track): ()
	track.WindowPosition = nil
	track.WindowStartedAt = 0
	track.LastPosition = nil
	track.LastChangeAt = 0
end

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

-- One sample of `track` at `position`, `now`, against `allowedSpeed` (horizontal studs per second). `judgeRise`
-- false skips the climb check (a parkour action owns the body). Returns the verdict and, for a violation, a short
-- detail for the log and the ledger. Pure: see this file's header.
function MovementJudge.Judge(
	track: Track,
	position: Vector3,
	now: number,
	allowedSpeed: number,
	judgeRise: boolean?
): (Verdict, string?)
	local speedConfig = CONFIG.Speed
	local teleport = CONFIG.Teleport

	local last = track.LastPosition
	if last == nil or track.WindowPosition == nil then
		track.LastPosition = position
		track.LastChangeAt = now
		track.WindowPosition = position
		track.WindowStartedAt = now
		return "Ok", nil
	end

	-- THE TELEPORT STEP, judged over the time since the position last changed (a stall then a catch-up is one
	-- long step, not one impossible frame).
	local step = flat(position - last).Magnitude
	if step > 1e-3 then
		local since = math.max(now - track.LastChangeAt, 1e-3)
		track.LastPosition = position
		track.LastChangeAt = now
		local implied = step / since
		if step >= teleport.MinStuds and implied > allowedSpeed * teleport.SpeedFactor then
			-- A fresh window from here: the jump has been judged, and must not also be judged as speed.
			track.WindowPosition = position
			track.WindowStartedAt = now
			return "Teleport", string.format("%.0f studs in %.2fs (allowed %.0f/s)", step, since, allowedSpeed)
		end
	end

	-- THE SPEED WINDOW.
	local elapsed = now - track.WindowStartedAt
	if elapsed < speedConfig.WindowSeconds then
		return "Ok", nil
	end
	local start = track.WindowPosition :: Vector3
	track.WindowPosition = position
	track.WindowStartedAt = now

	local covered = flat(position - start).Magnitude
	local limit = allowedSpeed * speedConfig.Tolerance * elapsed + speedConfig.SlackStuds
	if covered > limit then
		return "Speed",
			string.format("%.1f studs/s over %.2fs (allowed %.0f/s)", covered / elapsed, elapsed, allowedSpeed)
	end
	local rise = position.Y - start.Y
	if judgeRise ~= false and rise / elapsed > speedConfig.MaxRiseSpeed then
		return "Rise", string.format("rose %.1f studs in %.2fs", rise, elapsed)
	end
	return "Ok", nil
end

return MovementJudge
