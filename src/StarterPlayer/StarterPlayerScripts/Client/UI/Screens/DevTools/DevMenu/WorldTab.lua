--!strict
--[[
	DevMenu/WorldTab.lua

	Owns: the World tab -- things the admin puts INTO the server rather than does to a player: sparring
	partners (training bots and dummies), the server-wide hitbox view, a teleport to typed
	coordinates, blimp-fuel test nodes, and the vehicle catalog.

	EVERY SERVER-WIDE TOGGLE READS THE OVERVIEW. Dummy guard and hitbox volumes are state every admin
	in the server shares; the switches show what the last overview poll said, never a local guess, so
	an admin who joins after another turned volumes on sees them on.

	THE WEAPON LIST IS RE-READ WHENEVER THIS TAB OPENS. It is Workspace.Weapons' children (the same ids,
	in the same order, WeaponRoster builds on the server -- which never runs here), and a weapon model
	that replicates after the panel mounted must still be pickable. The dropdown is rebuilt only when
	the list actually changed.

	Does not own: what any intent does (the driver), or the vehicle snapshot (the driver's, from
	VehicleManager's GetState).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AdminFormat = require(ReplicatedStorage.Shared.Admin.AdminFormat)
local AdminTypes = require(ReplicatedStorage.Shared.Admin.AdminTypes)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)
local TrainingBotConstants = require(ReplicatedStorage.Shared.TrainingBot.TrainingBotConstants)
local VehicleTypes = require(ReplicatedStorage.Shared.Vehicle.VehicleTypes)
local WeaponAssets = require(ReplicatedStorage.Shared.Combat.WeaponAssets)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local DropdownModule = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local Tab = require(script.Parent.Parent.Parent.Parent.Components.Tab)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)

local DevMenuTypes = require(script.Parent.Types)
local Kit = require(script.Parent.Kit)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Intent = DevMenuTypes.Intent

export type WorldTabProps = {
	Visible: UsedAs<boolean>,
	Server: UsedAs<AdminTypes.ServerOverview?>,
	VehicleCatalog: UsedAs<{ VehicleTypes.VehicleCatalogEntry }>,
	VehicleLive: UsedAs<{ VehicleTypes.LiveVehicleInfo }>,
	VehicleBerths: UsedAs<{ VehicleTypes.VehicleBerthInfo }>,
	VehicleRegistryText: UsedAs<string>,
	VehicleRejectionText: UsedAs<string?>,
	Fire: (Intent) -> (),
}

local logger = Logger.scope("DevMenuWorldTab")

local LIST_ROW_HEIGHT = 44
local LIST_ACTION_WIDTH = 108
-- "" is the berth picker's "in front of me" -- a berth name is never empty.
local IN_FRONT = ""

-- "Default", every Workspace.Weapons model by name, then Fists -- see this file's header.
local function readWeaponChoices(): { string }
	local names: { string } = {}
	local container = WeaponAssets.Container(logger)
	if container then
		for _, child in container:GetChildren() do
			if child.Name ~= WeaponRoster.FISTS_ID and not table.find(names, child.Name) then
				table.insert(names, child.Name)
			end
		end
	end
	table.sort(names)
	table.insert(names, 1, TrainingBotConstants.DefaultWeaponChoice)
	table.insert(names, WeaponRoster.FISTS_ID)
	return names
end

local function options(names: { string }): { DropdownModule.DropdownOption }
	local result: { DropdownModule.DropdownOption } = {}
	for _, name in names do
		table.insert(result, { Value = name, Text = name })
	end
	return result
end

-- A two-line list row with one action at its right edge: the catalog and the live list both use it.
local function listRow(scope: Scope, order: number, title: string, detail: string, action: Instance): Frame
	return scope:New "Frame" {
		Name = "Row",
		Size = UDim2.new(1, 0, 0, LIST_ROW_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		[Fusion.Children] = {
			Label(scope, {
				Text = title,
				Scale = "Body",
				Color = Tokens.Color.TextPrimary,
				Position = UDim2.fromOffset(0, 4),
				Size = UDim2.new(1, -(LIST_ACTION_WIDTH + Tokens.Space.S), 0, Tokens.Type.Body.Size + 4),
				TextTruncate = Enum.TextTruncate.AtEnd,
			}),
			Label(scope, {
				Text = detail,
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				Position = UDim2.fromOffset(0, 23),
				Size = UDim2.new(1, -(LIST_ACTION_WIDTH + Tokens.Space.S), 0, Tokens.Type.Detail.Size + 4),
				TextTruncate = Enum.TextTruncate.AtEnd,
			}),
			scope:New "Frame" {
				Name = "Action",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromOffset(LIST_ACTION_WIDTH, Kit.ButtonHeight),
				BackgroundTransparency = 1,
				[Fusion.Children] = action,
			},
			scope:New "Frame" {
				Name = "Rule",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, Tokens.Control.DividerThickness),
				BackgroundColor3 = Tokens.Border.Hairline.Color,
				BackgroundTransparency = Tokens.Border.Hairline.Transparency,
				BorderSizePixel = 0,
			},
		},
	} :: Frame
