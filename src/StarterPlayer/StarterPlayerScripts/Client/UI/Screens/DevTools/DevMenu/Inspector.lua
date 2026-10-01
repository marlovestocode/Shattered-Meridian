--!strict
--[[
	DevMenu/Inspector.lua

	Owns: the admin panel's right rail -- everything the server knows about the selected player, live:
	who they are, their vitals, what their combat state is right now, where their cultivation stands,
	which overrides are on them, and their session.

	PINNED, NOT A TAB, for the Move Editor readout's reason: it is the RESULT of what the Player tab
	does. Toggle Godmode and the OVERRIDES block says GODMODE on the next poll; grant XP and the tier
	meter moves. A result a tab switch away from the action that caused it is a result nobody checks.

	THE SERVER'S WORD ONLY. Every value is the last InspectPlayer answer (polled each second while a
	player is selected) -- nothing here is predicted from a button press, so the rail never shows an
	override the server refused.

	Does not own: the data (the driver's poll) or any action (the Player tab).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AdminFormat = require(ReplicatedStorage.Shared.Admin.AdminFormat)
local AdminTypes = require(ReplicatedStorage.Shared.Admin.AdminTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Inset = require(script.Parent.Parent.Parent.Parent.Components.Inset)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local StatusTag = require(script.Parent.Parent.Parent.Parent.Components.StatusTag)

local Kit = require(script.Parent.Kit)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Inspection = AdminTypes.Inspection

export type InspectorProps = {
	Width: number,
	LayoutOrder: number?,
	Inspection: UsedAs<Inspection?>,
	SelectedUserId: UsedAs<number?>,
	SpectatingUserId: UsedAs<number?>,
}

local CHIP_ROW_HEIGHT = 24

local function Inspector(scope: Scope, props: InspectorProps): ScrollingFrame
	local function read<T>(fallback: T, pick: (Inspection) -> T): Fusion.Computed<T>
		return scope:Computed(function(use)
			local inspection = use(props.Inspection)
			return if inspection then pick(inspection) else fallback
		end)
	end

	local hasInspection = read(false, function()
		return true
	end)
	-- Selected but not answered yet (a fresh selection, or a player who just left).
	local isWaiting = scope:Computed(function(use)
		return use(props.SelectedUserId) ~= nil and use(props.Inspection) == nil
	end)
	local isEmpty = scope:Computed(function(use)
		return use(props.SelectedUserId) == nil
	end)
	local profileLoaded = read(false, function(inspection)
		return inspection.ProfileLoaded
	end)
	local profileMissing = scope:Computed(function(use)
		return use(hasInspection) and not use(profileLoaded)
	end)

	local function chip(label: string, color: Color3, order: number, visible: UsedAs<boolean>): Instance
		return scope:New "Frame" {
			Name = label,
			Size = UDim2.fromScale(0, 1),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Visible = visible,
			[Fusion.Children] = StatusTag(scope, { Label = label, Color = color }),
		}
	end

	local engagement = read(nil :: any, function(inspection)
		return inspection.Engagement
	end)

	local overridesText = read("", function(inspection)
		local active: { string } = {}
		if inspection.Godmode then
			table.insert(active, "Godmode")
		end
		if inspection.Flying then
			table.insert(active, if inspection.FlyCollide then "Flying (collides)" else "Flying")
		end
		if inspection.Frozen then
			table.insert(active, "Frozen")
		end
		if inspection.Invisible then
			table.insert(active, "Invisible")
		end
		if inspection.SpeedMultiplier ~= 1 then
			table.insert(active, `Speed x{inspection.SpeedMultiplier}`)
		end
		return if #active > 0 then table.concat(active, " · ") else "None"
	end)

	local bloodlinesText = read("", function(inspection)
		if #inspection.Bloodlines == 0 then
			return "None awakened"
		end
		local lines: { string } = {}
		for _, bloodline in inspection.Bloodlines do
			table.insert(lines, `{bloodline.Name} (stage {bloodline.Stage})`)
		end
		return table.concat(lines, ", ")
	end)

	local content: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Tokens.Space.M),
		},
		Inset(scope, { Top = Tokens.Space.M, Bottom = Tokens.Space.XL, X = Tokens.Space.M }),

		Kit.Prose(scope, "Pick a player on the left to inspect them.", 1, isEmpty),
		Kit.Prose(scope, "Reading...", 2, isWaiting),

		-- Identity.
		Stack.New(scope, {
			Name = "Identity",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Gap = Tokens.Space.XS,
			LayoutOrder = 10,
			Visible = hasInspection,
			Children = {
				Label(scope, {
					Text = read("", function(inspection)
						return inspection.DisplayName
					end),
					Scale = "CardTitle",
					Color = Tokens.Color.TextPrimary,
					Size = UDim2.new(1, 0, 0, Tokens.Type.CardTitle.Size + Tokens.Space.XS),
					TextTruncate = Enum.TextTruncate.AtEnd,
					LayoutOrder = 1,
				}),
				Label(scope, {
					Text = read("", function(inspection)
						local character = if inspection.CharacterName then `  ·  as {inspection.CharacterName}` else ""
						return `@{inspection.Name}  ·  {inspection.UserId}{character}`
					end),
					Scale = "Detail",
					Color = Tokens.Color.TextSecondary,
					Size = UDim2.new(1, 0, 0, Tokens.Type.Detail.Size + Tokens.Space.XS),
					TextTruncate = Enum.TextTruncate.AtEnd,
					LayoutOrder = 2,
				}),
				Stack.Row(scope, {
					Name = "Chips",
					Size = UDim2.new(1, 0, 0, CHIP_ROW_HEIGHT),
					Gap = Tokens.Space.XS,
					LayoutOrder = 3,
					Children = {
						chip(
							"YOU",
							Tokens.Color.AccentPrimary,
							1,
							read(false, function(inspection)
								return inspection.IsRequester
							end)
						),
						chip(
							"DEAD",
							Tokens.Color.DangerBright,
							2,
							read(false, function(inspection)
								return not inspection.Alive
							end)
						),
						chip(
							"IN COMBAT",
							Tokens.Color.Danger,
							3,
							read(false, function(inspection)
								return inspection.Engagement ~= nil and inspection.Engagement.InCombat
							end)
						),
						chip(
							"FLAGGED",
							Tokens.Color.DangerBright,
							4,
							read(false, function(inspection)
								return inspection.Flagged
							end)
						),
						chip(
							"MUTED",
							Tokens.Color.Warning,
							5,
							read(false, function(inspection)
								return inspection.Muted
							end)
						),
						chip(
							"WATCHING",
							Tokens.Color.AccentSecondary,
							6,
							scope:Computed(function(use)
								local inspection = use(props.Inspection)
								return inspection ~= nil and use(props.SpectatingUserId) == inspection.UserId
							end)
						),
					},
				}),
			},
		}),

		-- Vitals.
		Kit.Heading(scope, "VITALS", 20, hasInspection),
		Kit.Meter(scope, {
			Caption = "Health",
			Value = read(0, function(inspection)
				return inspection.Health
			end),
			Max = read(1, function(inspection)
				return math.max(inspection.MaxHealth, 1)
			end),
			Text = read("", function(inspection)
				return if inspection.Alive then AdminFormat.Pair(inspection.Health, inspection.MaxHealth) else "dead"
			end),
			Color = Tokens.VitalColor.Health,
			CriticalBelow = 0.25,
			Order = 21,
			Visible = hasInspection,
		}),
		Kit.Meter(scope, {
			Caption = "Qi",
			Value = read(0, function(inspection)
				return inspection.Qi
			end),
			Max = read(1, function(inspection)
				return math.max(inspection.MaxQi, 1)
			end),
			Text = read("", function(inspection)
				return AdminFormat.Pair(inspection.Qi, inspection.MaxQi)
			end),
			Color = Tokens.VitalColor.Qi,
			Order = 22,
			Visible = hasInspection,
		}),
		Kit.Meter(scope, {
			Caption = "Guard",
			Value = read(0, function(inspection)
				return inspection.Guard or 0
			end),
			Max = read(1, function(inspection)
				return math.max(inspection.MaxGuard or 1, 1)
			end),
			Text = read("", function(inspection)
				return if inspection.Guard and inspection.MaxGuard
					then AdminFormat.Pair(inspection.Guard, inspection.MaxGuard)
					else "not a combatant"
			end),
			Color = Tokens.VitalColor.Posture,
			CriticalBelow = 0.25,
			Order = 23,
			Visible = hasInspection,
		}),

		-- Combat.
		Kit.Heading(scope, "COMBAT", 30, hasInspection),
		Kit.Stat(
			scope,
			"Defense state",
			read("", function(inspection)
				return inspection.DefenseState or "--"
			end),
			31,
			hasInspection
		),
		Kit.Stat(
			scope,
			"Engaged",
			scope:Computed(function(use)
				local current = use(engagement)
				if not current or not current.InCombat then
					return "No"
				end
				local opponent = current.OpponentName or "someone"
				return `with {opponent} · {math.ceil(current.SecondsRemaining)}s`
			end),
			32,
			hasInspection,
			scope:Computed(function(use)
				local current = use(engagement)
				return if current and current.InCombat then Tokens.Color.DangerBright else Tokens.Color.TextPrimary
			end)
		),
		Kit.Stat(
			scope,
			"This fight",
			scope:Computed(function(use)
				local current = use(engagement)
				if not current then
					return "--"
				end
				return `{math.floor(current.DamageDealt + 0.5)} dealt · {math.floor(current.DamageTaken + 0.5)} taken`
			end),
			33,
			hasInspection
		),
		Kit.Stat(
			scope,
			"Last exchange",
			scope:Computed(function(use)
				local current = use(engagement)
				return if current and current.LastOutcomeKind then current.LastOutcomeKind else "--"
			end),
			34,
			hasInspection
		),
		Kit.Stat(
			scope,
			"Kill streak",
			read("", function(inspection)
				return if inspection.Marked
					then `{inspection.KillStreak} · bounty on them`
					else tostring(inspection.KillStreak)
			end),
			35,
			hasInspection
		),

		-- Cultivation.
		Kit.Heading(scope, "CULTIVATION", 40, hasInspection),
		Kit.Prose(
			scope,
			"Profile not loaded -- these are defaults, not this player's.",
			41,
			profileMissing,
			Tokens.Color.Warning
		),
		Kit.Stat(
			scope,
			"Tier",
			read("", function(inspection)
				return `{inspection.Tier}  ·  {inspection.TierName}`
			end),
			42,
			hasInspection
		),
		Kit.Meter(scope, {
			Caption = "Meridian XP",
			Value = read(0, function(inspection)
				return inspection.MeridianXP - inspection.TierFloorXP
			end),
			Max = read(1, function(inspection)
				return if inspection.TierNextXP then math.max(inspection.TierNextXP - inspection.TierFloorXP, 1) else 1
			end),
			Text = read("", function(inspection)
				if not inspection.TierNextXP then
					return `{AdminFormat.Count(inspection.MeridianXP)} · max tier`
				end
				return `{AdminFormat.Count(inspection.MeridianXP)} / {AdminFormat.Count(inspection.TierNextXP)}`
			end),
			Color = Tokens.Color.AccentSecondary,
			Order = 43,
			Visible = hasInspection,
		}),
		Kit.Stat(
			scope,
			"Race",
			read("", function(inspection)
				return inspection.RaceId or "--"
			end),
			44,
			hasInspection
		),
		Kit.Stat(
			scope,
			"Faction",
			read("", function(inspection)
				return inspection.Faction or "--"
			end),
			45,
			hasInspection
		),
		Kit.Stat(
			scope,
			"Rerolls",
			read("", function(inspection)
				return tostring(inspection.BloodlineRerolls)
			end),
			46,
			hasInspection
		),
		Kit.Stat(
			scope,
			"Arts equipped",
			read("", function(inspection)
				return tostring(inspection.EquippedArtCount)
			end),
			47,
			hasInspection
		),
		Kit.Stat(
			scope,
			"Corruption",
			read("", function(inspection)
				return string.format("%.1f", inspection.Corruption)
			end),
			48,
			hasInspection
		),
		Kit.Stat(
			scope,
			"Deviation risk",
			read("", function(inspection)
				return string.format("%.1f", inspection.QiDeviationRisk)
			end),
			49,
			hasInspection
		),
		Kit.Prose(scope, bloodlinesText, 50, hasInspection, Tokens.Color.TextSecondary),

		-- Overrides.
		Kit.Heading(scope, "OVERRIDES", 60, hasInspection),
		Kit.Prose(
			scope,
			overridesText,
			61,
			hasInspection,
			scope:Computed(function(use)
				return if use(overridesText) == "None" then Tokens.Color.TextDisabled else Tokens.Color.AccentSecondary
			end)
		),

		-- Session.
		Kit.Heading(scope, "SESSION", 70, hasInspection),
		Kit.Stat(
			scope,
			"Ping",
			read("", function(inspection)
				return AdminFormat.Ping(inspection.PingMs)
			end),
			71,
			hasInspection
		),
		Kit.Stat(
			scope,
			"Account age",
			read("", function(inspection)
				return `{AdminFormat.Count(inspection.AccountAgeDays)} days`
			end),
			72,
			hasInspection
		),
		Kit.Stat(
			scope,
			"Position",
			read("", function(inspection)
				return if inspection.Position then AdminFormat.Position(inspection.Position) else "--"
			end),
			73,
			hasInspection
		),
	}

	return ScrollArea(scope, {
		Name = "Inspector",
		Size = UDim2.new(0, props.Width, 1, 0),
		LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = Tokens.Wash.RailScrim.Color,
		BackgroundTransparency = Tokens.Wash.RailScrim.Transparency,
		Children = content,
	})
end

return Inspector
