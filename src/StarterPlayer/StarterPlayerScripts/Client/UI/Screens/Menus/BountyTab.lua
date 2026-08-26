--!strict
--[[
	BountyTab.lua

	Owns: the bounty board tab inside the character menu -- the ranked list of players currently
	carrying a Notoriety bounty, what each is worth, and which row is the player themselves.

	Was BountyMenu.lua, when this whole screen WAS the bounty board and nothing else. It is now one
	tab of four (see Screens/Menus/init.lua), which is why it renders a plain transparent Frame
	rather than its own Panel -- the menu root already draws the frame around everything.

	Its rows DO carry a 1px edge (added 2026-08-20, same pass as ArtsTab's). They previously relied on
	a fill alone, which over the panel's own surface texture gave a two-line entry no readable
	boundary; a board of three marks read as six loose lines of text.

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
	badge and the identity rail also read -- see ClientState.lua's header on why that one is shared
	state and this board is not), or any placement action. There is no "place bounty" control here
	and adding one would be a design change: bounties are server-placed, see BountyConstants.lua's
	header.

	Keeps its OWN remote wiring, unlike the Character/Arts tabs beside it, which read Values that
	Client/CharacterMenu/CharacterMenuClient.lua fills from outside. That is a deliberate asymmetry,
	not an oversight: those two tabs have actions (unlock, equip) whose requests need a driver that
	owns retry/status/refetch, where this one is a pure read whose two remotes it has always owned
	and which nothing outside it consumes. Moving it would add an indirection hop with no second
	consumer to justify it -- the same rule ClientState.lua's own header applies to deciding what
	belongs in shared state.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local BountyConstants = require(ReplicatedStorage.Shared.BountyConstants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local ScrollArea = require(script.Parent.Parent.Parent.Components.ScrollArea)
local SectionHeading = require(script.Parent.Parent.Parent.Components.SectionHeading)
local StatusTag = require(script.Parent.Parent.Parent.Components.StatusTag)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)

local Children = Fusion.Children

local logger = Logger.scope("BountyMenu")

type Scope = Fusion.Scope<typeof(Fusion)>

local BountyTab = {}

export type BountyTabProps = {
	Width: number,
	Height: number,
	Visible: Fusion.UsedAs<boolean>,
	LayoutOrder: number,
}

local HINT_HEIGHT = 20
local GAP = Tokens.Space.S
local ROW_HEIGHT = 64
local ROW_PADDING_X = Tokens.Space.M
local REWARD_WIDTH = 110

-- One board row. `isSelf` drives the only per-row styling decision: the player's own bounty is drawn
-- in the Danger register the hotbar badge already uses for the same fact, so the two surfaces agree
-- rather than each inventing their own language for "this one is you."
local function bountyRow(scope: Scope, entry: Types.BountyBoardEntry, rank: number, isSelf: boolean): Frame
	local accent = if isSelf then Tokens.Color.Danger else Tokens.Border.Standard.Color

	local metaChildren: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Tokens.Space.S),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
		Label(scope, {
			Text = `Tier {entry.TargetTier}`,
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			Size = UDim2.fromOffset(52, 16),
			LayoutOrder = 1,
		}),
		Label(scope, {
			Text = `{entry.Streak} kill streak`,
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			Size = UDim2.fromOffset(102, 16),
			LayoutOrder = 2,
		}),
	}
	if isSelf then
		-- Only on your own row. A "them" chip on every other row would be noise; the absence of this
		-- one IS the other state.
		table.insert(
			metaChildren,
			StatusTag(scope, {
				Label = "You",
				Color = Tokens.Color.Danger,
				Tracked = true,
				LayoutOrder = 3,
			})
		)
	end

	return scope:New "Frame" {
		Name = `BountyRow_{entry.BountyId}`,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		LayoutOrder = rank,
		BackgroundColor3 = if isSelf then Tokens.Color.SurfaceElevated else Tokens.Color.Surface,
		BackgroundTransparency = if isSelf then 0 else 0.35,
		BorderSizePixel = 0,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			},
			scope:New "UIStroke" {
				Color = if isSelf then Tokens.Color.Danger else Tokens.Border.Standard.Color,
				Thickness = 1,
				Transparency = if isSelf then 0.4 else Tokens.Border.Standard.Transparency,
			},
			Inset(scope, { X = ROW_PADDING_X }),
			-- A single lit edge on your own row rather than a full border: it marks the row without
			-- turning it into a box the neighbouring rows aren't.
			scope:New "Frame" {
				Name = "Edge",
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromOffset(-ROW_PADDING_X, 0),
				Size = UDim2.new(0, 2, 1, 0),
				BackgroundColor3 = accent,
				BackgroundTransparency = if isSelf then 0 else 1,
				BorderSizePixel = 0,
			},

			Label(scope, {
				Text = `{rank}.  {entry.TargetName}`,
				Scale = "BodyLarge",
				Color = if isSelf then Tokens.Color.Danger else Tokens.Color.TextPrimary,
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromOffset(0, 11),
				Size = UDim2.new(1, -REWARD_WIDTH, 0, 20),
			}),
			Label(scope, {
				Text = `{entry.Reward} XP`,
				Scale = "Numeral",
				Color = Tokens.Color.AccentSecondary,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 12),
				Size = UDim2.fromOffset(REWARD_WIDTH, 18),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),

			scope:New "Frame" {
				Name = "Meta",
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromOffset(0, 33),
				Size = UDim2.new(1, 0, 0, 22),
				BackgroundTransparency = 1,

				[Children] = metaChildren,
			},
		},
	} :: Frame
