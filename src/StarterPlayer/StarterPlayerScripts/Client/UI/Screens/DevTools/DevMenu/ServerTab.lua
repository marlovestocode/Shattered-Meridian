--!strict
--[[
	DevMenu/ServerTab.lua

	Owns: the Server tab -- the server's own health at a glance, a broadcast to everyone in it,
	moderation of players who are NOT here (look up a UserId's ban, lift it, or ban them), and the two
	lifecycle actions that end the server for everyone.

	STATUS IS THE OVERVIEW POLL, the same answer the roster rail's pulse line reads, laid out in full:
	uptime, population, the server's frame rate and worst frame, memory, version and job. A newer
	published version gets a warning line of its own, because it is the one fact here that asks the
	admin to do something.

	SHUTDOWN AND RESTART ARE ARMED ON THE SERVER, not by Kit.Armed: they take every player with them,
	so the server keeps its own two-press window per admin (DevMenuSystem.needsConfirmation). The
	buttons read ShutdownArmed/RestartArmed, which the driver sets from the server's own
	"ConfirmationRequired" answer -- so a button says "Confirm" exactly while the server would accept
	the confirm, never on the client's say-so.

	Does not own: what any intent does (the driver), or the numbers (the server's).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AdminFormat = require(ReplicatedStorage.Shared.Admin.AdminFormat)
local AdminTypes = require(ReplicatedStorage.Shared.Admin.AdminTypes)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local DropdownModule = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)

local DevMenuTypes = require(script.Parent.Types)
local Kit = require(script.Parent.Kit)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Intent = DevMenuTypes.Intent
type ServerOverview = AdminTypes.ServerOverview

export type ServerTabProps = {
	Visible: UsedAs<boolean>,
	Server: UsedAs<ServerOverview?>,
	BanLookup: UsedAs<AdminTypes.BanLookup?>,
	ShutdownArmed: UsedAs<boolean>,
	RestartArmed: UsedAs<boolean>,
	Fire: (Intent) -> (),
}

local DevMenuConfig = Constants.Debug.DevMenu

local function ServerTab(scope: Scope, props: ServerTabProps): ScrollingFrame
	local announcement = scope:Value("")
	local lookupText = scope:Value("")
	local offlineReason = scope:Value("")
	local offlineDuration = scope:Value("Day")

	local function fact(pick: (ServerOverview) -> string): Fusion.Computed<string>
		return scope:Computed(function(use)
			local server = use(props.Server)
			return if server then pick(server) else "--"
		end)
	end

	local newerVersion = scope:Computed(function(use)
		local server = use(props.Server)
		return server ~= nil and server.LatestPlaceVersion ~= nil and server.LatestPlaceVersion > server.PlaceVersion
	end)

	local lookupUserId = scope:Computed(function(use)
		return AdminFormat.ParseUserId(use(lookupText))
	end)
	local noLookupUserId = scope:Computed(function(use)
		return use(lookupUserId) == nil
	end)
	-- The lookup answer only applies while the field still holds the id it was asked about.
	local lookup = scope:Computed(function(use)
		local answer = use(props.BanLookup)
		return if answer and answer.UserId == use(lookupUserId) then answer else nil
	end)
	local lookupSummary = scope:Computed(function(use)
		local answer = use(lookup)
		if not answer then
			return "Type a UserId and look it up."
		end
		local here = if answer.Online then " They are in this server." else ""
		if not answer.Banned then
			return `{answer.UserId} is not banned.{here}`
		end
		local expiry = if answer.ExpiresAt
			then `expires {AdminFormat.Date(answer.ExpiresAt)} ({AdminFormat.Until(answer.ExpiresAt, os.time())})`
			else "permanent"
		local since = if answer.BannedAt then ` since {AdminFormat.Date(answer.BannedAt)}` else ""
		local by = if answer.BannedByUserId then ` by {answer.BannedByUserId}` else ""
		return `BANNED{since}{by} -- {expiry}. Reason: {answer.BanReason or "none given"}.{here}`
	end)
	local isBanned = scope:Computed(function(use)
		local answer = use(lookup)
		return answer ~= nil and answer.Banned
	end)
	local isNotBanned = scope:Computed(function(use)
		local answer = use(lookup)
		return answer ~= nil and not answer.Banned
	end)

	local banOptions: { DropdownModule.DropdownOption } = {}
	for _, duration in DevMenuConfig.BanDurations do
		table.insert(banOptions, { Value = duration.Key, Text = duration.Label })
	end

	local children: { Instance } = {
		-- Status.
		Kit.Heading(scope, "STATUS", 10),
		Kit.Pair(
			scope,
			11,
			Kit.Group(scope, 1, {
				Kit.Stat(
					scope,
					"Uptime",
					fact(function(server)
						return AdminFormat.Duration(server.UptimeSeconds)
					end),
					1
				),
				Kit.Stat(
					scope,
					"Players",
					fact(function(server)
						return `{server.PlayerCount} / {server.MaxPlayers}`
					end),
					2
				),
				Kit.Stat(
					scope,
					"In combat",
					fact(function(server)
						return tostring(server.EngagedCount)
					end),
					3
				),
				Kit.Stat(
					scope,
					"Open reports",
					fact(function(server)
						return tostring(server.OpenReports)
					end),
					4
				),
				Kit.Stat(
					scope,
					"Flagged players",
					fact(function(server)
						return tostring(server.FlaggedCount)
					end),
					5
				),
			}, nil, 0),
			Kit.Group(scope, 2, {
				Kit.Stat(
					scope,
					"Server frame rate",
					fact(function(server)
						return if server.ServerFps then `{server.ServerFps} fps` else "not published"
					end),
					1,
					nil,
					scope:Computed(function(use)
						local server = use(props.Server)
						return if server
								and server.ServerFps
								and server.ServerFps < 45
							then Tokens.Color.Warning
							else Tokens.Color.TextPrimary
					end)
				),
				Kit.Stat(
					scope,
					"Worst frame",
					fact(function(server)
						return if server.WorstFrameMs then `{server.WorstFrameMs} ms` else "--"
					end),
					2
				),
				Kit.Stat(
					scope,
					"Memory",
					fact(function(server)
						return `{AdminFormat.Count(server.MemoryMb)} MB`
					end),
					3
				),
				Kit.Stat(
					scope,
					"Place version",
					fact(function(server)
						local latest = if server.LatestPlaceVersion
								and server.LatestPlaceVersion > server.PlaceVersion
							then ` (latest v{server.LatestPlaceVersion})`
							else ""
						return `v{server.PlaceVersion}{latest}`
					end),
					4
				),
				Kit.Stat(
					scope,
					"Environment",
					fact(function(server)
						return if server.IsStudio then "Studio" else "Live server"
					end),
					5
				),
			}, nil, 0)
		),
		Kit.Stat(
			scope,
			"Job",
			fact(function(server)
				return if server.JobId == "" then "(local)" else server.JobId
			end),
			12
		),
		Kit.Prose(
			scope,
			"A newer version of the place has been published since this server started. Restart it to move everyone onto the update.",
			13,
			newerVersion,
			Tokens.Color.Warning
		),

		-- Broadcast.
		Kit.Heading(
			scope,
			"BROADCAST",
			20,
			nil,
			scope:Computed(function(use)
				return `{#use(announcement)} / {DevMenuConfig.AnnouncementMaxLength}`
			end)
		),
		TextField(scope, {
			Text = announcement,
			PlaceholderText = "A banner every player in this server sees for a few seconds",
			MaxLength = DevMenuConfig.AnnouncementMaxLength,
			Multiline = true,
			Size = UDim2.new(1, 0, 0, 64),
			LayoutOrder = 21,
		}),
		Kit.Button(scope, {
			Text = "Send to everyone",
			Order = 22,
			Disabled = scope:Computed(function(use)
				return (string.gsub(use(announcement), "%s", "")) == ""
			end),
			OnActivated = function()
				local message = peek(announcement)
				props.Fire({ Kind = "Announce", Message = message })
				announcement:set("")
			end,
		}),

		-- Offline moderation.
		Kit.Heading(scope, "BANS BY USER ID", 30),
		Kit.Prose(scope, "For a player who is not here -- an appeal, a report from another server.", 31),
		Kit.Row(scope, 32, {
			TextField(scope, {
				Text = lookupText,
				PlaceholderText = "UserId",
				MaxLength = 20,
				Size = UDim2.new(2 / 3, -Tokens.Space.S / 3, 1, 0),
				LayoutOrder = 1,
			}),
			Kit.Button(scope, {
				Text = "Look up",
				Order = 2,
				Size = Kit.Cell(3),
				Disabled = noLookupUserId,
				OnActivated = function()
					local userId = peek(lookupUserId)
					if userId then
						props.Fire({ Kind = "LookupBan", UserId = userId })
					end
				end,
			}),
		}),
		Kit.Prose(
			scope,
			lookupSummary,
			33,
			nil,
			scope:Computed(function(use)
				return if use(isBanned) then Tokens.Color.DangerBright else Tokens.Color.TextSecondary
			end)
		),
		Kit.Armed(scope, {
			Idle = "Lift this ban",
			Armed = "Lift the ban? Again",
			Order = 34,
			Visible = isBanned,
			OnConfirm = function()
				local userId = peek(lookupUserId)
				if userId then
					props.Fire({ Kind = "Unban", UserId = userId })
				end
			end,
		}),
		Kit.Group(scope, 35, {
			TextField(scope, {
				Text = offlineReason,
				PlaceholderText = "Reason for the ban",
				MaxLength = 200,
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				LayoutOrder = 1,
			}),
			Kit.Pair(
				scope,
				2,
				DropdownModule.Mount(scope, {
					Label = "Ban for",
					Options = banOptions,
					Value = offlineDuration,
					OnChanged = function(value: string)
						offlineDuration:set(value)
					end,
				}),
				Kit.Group(scope, 1, {
					scope:New "Frame" {
						Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + Tokens.Space.XS),
						BackgroundTransparency = 1,
						LayoutOrder = 1,
					},
					Kit.Armed(scope, {
						Idle = "Ban this user id",
						Armed = "Ban? Again",
						Order = 2,
						Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
						OnConfirm = function()
							local userId = peek(lookupUserId)
							if userId then
								props.Fire({
									Kind = "OfflineBan",
									UserId = userId,
									DurationKey = peek(offlineDuration),
									Reason = peek(offlineReason),
								})
							end
						end,
					}),
				}, nil, Tokens.Space.XS)
			),
		}, isNotBanned),

		-- Lifecycle.
		Kit.Heading(scope, "LIFECYCLE", 40),
		Kit.Prose(
			scope,
			`Both disconnect every player in this server. Shut down warns them for {DevMenuConfig.ShutdownDelaySeconds} seconds first; Restart kicks at once with a "please rejoin" -- for moving a server onto a new version. Each asks for a second press.`,
			41,
			nil,
			Tokens.Color.Warning
		),
		Kit.Row(scope, 42, {
			Kit.Button(scope, {
				Text = scope:Computed(function(use)
					return if use(props.ShutdownArmed) then "Confirm shutdown" else "Shut down server"
				end),
				Order = 1,
				Size = Kit.Cell(2),
				OnActivated = function()
					props.Fire({ Kind = "Shutdown" })
				end,
			}),
			Kit.Button(scope, {
				Text = scope:Computed(function(use)
					return if use(props.RestartArmed) then "Confirm restart" else "Restart now"
				end),
				Order = 2,
				Size = Kit.Cell(2),
				OnActivated = function()
					props.Fire({ Kind = "Restart" })
				end,
			}),
		}),
	}

	return Kit.Page(scope, "ServerTab", props.Visible, children)
end

return ServerTab
