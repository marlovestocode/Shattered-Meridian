--!strict
--[[
	WorldArchitect/init.lua

	Owns: the World Architect's console -- the state every panel reads (Types.Handle), the one Intent signal they write
	through, and the docked layout: a tool strip along the top, the Assets / Scene dock on the left, the Inspect / Build /
	World / Optimize / Terrain dock on the right, and a status line along the bottom. Each dock collapses to its tab.

	DOCKED, NOT A CENTRED MODAL. A world editor that covers the world is useless, so this is one full-bleed surface whose
	middle is empty and click-through (the viewport's picking reads clicks that land there). It still OWNS INPUT while
	open -- Shell/ModalCount counts it like any modal, so UiModalOpen gates combat and a click in the world never swings.

	Does not own: what any control does (Client/DevTools/WorldArchitect/WorldArchitectClient.lua handles every Intent),
	or the 3D side (EditorViewport).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Tab = require(script.Parent.Parent.Parent.Components.Tab)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)
local Layers = require(script.Parent.Parent.Parent.Shell.Layers)
local Surface = require(script.Parent.Parent.Parent.Shell.Surface)
local ModalCount = require(script.Parent.Parent.Parent.Shell.ModalCount)
local ViewportScale = require(script.Parent.Parent.Parent.ViewportScale)

local WorldArchitectTypes = require(script.Types)
local Style = require(script.Style)
local Toolbar = require(script.Toolbar)
local AssetBrowser = require(script.AssetBrowser)
local Hierarchy = require(script.Hierarchy)
local Inspector = require(script.Inspector)
local BuildPanel = require(script.BuildPanel)
local WorldPanel = require(script.WorldPanel)
local OptimizePanel = require(script.OptimizePanel)
local TerrainPanel = require(script.TerrainPanel)

type Scope = Fusion.Scope<typeof(Fusion)>
type Handle = WorldArchitectTypes.Handle

export type WorldArchitectHandle = Handle

local peek = Fusion.peek

local WorldArchitect = {}

local LEFT_WIDTH = 300
local RIGHT_WIDTH = 340
local TOOLBAR_HEIGHT = 44
local STATUS_HEIGHT = 28
local MARGIN = Tokens.Space.L
local TAB_HEIGHT = 30
local COLLAPSED_HEIGHT = TAB_HEIGHT + Tokens.Space.S * 2

local TONE_COLOR = {
	Info = Tokens.Color.TextSecondary,
	Good = Tokens.Color.Positive,
	Warn = Tokens.Color.Warning,
	Bad = Tokens.Color.DangerBright,
}

-- Where the docks start: below the toolbar, which grows with the console's scale.
local function topOf(scale: number): number
	return MARGIN + TOOLBAR_HEIGHT * scale + Tokens.Space.M
end

-- A dock: a strip of tabs (plus a collapse chip) over the open tab's page.
local function dock(
	scope: Scope,
	name: string,
	tabs: { { Id: string, Text: string } },
	current: Fusion.Value<string>,
	open: Fusion.Value<boolean>,
	pages: { Instance },
	horizontal: UDim,
	anchor: Vector2,
	width: number,
	scale: Fusion.Computed<number>
): Frame
	local chips: { Instance } = {}
	for index, tab in tabs do
		table.insert(
			chips,
			Tab(scope, {
				Text = tab.Text,
				Selected = scope:Computed(function(use)
					return use(open) and use(current) == tab.Id
				end),
				Size = UDim2.new(1 / (#tabs + 0.6), -Tokens.Space.XS, 1, 0),
				LayoutOrder = index,
				OnActivated = function()
					if peek(current) == tab.Id then
						open:set(not peek(open))
					else
						current:set(tab.Id)
						open:set(true)
					end
				end,
			})
		)
	end
	table.insert(
		chips,
		Tab(scope, {
			Text = scope:Computed(function(use)
				return if use(open) then "–" else "+"
			end),
			Selected = false,
			Size = UDim2.new(0.6 / (#tabs + 0.6), -Tokens.Space.XS, 1, 0),
			LayoutOrder = #tabs + 1,
			OnActivated = function()
				open:set(not peek(open))
			end,
		})
	)
	-- The panel's own UIScale multiplies its Size, so the height it should FILL is divided back out: the dock then ends
	-- exactly above the status bar at any scale.
	return Panel(scope, {
		Name = name,
		AnchorPoint = anchor,
		Position = scope:Computed(function(use)
			return UDim2.new(horizontal, UDim.new(0, topOf(use(scale))))
		end),
		Scale = scale,
		Size = scope:Computed(function(use)
			local s = use(scale)
			return if use(open)
				then UDim2.new(0, width, 1 / s, -(topOf(s) + STATUS_HEIGHT * s + MARGIN * 2) / s)
				else UDim2.fromOffset(width, COLLAPSED_HEIGHT)
		end),
		Active = true,
		Elevated = true,
		CornerAccent = true,
		Children = {
			Stack.New(scope, {
				Name = "Column",
				Size = UDim2.fromScale(1, 1),
				Gap = Tokens.Space.S,
				Children = {
					scope:New "UIPadding" {
						PaddingTop = UDim.new(0, Tokens.Space.S),
						PaddingLeft = UDim.new(0, Tokens.Space.S),
						PaddingRight = UDim.new(0, Tokens.Space.S),
					},
					Stack.Row(scope, {
						Name = "Tabs",
						Size = UDim2.new(1, 0, 0, TAB_HEIGHT),
						Gap = Tokens.Space.XS,
						LayoutOrder = 1,
						Children = chips,
					}),
					Stack.Fill(
						scope,
						scope:New "Frame" {
							Name = "Pages",
							Size = UDim2.fromScale(1, 0),
							BackgroundTransparency = 1,
							ClipsDescendants = true,
							LayoutOrder = 2,
							Visible = open,
							[Fusion.Children] = pages,
						} :: Frame
					),
				},
			}),
		},
	})
end

function WorldArchitect.Mount(scope: Scope, playerGui: PlayerGui): Handle
	local intentEvent = Instance.new("BindableEvent")
	table.insert(scope, intentEvent)

	local handle: Handle = {
		IsOpen = scope:Value(false),
		Message = scope:Value("World Architect ready."),
		Tone = scope:Value("Info" :: WorldArchitectTypes.Tone),
		Records = scope:Value({} :: { [string]: WorldArchitectTypes.NodeRecord }),
		Selection = scope:Value({} :: { string }),
		Hidden = scope:Value({} :: { [string]: boolean }),
		Expanded = scope:Value({} :: { [string]: boolean }),
		Tool = scope:Value("Select" :: WorldArchitectTypes.Tool),
		DeepPick = scope:Value(false),
		Grid = scope:Value(ArchitectConstants.Editor.DefaultGrid),
		RotationStep = scope:Value(ArchitectConstants.Editor.DefaultRotation),
		Space = scope:Value("World" :: "World" | "Local"),
		SurfaceSnap = scope:Value(true),
		UndoLabel = scope:Value(nil :: string?),
		RedoLabel = scope:Value(nil :: string?),
		Templates = scope:Value({} :: { WorldArchitectTypes.TemplateSummary }),
		TemplateCache = scope:Value({} :: { [string]: any }),
		ActiveAsset = scope:Value(nil :: string?),
		FocusedAsset = scope:Value(nil :: string?),
		Favorites = scope:Value({} :: { [string]: boolean }),
		Recent = scope:Value({} :: { string }),
		Server = scope:Value(nil :: WorldArchitectTypes.ServerStatus?),
		Slots = scope:Value({} :: { any }),
		Report = scope:Value(nil :: any?),
		PreviewFindings = scope:Value({} :: { [string]: boolean }),
		Generation = scope:Value({
			Type = "SectCompound",
			Faction = "Celestial",
			Seed = 1,
			AreaX = 128,
			AreaZ = 128,
			Yaw = 0,
			Spacing = 6,
			Density = 0.5,
			RotationJitter = 180,
			Pack = "",
			FollowGround = true,
		} :: WorldArchitectTypes.GenerationSettings),
		GenerationPreview = scope:Value(nil :: WorldArchitectTypes.GenerationPreview?),
		Terrain = scope:Value({
			Mode = "Add",
			Material = "Grass",
			Radius = 8,
			Strength = 0.6,
		} :: WorldArchitectTypes.TerrainSettings),
		LeftOpen = scope:Value(true),
		RightOpen = scope:Value(true),
		LeftTab = scope:Value("Assets"),
		RightTab = scope:Value("Inspect"),
		Intent = intentEvent.Event,
		Fire = function(intent: WorldArchitectTypes.Intent)
			intentEvent:Fire(intent)
		end,
	} :: any

	local viewportScale = ViewportScale.Compute(scope)
	local scale = scope:Computed(function(use)
		return use(viewportScale) * Style.Readability
	end)

	local function page(id: string, current: Fusion.Value<string>): Fusion.Computed<boolean>
		return scope:Computed(function(use)
			return use(current) == id
		end)
	end

	local left = dock(
		scope,
		"LeftDock",
		{ { Id = "Assets", Text = "ASSETS" }, { Id = "Scene", Text = "SCENE" } },
		handle.LeftTab,
		handle.LeftOpen,
		{
			AssetBrowser(scope, handle, page("Assets", handle.LeftTab)),
			Hierarchy(scope, handle, page("Scene", handle.LeftTab)),
		},
		UDim.new(0, MARGIN),
		Vector2.zero,
		LEFT_WIDTH,
		scale
	)

	local right = dock(
		scope,
		"RightDock",
		{
			{ Id = "Inspect", Text = "INSPECT" },
			{ Id = "Build", Text = "BUILD" },
			{ Id = "World", Text = "WORLD" },
			{ Id = "Optimize", Text = "OPTIM" },
			{ Id = "Terrain", Text = "TERRAIN" },
		},
		handle.RightTab,
		handle.RightOpen,
		{
			Inspector(scope, handle, page("Inspect", handle.RightTab)),
			BuildPanel(scope, handle, page("Build", handle.RightTab)),
			WorldPanel(scope, handle, page("World", handle.RightTab)),
			OptimizePanel(scope, handle, page("Optimize", handle.RightTab)),
			TerrainPanel(scope, handle, page("Terrain", handle.RightTab)),
		},
		UDim.new(1, -MARGIN),
		Vector2.new(1, 0),
		RIGHT_WIDTH,
		scale
	)

	local statusRight = scope:Computed(function(use)
		local server = use(handle.Server)
		local selection = #use(handle.Selection)
		local parts: { string } = {}
		if selection > 0 then
			table.insert(parts, `{selection} selected`)
		end
		if server then
			table.insert(parts, `{server.Count} / {ArchitectConstants.Limits.MaxNodes} nodes`)
			if server.Strokes > 0 then
				table.insert(parts, `{server.Strokes} terrain strokes`)
			end
			table.insert(parts, `rev {server.Revision}`)
			table.insert(
				parts,
				if not server.StorageAvailable
					then "NO STORAGE"
					elseif server.Unpublished then "UNPUBLISHED"
					else "PUBLISHED"
			)
		end
		return table.concat(parts, "  ·  ")
	end)

	local statusBar = Panel(scope, {
		Name = "StatusBar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -MARGIN),
		Size = scope:Computed(function(use)
			local s = use(scale)
			return UDim2.new(1 / s, -MARGIN * 2 / s, 0, STATUS_HEIGHT)
		end),
		Scale = scale,
		Active = true,
		Children = {
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
			},
			Label(scope, {
				Text = handle.Message,
				Scale = "Body",
				Color = scope:Computed(function(use)
					return TONE_COLOR[use(handle.Tone)] or Tokens.Color.TextSecondary
				end),
				Size = UDim2.fromScale(0.6, 1),
				TextTruncate = Enum.TextTruncate.AtEnd,
			}),
			Label(scope, {
				Text = statusRight,
				Scale = "Numeral",
				Color = scope:Computed(function(use)
					local server = use(handle.Server)
					return if server and server.Unpublished then Tokens.Color.Warning else Tokens.Color.TextSecondary
				end),
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.fromScale(0.4, 1),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
		},
	})

	local screenGui = Surface.New(scope, {
		Name = "WorldArchitect",
		Layer = Layers.Modal,
		Parent = playerGui,
		Scaled = false,
		Enabled = handle.IsOpen,
		Children = {
			Toolbar(scope, handle, UDim2.new(0.5, 0, 0, MARGIN), TOOLBAR_HEIGHT, scale),
			left,
			right,
			statusBar,
		},
	})
	-- Gates gameplay input like any modal, but never dims the world: the world is what is being edited.
	ModalCount.Track(scope, screenGui, { KeepWorldVisible = true })

	return handle
end

return WorldArchitect