end

local function list(scope: Scope, name: string, order: number, rows: any): Frame
	return Stack.New(scope, {
		Name = name,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Children = { rows },
	})
end

local function WorldTab(scope: Scope, props: WorldTabProps): ScrollingFrame
	local botStyle = scope:Value(TrainingBotConstants.DefaultStyle :: string)
	local botDifficulty = scope:Value(TrainingBotConstants.DefaultDifficulty :: string)
	local botWeapon = scope:Value(TrainingBotConstants.DefaultWeaponChoice)
	local weaponNames = scope:Value(readWeaponChoices())
	local teleportX = scope:Value("")
	local teleportY = scope:Value("")
	local teleportZ = scope:Value("")
	local berth = scope:Value(IN_FRONT)

	-- Re-read the weapon list on every open of this tab -- see the header. Set only on a real change,
	-- so the dropdown is not rebuilt under a cursor for nothing.
	scope:Observer(props.Visible):onChange(function()
		if not peek(props.Visible) then
			return
		end
		local fresh = readWeaponChoices()
		if table.concat(fresh, "\0") ~= table.concat(peek(weaponNames), "\0") then
			weaponNames:set(fresh)
			if not table.find(fresh, peek(botWeapon)) then
				botWeapon:set(TrainingBotConstants.DefaultWeaponChoice)
			end
		end
	end)

	local function serverFact<T>(fallback: T, pick: (AdminTypes.ServerOverview) -> T): Fusion.Computed<T>
		return scope:Computed(function(use)
			local server = use(props.Server)
			return if server then pick(server) else fallback
		end)
	end

	local sparringText = serverFact("", function(server)
		local bots = if server.BotCount == 1 then "1 bot" else `{server.BotCount} bots`
		local dummies = if server.DummyCount == 1 then "1 dummy" else `{server.DummyCount} dummies`
		return `{bots} · {dummies}`
	end)

	-- One dropdown per distinct weapon list; ForValues rebuilds it when the list's identity changes.
	local weaponPicker = scope:ForValues(
		scope:Computed(function(use)
			return { use(weaponNames) }
		end),
		function(_use, innerScope: Scope, names: { string })
			return DropdownModule.Mount(innerScope, {
				Label = "Weapon",
				Options = options(names),
				Value = botWeapon,
				OnChanged = function(value: string)
					botWeapon:set(value)
				end,
			})
		end
	)

	local function readCoordinate(value: Fusion.Value<string>): number?
		local number = tonumber((string.gsub(peek(value), "%s", "")))
		return if number and number == number and math.abs(number) < math.huge then number else nil
	end

	local berthChips = scope:ForPairs(
		scope:Computed(function(use)
			local chips: { { Value: string, Text: string } } = {
				{ Value = IN_FRONT, Text = "In front of me" },
			}
			for _, info in use(props.VehicleBerths) do
				local occupied = if info.Occupied then " · taken" else ""
				table.insert(chips, { Value = info.Name, Text = `{info.Name}{occupied}` })
			end
			return chips
		end),
		function(_use, innerScope: Scope, index: number, chip: { Value: string, Text: string })
			return index,
				Tab(innerScope, {
					Text = chip.Text,
					Selected = innerScope:Computed(function(use)
						return use(berth) == chip.Value
					end),
					-- Tab does not size itself to its text, so the chip is measured roughly from it.
					Size = UDim2.fromOffset(math.max(96, #chip.Text * 8 + Tokens.Space.L * 2), Kit.ButtonHeight - 4),
					LayoutOrder = index,
					OnActivated = function()
						berth:set(chip.Value)
					end,
				})
		end
	)
	-- A berth that vanished from the registry falls back to "in front of me" rather than sending a
	-- name the server will refuse.
	scope:Observer(props.VehicleBerths):onChange(function()
		local current = peek(berth)
		if current == IN_FRONT then
			return
		end
		for _, info in peek(props.VehicleBerths) do
			if info.Name == current then
				return
			end
		end
		berth:set(IN_FRONT)
	end)

	local catalogRows = scope:ForPairs(
		props.VehicleCatalog,
		function(_use, innerScope: Scope, index: number, entry: VehicleTypes.VehicleCatalogEntry)
			local atCapacity = entry.LiveCount >= entry.MaxLive
			return index,
				listRow(
					innerScope,
					index,
					entry.DisplayName,
					`{entry.Kind} · {entry.FootprintStuds} studs · {entry.LiveCount}/{entry.MaxLive} live`,
					Kit.Button(innerScope, {
						Text = if atCapacity then "Replace oldest" else "Spawn",
						Order = 1,
						Size = UDim2.fromScale(1, 1),
						OnActivated = function()
							local target = peek(berth)
							props.Fire({
								Kind = "VehicleSpawn",
								VehicleId = entry.Id,
								Berth = if target == IN_FRONT then nil else target,
							})
						end,
					})
				)
		end
	)

	local liveRows = scope:ForPairs(
		props.VehicleLive,
		function(_use, innerScope: Scope, index: number, info: VehicleTypes.LiveVehicleInfo)
			local place = if info.BerthName then `berth {info.BerthName}` else AdminFormat.Position(info.Position)
			local occupied = if info.Occupied then " · crewed" else ""
			return index,
				listRow(
					innerScope,
					index,
					info.DisplayName,
					`{info.OwnerName} · {AdminFormat.Duration(info.AgeSeconds)} · {place}{occupied}`,
					Kit.Button(innerScope, {
						Text = "Despawn",
						Order = 1,
						Size = UDim2.fromScale(1, 1),
						OnActivated = function()
							props.Fire({ Kind = "VehicleDespawn", InstanceId = info.InstanceId })
						end,
					})
				)
		end
	)
	local noCatalog = scope:Computed(function(use)
		return #use(props.VehicleCatalog) == 0
	end)
	local noLive = scope:Computed(function(use)
		return #use(props.VehicleLive) == 0
	end)

	local children: { Instance } = {
		-- Sparring.
		Kit.Heading(scope, "SPARRING", 10, nil, sparringText),
		Kit.Prose(
			scope,
			"Bots fight through the same entry points a player does. Style is what it does, difficulty how well. Dummies guard but never parry -- spawn a ParryOnly bot to test against a parry.",
			11
		),
		Kit.Pair(
			scope,
			12,
			DropdownModule.Mount(scope, {
				Label = "Bot style",
				Options = options(TrainingBotConstants.StyleOrder :: { string }),
				Value = botStyle,
				OnChanged = function(value: string)
					botStyle:set(value)
				end,
			}),
			DropdownModule.Mount(scope, {
				Label = "Difficulty",
				Options = options(TrainingBotConstants.DifficultyOrder :: { string }),
				Value = botDifficulty,
				OnChanged = function(value: string)
					botDifficulty:set(value)
				end,
			})
		),
		Kit.Holder(scope, "Weapon", 13, weaponPicker :: any),
		Kit.Row(scope, 14, {
			Kit.Button(scope, {
				Text = "Spawn bot",
				Order = 1,
				Size = Kit.Cell(2),
				OnActivated = function()
					props.Fire({
						Kind = "SpawnBot",
						Style = peek(botStyle),
						Difficulty = peek(botDifficulty),
						Weapon = peek(botWeapon),
					})
				end,
			}),
			Kit.Button(scope, {
				Text = "Despawn bots",
				Order = 2,
				Size = Kit.Cell(2),
				OnActivated = function()
					props.Fire({ Kind = "DespawnBots" })
				end,
			}),
		}),
		Kit.Row(scope, 15, {
			Kit.Button(scope, {
				Text = "Spawn dummy",
				Order = 1,
				Size = Kit.Cell(2),
				OnActivated = function()
					props.Fire({ Kind = "SpawnDummy" })
				end,
			}),
			Kit.Button(scope, {
				Text = "Despawn dummies",
				Order = 2,
				Size = Kit.Cell(2),
				OnActivated = function()
					props.Fire({ Kind = "DespawnDummies" })
				end,
			}),
		}),
		Kit.Holder(
			scope,
			"DummyGuard",
			16,
			Toggle(scope, {
				Label = "Dummies hold their guard",
				Hint = "Server-wide: every dummy, now and future, blocks until this is off.",
				Value = serverFact(false, function(server)
					return server.DummyGuard
				end),
				OnChanged = function(enabled: boolean)
					props.Fire({ Kind = "DummyGuard", Enabled = enabled })
				end,
			})
		),

		-- Debug view.
		Kit.Heading(scope, "DEBUG VIEW", 20),
		Kit.Holder(
			scope,
			"Volumes",
			21,
			Toggle(scope, {
				Label = "Show live hitbox volumes",
				Hint = "Server-wide: every swing draws its real volume for everyone in the server. Turn it off when done.",
				Value = serverFact(false, function(server)
					return server.HitboxVolumes
				end),
				OnChanged = function(enabled: boolean)
					props.Fire({ Kind = "HitboxVolumes", Enabled = enabled })
				end,
			})
		),
		Kit.Prose(scope, "F6 toggles the parkour debug overlay; F3 the frame-rate readout; F5 the live console.", 22),

		-- Teleport.
		Kit.Heading(scope, "TELEPORT", 30),
		Kit.Row(scope, 31, {
			TextField(scope, {
				Text = teleportX,
				PlaceholderText = "X",
				MaxLength = 12,
				Size = Kit.Cell(5),
				LayoutOrder = 1,
			}),
			TextField(scope, {
				Text = teleportY,
				PlaceholderText = "Y",
				MaxLength = 12,
				Size = Kit.Cell(5),
				LayoutOrder = 2,
			}),
			TextField(scope, {
				Text = teleportZ,
				PlaceholderText = "Z",
				MaxLength = 12,
				Size = Kit.Cell(5),
				LayoutOrder = 3,
			}),
			Kit.Button(scope, {
				Text = "Here",
				Order = 4,
				Size = Kit.Cell(5),
				OnActivated = function()
					local _, _, root = CharacterUtil.LiveRig(Players.LocalPlayer)
					if root then
						teleportX:set(tostring(math.floor(root.Position.X + 0.5)))
						teleportY:set(tostring(math.floor(root.Position.Y + 0.5)))
						teleportZ:set(tostring(math.floor(root.Position.Z + 0.5)))
					end
				end,
			}),
			Kit.Button(scope, {
				Text = "Go",
				Order = 5,
				Size = Kit.Cell(5),
				OnActivated = function()
					local x, y, z = readCoordinate(teleportX), readCoordinate(teleportY), readCoordinate(teleportZ)
					if x and y and z then
						props.Fire({ Kind = "TeleportCoords", X = x, Y = y, Z = z })
					end
				end,
			}),
		}),
		Kit.Prose(scope, 'Moves you. "Here" fills in where you are standing, to note a spot and come back to it.', 32),

		-- Fuel.
		Kit.Heading(scope, "BLIMP FUEL", 40),
		Kit.Row(scope, 41, {
			Kit.Button(scope, {
				Text = "Coal deposit",
				Order = 1,
				Size = Kit.Cell(3),
				OnActivated = function()
					props.Fire({ Kind = "SpawnCoal" })
				end,
			}),
			Kit.Button(scope, {
				Text = "Water source",
				Order = 2,
				Size = Kit.Cell(3),
				OnActivated = function()
					props.Fire({ Kind = "SpawnWater" })
				end,
			}),
			Kit.Button(scope, {
				Text = "Fill my fuel",
				Order = 3,
				Size = Kit.Cell(3),
				OnActivated = function()
					props.Fire({ Kind = "FillFuel" })
				end,
			}),
		}),
		Kit.Prose(scope, "The two nodes spawn in front of you to gather from; Fill my fuel skips the gathering.", 42),

		-- Vehicles.
		Kit.Heading(scope, "VEHICLES", 50),
		Kit.Prose(scope, props.VehicleRegistryText, 51, nil, Tokens.Color.TextSecondary),
		Kit.Prose(
			scope,
			scope:Computed(function(use)
				return use(props.VehicleRejectionText) or ""
			end),
			52,
			scope:Computed(function(use)
				return use(props.VehicleRejectionText) ~= nil
			end),
			Tokens.Color.Warning
		),
		Kit.Row(scope, 53, {
			Kit.Button(scope, {
				Text = "Refresh",
				Order = 1,
				Size = Kit.Cell(2),
				OnActivated = function()
					props.Fire({ Kind = "VehiclesRefresh" })
				end,
			}),
			Kit.Button(scope, {
				Text = "Rescan registry",
				Order = 2,
				Size = Kit.Cell(2),
				OnActivated = function()
					props.Fire({ Kind = "VehiclesRescan" })
				end,
			}),
		}),
		Label(scope, {
			Text = "Spawn at",
			Scale = "Body",
			Color = Tokens.Color.TextSecondary,
			Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + Tokens.Space.XS),
			LayoutOrder = 54,
		}),
		Stack.Row(scope, {
			Name = "Berths",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Gap = Tokens.Space.XS,
			Wraps = true,
			LayoutOrder = 55,
			Children = { berthChips :: any },
		}),
		Kit.Prose(scope, "No vehicles in the registry.", 56, noCatalog),
		list(scope, "Catalog", 57, catalogRows),
		Kit.Heading(scope, "LIVE VEHICLES", 58),
		Kit.Prose(scope, "Nothing spawned.", 59, noLive),
		list(scope, "Live", 60, liveRows),
		Kit.Armed(scope, {
			Idle = "Despawn every vehicle",
			Armed = "Despawn all? Again",
			Order = 61,
			Disabled = noLive,
			OnConfirm = function()
				props.Fire({ Kind = "VehiclesDespawnAll" })
			end,
		}),
	}

	return Kit.Page(scope, "WorldTab", props.Visible, children)
end

return WorldTab