end

function BountyTab.Mount(scope: Scope, props: BountyTabProps): Frame
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
	local countText = scope:Computed(function(use)
		local count = #use(entries)
		return if count == 1 then "1 marked" else `{count} marked`
	end)
	local countColor = scope:Computed(function(use)
		return if #use(entries) > 0 then Tokens.Color.Danger else Tokens.Color.TextDisabled
	end)

	return Stack.New(scope, {
		Name = "BountyTab",
		Size = UDim2.fromOffset(props.Width, props.Height),
		Gap = GAP,
		Visible = props.Visible,
		LayoutOrder = props.LayoutOrder,

		Children = {
			SectionHeading(scope, {
				Text = "Active Bounties",
				LayoutOrder = 1,
				Accessory = StatusTag(scope, {
					Label = countText,
					Color = countColor,
				}),
			}),
			Label(scope, {
				Text = "Marked by the server. Ranked by what they pay.",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, HINT_HEIGHT),
				LayoutOrder = 2,
			}),

			-- The empty state and the list are mutually exclusive, driven off the same one Computed
			-- rather than each deciding independently -- so there is no frame in which both or neither
			-- renders.
			Label(scope, {
				-- States the rule rather than just reporting emptiness -- an empty board is the normal
				-- resting state of this system, so "none right now" alone would read as broken.
				Text = `No bounties. One appears when someone reaches a {BountyConstants.NotorietyStreakThreshold}-kill streak.`,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				Size = UDim2.fromScale(1, 0),
				LayoutOrder = 3,
				Visible = scope:Computed(function(use)
					return not use(hasEntries)
				end),
			}),
			-- A ScrollingFrame now that this is a full tab rather than a 420px-tall side panel: a
			-- populated server can carry more marks than fit, and a plain Frame silently clipped the
			-- overflow. AutomaticCanvasSize means the canvas tracks however many rows exist without
			-- this file counting them, the same shape Screens/DevTools/MoveEditor/MoveList.lua uses.
			-- Takes whatever the heading and the subtitle left, rather than giving back a hand-summed
			-- HEADER_ALLOWANCE -- see Components/Stack.lua's header. That constant was this file's
			-- share of the ten that a single Tokens.Type change used to invalidate silently.
			Stack.Fill(
				scope,
				ScrollArea(scope, {
					Name = "Rows",
					Size = UDim2.fromScale(1, 1),
					LayoutOrder = 4,
					Visible = hasEntries,

					Children = {
						Inset(scope, { Right = Tokens.Space.S }),
						scope:New "UIListLayout" {
							FillDirection = Enum.FillDirection.Vertical,
							HorizontalAlignment = Enum.HorizontalAlignment.Left,
							Padding = UDim.new(0, Tokens.Space.XS),
							SortOrder = Enum.SortOrder.LayoutOrder,
						},
						rows,
					},
				})
			),
		},
	})
end

return BountyTab
