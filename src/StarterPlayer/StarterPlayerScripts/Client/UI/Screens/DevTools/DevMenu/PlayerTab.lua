--!strict
--[[
	DevMenu/PlayerTab.lua

	Owns: the Player tab -- every action on the SELECTED player, grouped by how much it changes:
	overrides (toggled on and off, persist across respawns), movement, vitals, grants, and moderation
	at the bottom, furthest from the everyday controls.

	THE PLATE AT THE TOP NAMES THE TARGET, and it is the only place on the panel that does. Every
	control below acts on that name and nobody else. The old panel's "Target: Self" header was the
	same idea with the target hard-wired to the admin; here it follows the roster selection.

	TOGGLES SHOW THE SERVER'S STATE, NOT THE PRESS. A switch reads the last inspection, so after a
	press it moves when the server has applied the override (the driver re-inspects straight after
	every action) -- a refused override never shows as on.

	SOME CONTROLS DO NOT APPLY TO YOURSELF and are hidden rather than disabled when you are the
	target: going to yourself, bringing yourself, spectating yourself, kicking, banning, muting and
	flagging yourself. Resetting your own saved data stays -- wiping your own test profile is the
	commonest reason to reach for it.

	IRREVERSIBLE ACTIONS ARM FIRST (Kit.Armed): Kill, Ban, Reset saved data.

	Does not own: what any intent does (the driver), or the target (SelectedUserId).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AdminTypes = require(ReplicatedStorage.Shared.Admin.AdminTypes)
local BloodlineConstants = require(ReplicatedStorage.Shared.Bloodline.BloodlineConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local DropdownModule = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)
local TrackedLabel = require(script.Parent.Parent.Parent.Parent.Components.TrackedLabel)

local DevMenuTypes = require(script.Parent.Types)
local Kit = require(script.Parent.Kit)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Inspection = AdminTypes.Inspection
type Intent = DevMenuTypes.Intent

export type PlayerTabProps = {
	Visible: UsedAs<boolean>,
	Inspection: UsedAs<Inspection?>,
	SpectatingUserId: UsedAs<number?>,
	Fire: (Intent) -> (),
}

local DevMenuConfig = Constants.Debug.DevMenu

local function PlayerTab(scope: Scope, props: PlayerTabProps): ScrollingFrame
	local reasonText = scope:Value("")
	local banDuration = scope:Value("Day")

	local hasTarget = scope:Computed(function(use)
		return use(props.Inspection) ~= nil
	end)
	local noTarget = scope:Computed(function(use)
		return use(props.Inspection) == nil
	end)
	local isOther = scope:Computed(function(use)
		local inspection = use(props.Inspection)
		return inspection ~= nil and not inspection.IsRequester
	end)
	local isSelf = scope:Computed(function(use)
		local inspection = use(props.Inspection)
		return inspection ~= nil and inspection.IsRequester
	end)
	local isDead = scope:Computed(function(use)
		local inspection = use(props.Inspection)
		return inspection ~= nil and not inspection.Alive
	end)
	local function flag(pick: (Inspection) -> boolean): Fusion.Computed<boolean>
		return scope:Computed(function(use)
			local inspection = use(props.Inspection)
			return inspection ~= nil and pick(inspection)
		end)
	end

	local function override(
		label: string,
		name: DevMenuTypes.OverrideName,
		hint: string,
		pick: (Inspection) -> boolean
	): Frame
		return Toggle(scope, {
			Label = label,
			Hint = hint,
			Value = flag(pick),
			OnChanged = function(enabled: boolean)
				props.Fire({ Kind = "Override", Override = name, Enabled = enabled })
			end,
		})
	end

	local speedOptions: { Kit.Option } = {}
	for _, preset in DevMenuConfig.SpeedMultiplierPresets do
		table.insert(speedOptions, { Value = tostring(preset), Text = `{preset}x` })
	end

	local xpButtons: { Instance } = {}
	for index, grant in DevMenuConfig.XpGrants do
		table.insert(
			xpButtons,
			Kit.Button(scope, {
				Text = grant.Label,
				Order = index,
				Size = Kit.Cell(#DevMenuConfig.XpGrants),
				OnActivated = function()
					props.Fire({ Kind = "GrantXP", Key = grant.Key })
				end,
			})
		)
	end

	local banOptions: { DropdownModule.DropdownOption } = {}
	for _, duration in DevMenuConfig.BanDurations do
		table.insert(banOptions, { Value = duration.Key, Text = duration.Label })
	end

	local targetName = scope:Computed(function(use)
		local inspection = use(props.Inspection)
		return if inspection then inspection.DisplayName else ""
	end)

	local children: { Instance } = {
		-- The target plate.
		Stack.New(scope, {
			Name = "Plate",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Gap = Tokens.Space.XS,
			LayoutOrder = 1,
			Children = {
				TrackedLabel(scope, {
					Text = "ACTING ON",
					Scale = "Eyebrow",
					Color = Tokens.Color.TextDisabled,
					LayoutOrder = 1,
				}),
				Label(scope, {
					Text = scope:Computed(function(use)
						local name = use(targetName)
						if name == "" then
							return "Nobody selected"
						end
						return if use(isSelf) then `{name}  (you)` else name
					end),
					Scale = "Heading",
					Color = scope:Computed(function(use)
						return if use(hasTarget) then Tokens.Color.TextPrimary else Tokens.Color.TextDisabled
					end),
					Size = UDim2.new(1, 0, 0, Tokens.Type.Heading.Size + Tokens.Space.XS),
					TextTruncate = Enum.TextTruncate.AtEnd,
					LayoutOrder = 2,
				}),
				Kit.Prose(scope, "Pick a player in the roster -- every control on this tab acts on them.", 3, noTarget),
			},
		}),

		-- Overrides.
		Kit.Heading(scope, "OVERRIDES", 10, hasTarget),
		Kit.Prose(
			scope,
			"Stay on across respawns until turned off. The rail on the right shows what the server applied.",
			11,
			hasTarget
		),
		Kit.Pair(
			scope,
			12,
			override("Godmode", "Godmode", "Takes no damage from any source.", function(inspection)
				return inspection.Godmode
			end),
			override("Frozen", "Frozen", "Cannot move or jump.", function(inspection)
				return inspection.Frozen
			end),
			hasTarget
		),
		Kit.Pair(
			scope,
			13,
			override(
				"Flight",
				"Flight",
				"Free flight, driven by their own client. Needs a live body.",
				function(inspection)
					return inspection.Flying
				end
			),
			override(
				"Flight collides",
				"FlightCollide",
				"While flying, bump into the world instead of passing through.",
				function(inspection)
					return inspection.FlyCollide
				end
			),
			hasTarget
		),
		Kit.Pair(
			scope,
			14,
			override("Invisible", "Invisible", "Every part of their body hidden from everyone.", function(inspection)
				return inspection.Invisible
			end),
			Kit.Group(scope, 1, {
				Label(scope, {
					Text = "Walk speed",
					Scale = "Body",
					Color = Tokens.Color.TextSecondary,
					Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + Tokens.Space.XS),
					LayoutOrder = 1,
				}),
				Kit.Segmented(scope, {
					Options = speedOptions,
					Selected = scope:Computed(function(use)
						local inspection = use(props.Inspection)
						return if inspection then tostring(inspection.SpeedMultiplier) else nil
					end),
					OnPick = function(value: string)
						props.Fire({ Kind = "Speed", Multiplier = tonumber(value) :: number })
					end,
					Order = 2,
				}),
			}, nil, Tokens.Space.XS),
			hasTarget
		),

		-- Movement.
		Kit.Heading(scope, "MOVEMENT", 20, hasTarget),
		Kit.Row(scope, 21, {
			Kit.Button(scope, {
				Text = "Go to them",
				Order = 1,
				Size = Kit.Cell(3),
				Visible = isOther,
				OnActivated = function()
					props.Fire({ Kind = "GoTo" })
				end,
			}),
			Kit.Button(scope, {
				Text = "Bring here",
				Order = 2,
				Size = Kit.Cell(3),
				Visible = isOther,
				OnActivated = function()
					props.Fire({ Kind = "Bring" })
				end,
			}),
			Kit.Button(scope, {
				Text = scope:Computed(function(use)
					local inspection = use(props.Inspection)
					return if inspection and use(props.SpectatingUserId) == inspection.UserId
						then "Stop watching"
						else "Spectate"
				end),
				Order = 3,
				Size = Kit.Cell(3),
				Visible = isOther,
				OnActivated = function()
					props.Fire({ Kind = "Spectate" })
				end,
			}),
		}, isOther),
		Kit.Button(scope, {
			Text = scope:Computed(function(use)
				return if use(isDead) then "Respawn now" else "Force respawn"
			end),
			Order = 22,
			Visible = hasTarget,
			OnActivated = function()
				props.Fire({ Kind = "Respawn" })
			end,
		}),

		-- Vitals.
		Kit.Heading(scope, "VITALS", 30, hasTarget),
		Kit.Row(scope, 31, {
			Kit.Button(scope, {
				Text = "Restore health & Qi",
				Order = 1,
				Size = Kit.Cell(2),
				Disabled = isDead,
				OnActivated = function()
					props.Fire({ Kind = "Restore" })
				end,
			}),
			Kit.Armed(scope, {
				Idle = "Kill",
				Armed = "Kill? Again",
				Order = 2,
				Size = Kit.Cell(2),
				Disabled = isDead,
				OnConfirm = function()
					props.Fire({ Kind = "Kill" })
				end,
			}),
		}, hasTarget),
		Kit.Prose(
			scope,
			"Kill runs the ordinary death path -- death screen, respawn -- with nobody credited.",
			32,
			hasTarget
		),

		-- Grants.
		Kit.Heading(scope, "GRANTS", 40, hasTarget),
		Label(scope, {
			Text = "Meridian XP  --  tiers promote from it the normal way",
			Scale = "Body",
			Color = Tokens.Color.TextSecondary,
			Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + Tokens.Space.XS),
			LayoutOrder = 41,
			Visible = hasTarget,
		}),
		Kit.Row(scope, 42, xpButtons, hasTarget),
		Kit.Row(scope, 43, {
			Kit.Button(scope, {
				Text = `+{BloodlineConstants.DevGrantRerollAmount} bloodline rerolls`,
				Order = 1,
				Size = Kit.Cell(2),
				OnActivated = function()
					props.Fire({ Kind = "GrantRerolls" })
				end,
			}),
			Kit.Button(scope, {
				Text = "Roll a rare emote",
				Order = 2,
				Size = Kit.Cell(2),
				OnActivated = function()
					props.Fire({ Kind = "RollEmote" })
				end,
			}),
		}, hasTarget),

		-- Moderation.
		Kit.Heading(scope, "MODERATION", 50, hasTarget),
		Kit.Group(scope, 51, {
			TextField(scope, {
				Text = reasonText,
				PlaceholderText = "Reason -- shown to them on a kick or ban, kept on the record",
				MaxLength = 200,
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				LayoutOrder = 1,
			}),
			Kit.Row(scope, 2, {
				Kit.Button(scope, {
					Text = "Kick",
					Order = 1,
					Size = Kit.Cell(3),
					OnActivated = function()
						props.Fire({ Kind = "Kick", Reason = peek(reasonText) })
					end,
				}),
				Kit.Button(scope, {
					Text = scope:Computed(function(use)
						local inspection = use(props.Inspection)
						return if inspection and inspection.Muted then "Unmute" else "Mute chat"
					end),
					Order = 2,
					Size = Kit.Cell(3),
					OnActivated = function()
						local inspection = peek(props.Inspection)
						props.Fire({ Kind = "Mute", Enabled = not (inspection ~= nil and inspection.Muted) })
					end,
				}),
				Kit.Button(scope, {
					Text = scope:Computed(function(use)
						local inspection = use(props.Inspection)
						return if inspection and inspection.Flagged then "Clear flag" else "Flag as cheater"
					end),
					Order = 3,
					Size = Kit.Cell(3),
					OnActivated = function()
						local inspection = peek(props.Inspection)
						props.Fire({
							Kind = "Flag",
							Enabled = not (inspection ~= nil and inspection.Flagged),
							Reason = peek(reasonText),
						})
					end,
				}),
			}),
			Kit.Pair(
				scope,
				3,
				DropdownModule.Mount(scope, {
					Label = "Ban for",
					Options = banOptions,
					Value = banDuration,
					OnChanged = function(value: string)
						banDuration:set(value)
					end,
				}),
				Stack.New(scope, {
					Size = UDim2.fromScale(1, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					Gap = Tokens.Space.XS,
					Children = {
						-- Spacer that lines the button up with the dropdown's field rather than its label.
						scope:New "Frame" {
							Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + Tokens.Space.XS),
							BackgroundTransparency = 1,
							LayoutOrder = 1,
						},
						Kit.Armed(scope, {
							Idle = "Ban",
							Armed = "Ban? Again",
							Order = 2,
							Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
							OnConfirm = function()
								props.Fire({ Kind = "Ban", DurationKey = peek(banDuration), Reason = peek(reasonText) })
							end,
						}),
					},
				})
			),
		}, isOther),
		Kit.Prose(
			scope,
			"Moderation acts on other players. Select someone else to kick, mute, flag or ban them.",
			52,
			isSelf
		),

		-- The one irreversible data action, alone at the bottom.
		Kit.Heading(scope, "SAVED DATA", 60, hasTarget, nil),
		Kit.Prose(
			scope,
			"Wipes their saved progression back to a fresh profile: tier, XP, bloodlines, arts, everything. There is no undo.",
			61,
			hasTarget,
			Tokens.Color.Warning
		),
		Kit.Armed(scope, {
			Idle = "Reset saved data",
			Armed = "Wipe the profile? Press again",
			Order = 62,
			Visible = hasTarget,
			OnConfirm = function()
				props.Fire({ Kind = "ResetData" })
			end,
		}),
	}

	return Kit.Page(scope, "PlayerTab", props.Visible, children)
end

return PlayerTab
