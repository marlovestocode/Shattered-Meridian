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
local ScreenFrame = require(script.Parent.Parent.Components.ScreenFrame)
local Stack = require(script.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Components.Inset)
local Label = require(script.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Components.Tab)
local TextField = require(script.Parent.Parent.Components.TextField)
local ScrollArea = require(script.Parent.Parent.Components.ScrollArea)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

-- The two log sources. Still exported and still the truth about what this panel can show, but no
-- longer the type of a Value here: the selection now lives in Components/ScreenFrame.lua's tab state,
-- which is keyed by plain strings because it cannot know any one screen's union. TAB_NAMES below is
-- the list that has to agree with this.
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

local ROOT_WIDTH = 820
local ROOT_HEIGHT = 560
local TOOLBAR_HEIGHT = 36

-- The two log sources ARE this panel's tabs, and were already drawn as Tab buttons before the frame
-- existed -- they just lived in a header band of their own, at the far right, beside a title that
-- said what the tab strip now says. Moving them into Components/ScreenFrame.lua's strip is the whole
-- of this screen's migration: same control, same behaviour, one band fewer.
local TAB_NAMES: { string } = { "Server", "My Client" }

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

	local tabs = ScreenFrame.NewTabState(scope, TAB_NAMES)
	local minLevelIndex = scope:Value(1)
	local searchText = scope:Value("")
	local paused = scope:Value(false)
	local frozenEntries: Fusion.Value<{ Logger.LogEntry }> = scope:Value({})
	local closeRequestedEvent = Instance.new("BindableEvent")

	local minLevelText = scope:Computed(function(use)
		return `Level: {LEVEL_ORDER[use(minLevelIndex)]}+`
	end)

	local liveSourceEntries = scope:Computed(function(use)
		if use(tabs.Current) == "Server" then
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

	ScreenFrame.Mount(scope, playerGui, {
		Name = "LiveConsole",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		IsOpen = isOpen,
		Tabs = tabs,
		Wordmark = "LIVE CONSOLE",
		StatusText = statusText,
		-- Fires the signal rather than writing IsOpen -- see LiveConsoleHandle.CloseRequested's own
		-- comment. This screen is the reason ScreenFrame takes a callback here instead of a Value.
		OnClose = function()
			closeRequestedEvent:Fire()
		end,

		Body = Stack.New(scope, {
			Name = "Body",
			Gap = Tokens.Space.M,
			Children = {
				Inset(scope, { Top = Tokens.Space.M, Bottom = Tokens.Space.L, X = Tokens.Space.L }),

				-- Toolbar: min-level cycle, search, Pause, Clear.
				Stack.Row(scope, {
					Name = "Toolbar",
					Size = UDim2.new(1, 0, 0, TOOLBAR_HEIGHT),
					Gap = Tokens.Space.S,
					AlignY = Enum.VerticalAlignment.Center,
					LayoutOrder = 1,
					Children = {
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
								if peek(tabs.Current) == "Server" then
									serverEntries:set({})
								else
									clientEntries:set({})
								end
							end,
						}),
					},
				}),

				-- The log itself takes everything the toolbar left. That subtraction used to be a
				-- four-term sum of three band heights and three gaps (docs/architecture/
				-- 2026-08-20-ui-velocity-plan.md section 2.1's worst kind), and two of those bands are
				-- not even this file's any more.
				Stack.Fill(
					scope,
					ScrollArea(scope, {
						Name = "LogList",
						Size = UDim2.fromScale(1, 1),
						LayoutOrder = 2,
						BackgroundColor3 = Tokens.Color.Background,
						BackgroundTransparency = 0,

						Children = {
							scope:New "UICorner" {
								CornerRadius = Tokens.Radius.Sharp,
							},
							Inset(scope, Tokens.Space.S),
							scope:New "UIListLayout" {
								FillDirection = Enum.FillDirection.Vertical,
								Padding = UDim.new(0, 2),
								SortOrder = Enum.SortOrder.LayoutOrder,
							},
							logRows,
						},
					})
				),
			},
		}),
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
