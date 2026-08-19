--!strict
--[[
	CharacterUtil.lua

	Owns: the small set of "find this Model's/Player's Humanoid or HumanoidRootPart" Instance lookups
	that were independently hand-duplicated across seven call sites before this existed
	(Combat/Damage/DamageSystem.lua, Combat/Grab/GrabSystem.lua, Systems/AdminActionSystem.lua,
	Systems/EmoteSystem.lua, Systems/ParkourSystem.lua x2, Systems/DevMenuSystem.lua) -- pure Instance
	plumbing with no client/server-authoritative distinction, the same reasoning AnimatorUtil.lua
	already establishes for its own single shared lookup.

	HumanoidOf/RootOf take whichever a caller already has in hand (some hold a Model from a hit/grab
	resolution, some only ever have a Player); LiveRig is the Player-rooted convenience the majority
	of call sites actually want. None of these filter on Health -- see LiveHumanoidOf's own header for
	the one place that distinction matters and why it stays a separate, explicitly-named function
	rather than a hidden default.

	Does not own: any Player-authorization/whitelist check (every prior call site already applied its
	own before reaching this point, and this module has no way to know which caller's rules apply),
	or logging a rejection reason -- DevMenuSystem.lua's own getRootPart wraps RootOf for that.
]]

local CharacterUtil = {}

-- `model`'s Humanoid, or nil if it has none. No Health filter -- a dead Humanoid is still returned,
-- since most callers (AdminActionSystem, EmoteSystem, ParkourSystem) want the Instance regardless of
-- whether the character is currently alive. See LiveHumanoidOf below for the filtered version.
function CharacterUtil.HumanoidOf(model: Model): Humanoid?
	return model:FindFirstChildOfClass("Humanoid")
end

-- `model`'s Humanoid, filtered to exclude one that has already died (Health <= 0). DamageSystem.lua
-- and GrabSystem.lua both want this specifically: a hit/grab resolving against a body mid-death
-- animation should not find a combat-legal target in it, even though the Humanoid Instance itself is
-- still there until the character despawns.
function CharacterUtil.LiveHumanoidOf(model: Model): Humanoid?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return if humanoid and humanoid.Health > 0 then humanoid else nil
end

-- `model`'s HumanoidRootPart, or nil if it's missing or not a BasePart (a character mid-respawn can
-- briefly have neither).
function CharacterUtil.RootOf(model: Model): BasePart?
	local rootPart = model:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

-- `player`'s current character, Humanoid, and HumanoidRootPart in one call -- the shape most Player-
-- rooted callers actually want, rather than three separate nil-checked lookups. Any of the three may
-- come back nil independently (no character at all; a character with no Humanoid yet; one with no
-- HumanoidRootPart yet) -- callers check whichever of the three they need.
function CharacterUtil.LiveRig(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	return character, CharacterUtil.HumanoidOf(character), CharacterUtil.RootOf(character)
end

return CharacterUtil
