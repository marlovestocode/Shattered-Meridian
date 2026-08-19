--!strict
--[[
	LiveConsole/init.lua

	Owns: the Live Admin Console (F5) panel -- log list, Server/My Client source tabs, and
	client-side-only level/text filters, Pause, and Clear. Follows CombatFeedback.lua/DevMenu's own
	"screen exposes state, client module drives it from outside" split: ServerEntries/ClientEntries
	are plain Fusion Values this screen renders from, written into entirely by
	Client/LiveConsole/LiveConsoleClient.lua (the Subscribe snapshot, batches off LiveConsole_Stream,
	and this VM's own local Logger.GetBufferSnapshot()/OnEntry feed) -- this screen never calls a
	remote and never reads Shared/Logger.lua directly.

	Source/level/search/Pause/Clear are all local-only UI state, not exposed on the handle -- nothing
	outside this file needs to read or drive them, the same "internal to the screen" scoping
	ContentArea.lua's own selectedTab keeps.

	Pause freezes the RENDERED list at whatever it held the instant Pause was pressed (frozenEntries,
	captured via peek) while ServerEntries/ClientEntries keep updating underneath -- unpausing simply
	resumes reading the live Value again, so nothing captured while paused is lost.

	No auto-scroll-to-bottom: newest entries append at the end of the list, same as every other
	scrollable list in this UI (ContentArea.lua's Reports tab included) -- an admin who has scrolled
	up to read history is never yanked back down by a new line arriving.

	Does not own: fetching/streaming (LiveConsoleClient.lua), authorization (LiveConsoleSystem.lua
	re-checks server-side regardless of whether this screen is even visible), or capture
	(Shared/Logger.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Logger = require(ReplicatedStorage.Shared.Logger)

local Tokens = require(script.Parent.Parent.Tokens)
local ModalScreen = require(script.Parent.Parent.Components.ModalScreen)
local Label = require(script.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Components.Tab)
local TextField = require(script.Parent.Parent.Components.TextField)
local ScrollArea = require(script.Parent.Parent.Components.ScrollArea)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

export type LiveConsoleSource = "Server" | "My Client"

export type LiveConsoleHandle = {
	IsOpen: Fusion.Value<boolean>,
	StatusText: Fusion.Value<string>,
	-- Driven entirely from outside -- see file header.
	ServerEntries: Fusion.Value<{ Logger.LogEntry }>,
	ClientEntries: Fusion.Value<{ Logger.LogEntry }>,
	-- Fired by the header's own close button instead of that button writing IsOpen directly -- same
	-- "the client module is the ONE place IsOpen is ever written" precedent Client/MoveEditor/
	-- MoveEditorClient.lua's own setOpen establishes, needed here because LiveConsoleClient.lua must
	-- call Unsubscribe on every close, not just the keybind-driven one.
	CloseRequested: BindableEvent,
}

local LiveConsole = {}

local ROOT_SIZE = UDim2.fromOffset(820, 560)
local HEADER_HEIGHT = 36
local TOOLBAR_HEIGHT = 36
local FOOTER_HEIGHT = 24

-- Ordered lowest to highest -- MinLevelIndex below is an index into this array, not a raw
-- Logger.LogLevel string, so "cycle to the next level" is a plain +1 wrapping around Off.
-- "Off" only ever means "one past Error" for the min-level filter's own last cycle step's label
-- ("Level: Off" reads as "hide everything"), not the Logging.Level meaning Constants.lua's
-- Debug.Logging.Level uses -- this filter never touches that config at all.
local LEVEL_ORDER: { Logger.LogLevel } = { "Trace", "Debug", "Info", "Warn", "Error", "Off" }

local LEVEL_RANK: { [string]: number } = {}
for index, level in ipairs(LEVEL_ORDER) do
	LEVEL_RANK[level] = index
end

local LEVEL_COLOR: { [string]: Color3 } = {
	Trace = Tokens.Color.TextDisabled,
	Debug = Tokens.Color.TextSecondary,
	Info = Tokens.Color.TextPrimary,
	Warn = Tokens.Color.Warning,
	Error = Tokens.Color.Danger,
}

-- Formats one entry as a single console line -- time, level, scope, message, and (if present) its
-- fields joined the same "key=val key2=val2" shape Shared/Logger.lua's own buildFieldsSuffix uses
-- for Output, so a line looks identical whether an admin is reading it here or in Studio.
-- pcall-wrapped: a field value this client can't tostring for whatever reason must never blank the
-- whole row.
local function formatEntryText(entry: Logger.LogEntry): string
	local ok, result = pcall(function()
		local timeText = os.date("%H:%M:%S", entry.TimestampUnix)
		local prefix = `[{timeText}][{entry.Side}][{entry.Scope}][{entry.Level}]`
		local fieldsSuffix = ""
		if entry.Fields then
			local parts = {}
			for key, value in pairs(entry.Fields) do
				table.insert(parts, `{tostring(key)}={tostring(value)}`)
			end
			table.sort(parts)
			if #parts > 0 then
				fieldsSuffix = " " .. table.concat(parts, " ")
			end
		end
		return `{prefix} {entry.Message}{fieldsSuffix}`
	end)
	if ok then
		return result
	end
	return `[{entry.Scope}][{entry.Level}] <unrenderable entry>`
end

-- One log line -- a small file-local builder, not a promoted Components/ primitive, same reasoning
-- ContentArea.lua's own reportRow gives for staying local to its one call site.
local function logRow(scope: Scope, entry: Logger.LogEntry, layoutOrder: number): TextLabel
	return Label(scope, {
		Text = formatEntryText(entry),
		Scale = "Detail",
		Color = LEVEL_COLOR[entry.Level] or Tokens.Color.TextPrimary,
		Size = UDim2.fromScale(1, 0),
		AutoHeight = true,
		LayoutOrder = layoutOrder,
	})
end

function LiveConsole.Mount(scope: Scope, playerGui: PlayerGui): LiveConsoleHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")
	local serverEntries: Fusion.Value<{ Logger.LogEntry }> = scope:Value({})
	local clientEntries: Fusion.Value<{ Logger.LogEntry }> = scope:Value({})

	local selectedSource: Fusion.Value<LiveConsoleSource> = scope:Value("Server")
	local minLevelIndex = scope:Value(1)
	local searchText = scope:Value("")
	local paused = scope:Value(false)
	local frozenEntries: Fusion.Value<{ Logger.LogEntry }> = scope:Value({})
	local closeRequestedEvent = Instance.new("BindableEvent")

	local minLevelText = scope:Computed(function(use)
		return `Level: {LEVEL_ORDER[use(minLevelIndex)]}+`
	end)

	local liveSourceEntries = scope:Computed(function(use)
		if use(selectedSource) == "Server" then
			return use(serverEntries)
		end
		return use(clientEntries)
	end)

	local displayedEntries = scope:Computed(function(use)
		if use(paused) then
			return use(frozenEntries)
		end
		return use(liveSourceEntries)
	end)

	local filteredEntries = scope:Computed(function(use)
		local minRank = LEVEL_RANK[LEVEL_ORDER[use(minLevelIndex)]] or 1
		local search = string.lower(use(searchText))
		local filtered: { Logger.LogEntry } = {}
		for _, entry in ipairs(use(displayedEntries)) do
			local rank = LEVEL_RANK[entry.Level] or 1
			if rank < minRank then
				continue
			end
			if #search > 0 then
				local haystack = string.lower(entry.Scope .. " " .. entry.Message)
				if not string.find(haystack, search, 1, true) then
					continue
				end
			end
			table.insert(filtered, entry)
		end
		return filtered
	end)

	local logRows = scope:ForPairs(filteredEntries, function(_use, innerScope, index, entry)
		return entry.Sequence, logRow(innerScope, entry, index)
	end)

	local function sourceTab(source: LiveConsoleSource, layoutOrder: number): TextButton
		return Tab(scope, {
			Text = source,
			Selected = scope:Computed(function(use)
				return use(selectedSource) == source
			end),
			Size = UDim2.fromOffset(96, Tokens.Control.StepButtonSize),
			LayoutOrder = layoutOrder,
			OnActivated = function()
				selectedSource:set(source)
			end,
		})
	end

	ModalScreen(scope, playerGui, {
		Name = "LiveConsole",
		Size = ROOT_SIZE,
		IsOpen = isOpen,

		Children = {
			-- Header: title, Server/My Client source tabs, close button.
			scope:New "Frame" {
				Name = "Header",
				Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					Label(scope, {
						Text = "Live Admin Console",
						Scale = "Heading",
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.fromScale(0, 0.5),
					}),
					scope:New "Frame" {
						Name = "SourceTabs",
						AutomaticSize = Enum.AutomaticSize.X,
						Size = UDim2.fromOffset(0, Tokens.Control.StepButtonSize),
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.new(1, -Tokens.Control.CloseButtonClearance - Tokens.Space.M, 0.5, 0),
						BackgroundTransparency = 1,

						[Children] = {
							scope:New "UIListLayout" {
								FillDirection = Enum.FillDirection.Horizontal,
								Padding = UDim.new(0, Tokens.Space.S),
								SortOrder = Enum.SortOrder.LayoutOrder,
							},
							sourceTab("Server", 1),
							sourceTab("My Client", 2),
						},
					},
					Button(scope, {
						Text = "X",
						Size = UDim2.fromOffset(28, 28),
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.fromScale(1, 0.5),
						OnActivated = function()
							closeRequestedEvent:Fire()
						end,
					}),
				},
			},

			-- Toolbar: min-level cycle, search, Pause, Clear.
			scope:New "Frame" {
				Name = "Toolbar",
				Size = UDim2.new(1, 0, 0, TOOLBAR_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = minLevelText,
						Size = UDim2.fromOffset(110, Tokens.Control.StepButtonSize),
						LayoutOrder = 1,
						OnActivated = function()
							local nextIndex = peek(minLevelIndex) + 1
							if nextIndex > #LEVEL_ORDER then
								nextIndex = 1
							end
							minLevelIndex:set(nextIndex)
						end,
					}),
					TextField(scope, {
						Text = searchText,
						PlaceholderText = "Search...",
						Size = UDim2.fromOffset(220, Tokens.Control.StepButtonSize),
						LayoutOrder = 2,
					}),
					Tab(scope, {
						Text = "Pause",
						Selected = paused,
						Size = UDim2.fromOffset(80, Tokens.Control.StepButtonSize),
						LayoutOrder = 3,
						OnActivated = function()
							local nowPaused = not peek(paused)
							if nowPaused then
								frozenEntries:set(peek(liveSourceEntries))
							end
							paused:set(nowPaused)
						end,
					}),
					Button(scope, {
						Text = "Clear",
						Size = UDim2.fromOffset(80, Tokens.Control.StepButtonSize),
						LayoutOrder = 4,
						OnActivated = function()
							if peek(selectedSource) == "Server" then
								serverEntries:set({})
							else
								clientEntries:set({})
							end
						end,
					}),
				},
			},

			ScrollArea(scope, {
				Name = "LogList",
				Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + TOOLBAR_HEIGHT + FOOTER_HEIGHT + Tokens.Space.M * 3)),
				LayoutOrder = 3,
				BackgroundColor3 = Tokens.Color.Background,
				BackgroundTransparency = 0,

				Children = {
					scope:New "UICorner" {
						CornerRadius = Tokens.Radius.Sharp,
					},
					scope:New "UIPadding" {
						PaddingTop = UDim.new(0, Tokens.Space.S),
						PaddingBottom = UDim.new(0, Tokens.Space.S),
						PaddingLeft = UDim.new(0, Tokens.Space.S),
						PaddingRight = UDim.new(0, Tokens.Space.S),
					},
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						Padding = UDim.new(0, 2),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					logRows,
				},
			}),

			Label(scope, {
				Text = statusText,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT),
				LayoutOrder = 4,
			}),
		},
	})

	return {
		IsOpen = isOpen,
		StatusText = statusText,
		ServerEntries = serverEntries,
		ClientEntries = clientEntries,
		CloseRequested = closeRequestedEvent,
	}
end

return LiveConsole
