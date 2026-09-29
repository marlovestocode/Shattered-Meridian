--!strict
--[[
	MoveEditor/FrameData.lua

	Owns: the readout's FRAME DATA block -- startup/active/recovery in frames, advantage on hit and on
	block, and the balance counts (hits to kill, blocks and clean hits to break a guard, damage per second)
	-- rendered from the entry's Balance.

	EVERY NUMBER IS THE SERVER'S. Balance is computed in Server/Systems/Support/MoveBalance.lua from the
	effective timeline and the live damage/defence modules, several of which the client does not have;
	this file only formats it. It lags an edit by the same one debounced round trip the timeline does.

	SIGN AND HUE TOGETHER. An advantage is written with its sign ("+3", "−24") and coloured by it --
	Positive when the attacker is never at a disadvantage, Warning when they can be -- so the colour is
	never the only carrier of the meaning.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local StatRow = require(script.Parent.Parent.Parent.Parent.Components.StatRow)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Balance = MoveEditorTypes.Balance

export type FrameDataProps = {
	Entry: UsedAs<MoveEditorTypes.MoveEntry?>,
	LayoutOrder: number?,
}

local ROW_HEIGHT = 22

local function signed(frames: number): string
	if frames > 0 then
		return `+{frames}`
	elseif frames < 0 then
		return `−{-frames}`
	end
	return "0"
end

local function range(frames: MoveEditorTypes.FrameRange): string
	if frames.Min == frames.Max then
		return signed(frames.Min)
	end
	return `{signed(frames.Min)} to {signed(frames.Max)}`
end

local function count(value: number?): string
	return if value then tostring(value) else "never"
end

local function FrameData(scope: Scope, props: FrameDataProps): Frame
	local balance = scope:Computed(function(use): Balance?
		local entry = use(props.Entry)
		return if entry then entry.Balance else nil
	end)
	local hasBalance = scope:Computed(function(use)
		return use(balance) ~= nil
	end)

	local function row(
		caption: string,
		order: number,
		value: (Balance) -> string,
		color: ((Balance) -> Color3)?
	): Instance
		return StatRow(scope, {
			Caption = caption,
			Value = scope:Computed(function(use)
				local b = use(balance)
				return if b then value(b) else "-"
			end),
			ValueColor = if color
				then scope:Computed(function(use)
					local b = use(balance)
					return if b then color(b) else Tokens.Color.TextSecondary
				end)
				else nil,
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			LayoutOrder = order,
		})
	end

	local function advantageColor(pick: (Balance) -> MoveEditorTypes.FrameRange): (Balance) -> Color3
		return function(b)
			return if pick(b).Min >= 0 then Tokens.Color.Positive else Tokens.Color.Warning
		end
	end

	return Stack.New(scope, {
		Name = "FrameData",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		LayoutOrder = props.LayoutOrder,
		Visible = hasBalance,
		Children = {
			row("Startup / active / recovery", 1, function(b)
				return `{b.StartupFrames}f / {b.ActiveFrames}f / {b.RecoveryFrames}f`
			end),
			row("Total  (cooldown)", 2, function(b)
				return `{b.TotalFrames}f  ({b.CooldownFrames}f)`
			end),
			row(
				"On hit",
				3,
				function(b)
					return range(b.OnHitFrames)
				end,
				advantageColor(function(b)
					return b.OnHitFrames
				end)
			),
			row(
				"On block",
				4,
				function(b)
					return range(b.OnBlockFrames)
				end,
				advantageColor(function(b)
					return b.OnBlockFrames
				end)
			),
			Label(scope, {
				Text = `No blockstun: the blocker acts at once. Contact on the first to the last active frame, at {Constants.MoveEditor.FrameRate} frames a second.`,
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.fromScale(1, 0),
				AutoHeight = true,
				TextWrapped = true,
				LineHeight = Tokens.Leading.Prose,
				LayoutOrder = 5,
			}),
			row("Hits to kill", 6, function(b)
				if b.HitsToKill == nil then
					return "never"
				end
				return `{count(b.HitsToKill)}  (string: {count(b.StringHitsToKill)})`
			end),
			row("Blocks to break guard", 7, function(b)
				if b.BlockedHitsToBreakGuard == nil then
					return "never"
				end
				return `{count(b.BlockedHitsToBreakGuard)}  (staggered: {count(b.StaggeredBlocksToBreakGuard)})`
			end),
			row("Clean hits to break guard", 8, function(b)
				return count(b.CleanHitsToBreakGuard)
			end),
			row("Damage per second", 9, function(b)
				return string.format("%.1f", b.DamagePerSecond)
			end),
		},
	})
end

return FrameData
