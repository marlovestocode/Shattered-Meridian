--!strict
--[[
	BountyMenu.lua

	Owns: the bounty board panel inside Screens/Menus -- the ranked list of players currently
	carrying a Notoriety bounty, what each is worth, and which row is the player themselves.

	Renders live server data only. This file previously seeded itself with `createDemoBounty`
	fabricated rows and hand-copied BountySystem's six reward constants into its own `computeReward`
	-- docs/architecture/2026-08-audit.md section 5.1 flagged that duplication and recommended
	extracting a Shared/BountyMath.lua so client and server shared one source of truth. That
	extraction is deliberately NOT what happened here, because the better fix was available once the
	board became real: the server now computes each reward and sends it in
	Types.BountyBoardEntry, so this file does no reward math at all. A formula that crosses no
	boundary needs no shared module -- the duplication was deleted rather than relocated.

	Data flow, both halves of which are needed: an initial Bounty_GetActiveBounties invoke on mount
	(so an opened menu is populated immediately rather than blank until something happens), plus a
	Bounty_BoardUpdated subscription for every subsequent change. Neither alone is sufficient -- pull
	only would go stale while open, push only would show nothing until the next kill.

	Does not own: whether the player themselves is marked (ClientState.BountyMarked, which the hotbar
	badge also reads -- see ClientState.lua's header on why that one is shared state and this board
	is not), or any placement action. There is no "place bounty" control here and adding one would be
	a design change: bounties are server-placed, see BountyConstants.lua's header.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local BountyConstants = require(ReplicatedStorage.Shared.BountyConstants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Parent.Components.Label)

local logger = Logger.scope("BountyMenu")

type Scope = Fusion.Scope<typeof(Fusion)>

local BountyMenu = {}

local ROW_HEIGHT = 64

-- One board row. `isSelf` drives the only per-row styling decision: the player's own bounty is drawn
-- in the Danger register the hotbar badge already uses for the same fact, so the two surfaces agree
-- rather than each inventing their own language for "this one is you."
local function bountyRow(scope: Scope, entry: Types.BountyBoardEntry, rank: number, isSelf: boolean): Frame
	local accent = if isSelf then Tokens.Color.Danger else Tokens.Color.AccentPrimary

	return Panel(scope, {
		Name = `BountyRow_{entry.BountyId}`,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		LayoutOrder = rank,
		Elevated = isSelf,
		BorderColor3 = accent,
		BorderTransparency = if isSelf then 0.2 else 0.6,

		Children = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.S),
				PaddingBottom = UDim.new(0, Tokens.Space.S),
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = if isSelf then `{rank}. {entry.TargetName}  (you)` else `{rank}. {entry.TargetName}`,
				Scale = "BodyLarge",
				Color = if isSelf then Tokens.Color.Danger else Tokens.Color.TextPrimary,
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = `Tier {entry.TargetTier}  |  {entry.Streak} kill streak  |  {entry.Reward} Meridian XP`,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 2,
			}),
		},
	}) :: Frame
end

local function emptyState(scope: Scope): Frame
	return scope:New "Frame" {
		Name = "EmptyState",
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = 1,

		[Fusion.Children] = Label(scope, {
			-- States the rule rather than just reporting emptiness -- an empty board is the normal
			-- resting state of this system, so "none right now" alone would read as broken.
			Text = `No bounties. A bounty appears when someone reaches a {BountyConstants.NotorietyStreakThreshold}-kill streak.`,
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			Size = UDim2.fromScale(1, 0),
			AutoHeight = true,
			LineHeight = Tokens.Leading.Prose,
		}),
	} :: Frame
end

function BountyMenu.Mount(scope: Scope, width: number, height: number): Frame
	local entries: Fusion.Value<{ Types.BountyBoardEntry }> = scope:Value({})
	local localUserId = Players.LocalPlayer.UserId

	local function applyEntries(incoming: unknown): ()
		if typeof(incoming) ~= "table" then
			logger:warn("Malformed bounty board payload ignored", { payload = tostring(incoming) })
			return
		end
		local validated: { Types.BountyBoardEntry } = {}
		for _, raw in ipairs(incoming :: { any }) do
			-- Validated at the boundary for the same reason ClientState.Bootstrap validates its own
			-- payloads: the Types annotation is not enforced across a remote, and one malformed row
			-- should be dropped rather than erroring inside a Fusion ForPairs and taking the whole
			-- board down with it.
			if
				typeof(raw) == "table"
				and typeof(raw.BountyId) == "string"
				and typeof(raw.TargetName) == "string"
				and typeof(raw.TargetUserId) == "number"
				and typeof(raw.TargetTier) == "number"
				and typeof(raw.Streak) == "number"
				and typeof(raw.Reward) == "number"
			then
				table.insert(validated, raw :: Types.BountyBoardEntry)
			end
		end
		entries:set(validated)
	end

	-- Push: every change from here on.
	local boardUpdated = NetworkBridge.GetRemoteEvent(BountyConstants.RemoteNames.BoardUpdated)
	boardUpdated.OnClientEvent:Connect(function(payload: Types.BountyBoardUpdatePayload)
		if typeof(payload) ~= "table" then
			logger:warn("Malformed Bounty_BoardUpdated payload ignored", { payload = tostring(payload) })
			return
		end
		applyEntries(payload.Entries)
	end)

	-- Pull: the current board, once, so an opened menu isn't blank until the next kill. Wrapped in
	-- pcall and spawned off the mount path -- a RemoteFunction invoke yields and can throw if the
	-- server drops it, and neither is a reason for the whole UI mount to fail.
	task.spawn(function()
		local getActive = NetworkBridge.GetRemoteFunction(BountyConstants.RemoteNames.GetActiveBounties)
		local ok, result = pcall(function()
			return getActive:InvokeServer()
		end)
		if not ok then
			logger:warn("Initial bounty board fetch failed", { error = tostring(result) })
			return
		end
		applyEntries(result)
	end)

	local rows = scope:ForPairs(entries, function(_use, innerScope, index, entry: Types.BountyBoardEntry)
		return entry.BountyId, bountyRow(innerScope, entry, index, entry.TargetUserId == localUserId)
	end)

	local hasEntries = scope:Computed(function(use)
		return #use(entries) > 0
	end)

	return Panel(scope, {
		Name = "BountyMenu",
		Size = UDim2.fromOffset(width, height),
		AutomaticSize = Enum.AutomaticSize.None,
		Children = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.M),
				PaddingBottom = UDim.new(0, Tokens.Space.M),
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = "Bounty Board",
				Scale = "Heading",
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = "Marked by the server. Ranked by what they pay.",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 2,
			}),
			-- The empty state and the list are mutually exclusive, driven off the same one Computed
			-- rather than each deciding independently -- so there is no frame in which both or neither
			-- renders.
			scope:New "Frame" {
				Name = "EmptySlot",
				Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 3,
				Visible = scope:Computed(function(use)
					return not use(hasEntries)
				end),

				[Fusion.Children] = emptyState(scope),
			},
			scope:New "Frame" {
				Name = "Rows",
				Size = UDim2.new(1, 0, 1, -80),
				BackgroundTransparency = 1,
				LayoutOrder = 4,
				Visible = hasEntries,

				[Fusion.Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Left,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					rows,
				},
			},
		},
	}) :: Frame
end

return BountyMenu
