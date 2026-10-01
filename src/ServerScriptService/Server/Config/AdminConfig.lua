--!strict
--[[
	AdminConfig.lua

	Owns: the dev-menu authorization whitelist -- the single list of Roblox UserIds allowed to open
	the dev menu and invoke its admin actions.

	Lives under ServerScriptService/Server/Config/ rather than ReplicatedStorage/Shared/Constants.lua
	specifically so it does NOT replicate. It previously sat in Constants.Debug.DevMenu, which put the
	exact roster of privileged accounts in every client's ReplicatedStorage, readable by anyone who
	opened a Roblox instance explorer. That was never a privilege escalation -- DevMenuSystem.lua
	re-checks every request's Player.UserId server-side and always has, which is the only thing
	authorization has ever rested on -- but publishing "here are the accounts worth attacking" bought
	nothing and cost real information. ServerScriptService is not replicated to clients, so a require
	from a client script is impossible rather than merely discouraged.

	Does not own: the authorization CHECK (DevMenuSystem.lua's isAuthorized), rate limiting, or any
	dev-menu behavior -- this module is data only, deliberately with no functions, so there is exactly
	one place to edit when someone joins or leaves the team.

	Client note: DevMenuClient.lua can no longer read this list to decide whether to start itself.
	It asks the server instead, over the DevMenu_GetOverview RemoteFunction the panel polls anyway, at
	startup -- see that file's own Start() header. A rejection from any DevMenuSystem handler is the
	authorization answer; no separate "am I an admin" remote exists or is needed.
]]

local AdminConfig = {}

-- Roblox UserIds allowed to open the dev menu and use its actions. Empty by default would fail
-- closed (nobody authorized until explicitly populated). Add your own UserId (and any testers')
-- here, e.g. [123456789] = true. Never guess or invent a UserId.
AdminConfig.AuthorizedUserIds = {
	[3888090557] = true, -- marquis
	[2620785150] = true, -- domingo
	[5123402196] = true, -- miraj
	[846436815] = true, -- dink
	[1785892535] = true, -- jay
	[4689336404] = true, -- chris
} :: { [number]: boolean }

return AdminConfig
