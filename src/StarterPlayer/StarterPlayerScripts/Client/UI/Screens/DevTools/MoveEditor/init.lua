--!strict
--[[
	MoveEditor/init.lua

	Owns: the Move Editor screen -- the admin tool that authors every combat move as data -- and the
	Values and signals on its handle (Types.lua). Rebuilt from nothing on 2026-09-29 alongside the schema,
	the registries and the server System; see docs/design/move-editor-guide.md for how it is used.

	THE FRAME IS Components/ScreenFrame, like every modal here: a tab strip, a body, a footer carrying the
	answer to the last action. The body is a row of three, and the reason for each column is what it is
	FOR while an author works:

	    Browser (rail)   every move, grouped, with its save state -- where you go to pick
	    Form (tabs)      the move TYPE bar, then the inputs, one concern per tab -- and Tools, for what
	                     acts on more than one move's inputs (bulk, history, source)
	    Readout (rail)   plots, the effective timeline, notes, actions -- the RESULTS of those inputs

	THE MOVE TYPE IS THE FIRST QUESTION, AND IT RESHAPES THE FORM (2026-10-01). A custom move is Melee,
	Projectile or a Domain Expansion, chosen in a segmented bar above the pages. It is not a field on a tab,
	because it decides which tabs there ARE (ScreenFrame.NewTabState's availability):

	    Melee, Projectile    Hitbox  Timing  Impact  Presentation  Identity  Tools
	    Domain Expansion     Realm  Timing  Presentation  Identity  Tools
	                         (Realm's own sub-tab bar: Core  Boundary  Effects  Law  Clash -- REALM_PAGES)

	THE 2026-10-07 PASS, for ease of use: the Realm sub-tabs above (nine top-level labels were too many for the
	strip); a help strip under the form showing the hint of the field you are on, with a "Show hints" switch
	to draw them all inline (Fields.lua's HINTS ARE ON DEMAND); a dot on every field that differs from the
	saved move (CHANGED FIELDS, compared against SavedMove); the readout's pinned action bar; a timeline you
	can drag and scrub (TimelineBar); typed New, type tags and arrow keys in the browser; and FitToViewport,
	so the panel shrinks onto a screen smaller than itself.

	A domain expansion shows only what a realm reads -- no volume to place, no Impact tab (its own strike's
	price is on Effects) -- and still everything a move has: Timing (its cast), Presentation, Identity, Tools,
	the readout. The type IS the blocks: Projectile seeds MoveDefinition.Projectile, Domain Expansion seeds
	.Domain, each drops the other and any grab (Validate refuses a grab on either), Melee drops both. Nothing
	holds a separate "type" field that could fall out of step with them. Switching type is an edit like any
	other, so undo brings back the block it dropped.

	PAGES ARE BUILT ON FIRST VISIT (Fields.Lazy), and inside them each group on first open (Fields.Section):
	a session that never opens Clash never builds it. A built page is kept, so it keeps its scroll position.

	Both rails are pinned, so a result is never a tab switch away from the input that caused it (the
	character menu's IdentityRail argument). The form takes whatever the rails leave (Stack.Fill), not a
	width computed from theirs.

	NO CARDS. Groups inside a column are separated by a bronze SectionHeading and spacing, never by a
	bordered box inside the panel's own border -- ScreenFrame's header, and the reason the old editor's
	Section-card stack was the first thing this rebuild removed.

	EDITS ARE OPTIMISTIC AND FLOW ONE WAY. A field edit clones the draft, mutates the clone, sets Draft
	(so every field, both plots and the dirty chip update the same frame) and fires DraftEdited; the
	driver debounces that into a Preview and writes the server's answer back. Nothing in this screen
	calls a remote.

	UNDO LIVES HERE, not in the driver: it is a property of the edits this screen makes, and an undo is
	just one more edit -- it sets Draft and fires DraftEdited like any field, so the driver previews it
	with no special case. Every edit records the draft it replaced (Shared/Authoring/DraftHistory.lua,
	one stack per move, a burst of edits coalesced into one step). The server's own answers written back
	into Draft are not edits and are never recorded.

	Does not own: any network call, authorization, or what an action does -- Client/DevTools/MoveEditor/
	MoveEditorClient.lua drives this screen from outside.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local DraftHistory = require(ReplicatedStorage.Shared.Authoring.DraftHistory)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)
local TrainingBotConstants = require(ReplicatedStorage.Shared.TrainingBot.TrainingBotConstants)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local ScreenFrame = require(script.Parent.Parent.Parent.Components.ScreenFrame)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)
local Tab = require(script.Parent.Parent.Parent.Components.Tab)

local Browser = require(script.Browser)
local Copy = require(script.Copy)
local DomainTab = require(script.DomainTab)
local Fields = require(script.Fields)
local HitboxTab = require(script.HitboxTab)
local IdentityTab = require(script.IdentityTab)
local ImpactTab = require(script.ImpactTab)
local MoveEditorScreenTypes = require(script.Types)
local PlacementBar = require(script.PlacementBar)
local PresentationTab = require(script.PresentationTab)
local Readout = require(script.Readout)
local TimingTab = require(script.TimingTab)
local ToolsTab = require(script.ToolsTab)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type MoveEntry = MoveEditorTypes.MoveEntry

export type MoveEditorHandle = MoveEditorScreenTypes.MoveEditorHandle

local MoveEditor = {}

local ROOT_WIDTH = 1240
local ROOT_HEIGHT = 780
local BROWSER_WIDTH = 272
local READOUT_WIDTH = 344

-- One strip order for every type; the availability below hides what a type does not have.
local TAB_NAMES: { string } = {
	"Hitbox",
	"Realm",
	"Timing",
	"Impact",
	"Presentation",
	"Identity",
	"Tools",
}

-- A domain expansion's one tab, and the two it does not have.
local DOMAIN_TABS = { "Realm" }
local VOLUME_TABS = { "Hitbox", "Impact" }

-- The Realm tab's own pages, under its sub-tab bar (2026-10-07: these were five top-level tabs, which left
-- nine labels sharing the strip). The keys are the page names the rest of the editor uses -- Copy's refusal
-- routing, ShowPage -- and "Realm" is the clock/cost page, shown as "Core" so the bar does not repeat its
-- own tab's name.
local REALM_PAGES: { string } = { "Realm", "Boundary", "Effects", "Law", "Clash" }
local REALM_PAGE_TEXT: { [string]: string } = {
	Realm = "Core",
	Boundary = "Boundary",
	Effects = "Effects",
	Law = "Law",
	Clash = "Clash",
}
local HELP_HEIGHT = 50
local HELP_IDLE = "Point at a field -- or select it with a gamepad -- to see what it does here."

local MOVE_TYPE_OPTIONS = {
	{ Value = "Melee", Text = "Melee" },
	{ Value = "Projectile", Text = "Projectile" },
	{ Value = "Domain", Text = "Domain Expansion" },
}

-- Which type a move is: the blocks it carries (see this file's header). Public, with setMoveType, for the
-- screen spec: they are the whole of what the type bar does to a move.
local function moveTypeOf(move: MoveTypes.MoveDefinition): string
	if move.Domain ~= nil then
		return "Domain"
	end
	return if move.Projectile ~= nil then "Projectile" else "Melee"
end

-- Makes `move` the given type. Re-choosing the current type re-applies it, which is also how an old record
-- carrying both a realm and a grab (or a projectile) is cleaned up: Copy's DomainCannotGrab says so.
local function setMoveType(move: MoveTypes.MoveDefinition, kind: string): ()
	if kind == "Domain" then
		move.Domain = move.Domain or DomainTypes.Defaults()
		move.Projectile = nil
		move.Grab = nil
	elseif kind == "Projectile" then
		move.Projectile = move.Projectile or ProjectileTypes.Defaults()
		move.Domain = nil
		move.Grab = nil
	else
		move.Projectile = nil
		move.Domain = nil
	end
end

MoveEditor.MoveTypeOf = moveTypeOf
MoveEditor.SetMoveType = setMoveType

function MoveEditor.Mount(scope: Scope, playerGui: PlayerGui): MoveEditorHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")
	local entries = scope:Value({} :: { MoveEntry })
	local hotbarBindings = scope:Value({} :: { [number]: string? })
	local volumesVisible = scope:Value(false)
	local dummyGuard = scope:Value(false)
	local botStyle = scope:Value(TrainingBotConstants.DefaultStyle :: string)
	local botDifficulty = scope:Value(TrainingBotConstants.DefaultDifficulty :: string)
	local hitLog = scope:Value({} :: { MoveEditorScreenTypes.HitLogEntry })
	local showOnCharacter = scope:Value(true)
	local placementMode = scope:Value(false)
	local placementTool = scope:Value("Move")
	local placementSnap = scope:Value(0.25)
	local historyVersions = scope:Value(nil :: { MoveEditorTypes.HistoryVersion }?)
	local exportText = scope:Value(nil :: string?)
	local selectedId = scope:Value(nil :: string?)
	local draft = scope:Value(nil :: MoveTypes.MoveDefinition?)
	-- The form's "Show hints" switch (Fields.lua's HINTS ARE ON DEMAND). Off: the help strip carries them.
	local hintsShown = scope:Value(false)
	-- Which of the Realm tab's pages is shown (REALM_PAGES).
	local realmPage = scope:Value(REALM_PAGES[1])
	-- The clip scrub (TimelineBar, driven by the client): a swing time the clip is held at on your own
	-- character, or nil while nothing is scrubbed; Playing runs it forward at real speed.
	local scrubTime = scope:Value(nil :: number?)
	local scrubPlaying = scope:Value(false)
	-- The move rows the browser shows, in order -- what the arrow keys step through.
	local browserOrder = scope:Value({} :: { string })
	local filterBox = scope:Value(nil :: TextBox?)
	local isDomain = scope:Computed(function(use)
		local current = use(draft)
		return current ~= nil and current.Domain ~= nil
	end)
	local notDomain = scope:Computed(function(use)
		return not use(isDomain)
	end)
	local availability: { [string]: Fusion.UsedAs<boolean> } = {}
	for _, name in DOMAIN_TABS do
		availability[name] = isDomain
	end
	for _, name in VOLUME_TABS do
		availability[name] = notDomain
	end
	local tabs = ScreenFrame.NewTabState(scope, TAB_NAMES, availability)

	local selectedEntry = scope:Computed(function(use): MoveEntry?
		local id = use(selectedId)
		if not id then
			return nil
		end
		for _, entry in ipairs(use(entries)) do
			if entry.Move.MoveId == id then
				return entry
			end
		end
		return nil
	end)
	local isDirty = scope:Computed(function(use)
		local current = use(draft)
		if not current then
			return false
		end
		local entry = use(selectedEntry)
		-- No entry yet is a brand-new move the server has not answered for: unsaved by definition.
		return entry == nil or entry.SavedFingerprint ~= MoveTypes.Fingerprint(current)
	end)
	local isDefault = scope:Computed(function(use)
		local entry = use(selectedEntry)
		return entry ~= nil and entry.Source == "Default"
	end)
	local hasDraft = scope:Computed(function(use)
		return use(draft) ~= nil
	end)
	-- The open move as it is SAVED, for the changed-field dots: the entry carries it whenever the live move
	-- differs (MoveEditorTypes.MoveEntry.Saved); when it does not, the live move IS the saved one.
	local savedMove = scope:Computed(function(use): MoveTypes.MoveDefinition?
		local entry = use(selectedEntry)
		if entry == nil or entry.SavedFingerprint == nil then
			return nil
		end
		if entry.Saved then
			return entry.Saved
		end
		return if entry.SavedFingerprint == MoveTypes.Fingerprint(entry.Move) then entry.Move else nil
	end)

	-- Raw BindableEvents need registering with the scope to be cleaned up with it (Studio hot reload
	-- re-runs Mount) -- see Screens/Menus/init.lua.
	local function signal(): BindableEvent
		local event = Instance.new("BindableEvent")
		table.insert(scope, event)
		return event
	end
	local closeRequested = signal()
	local selectRequested = signal()
	local newRequested = signal()
	local duplicateRequested = signal()
	local draftEdited = signal()
	local saveRequested = signal()
	local revertRequested = signal()
	local deleteRequested = signal()
	local resetDefaultRequested = signal()
	local testRequested = signal()
	local bindSlotRequested = signal()
	local spawnDummyRequested = signal()
	local volumesToggled = signal()
	local dummyGuardToggled = signal()
	local spawnBotRequested = signal()
	local clearBenchRequested = signal()
	local clearHitLogRequested = signal()
	local bulkScaleRequested = signal()
	local loadHistoryRequested = signal()
	local restoreVersionRequested = signal()
	local writeToSourceRequested = signal()
	local removeFromSourceRequested = signal()
	local exportSourceRequested = signal()
	local previewCueRequested = signal()
	local previewAssetRequested = signal()

	local history = DraftHistory.new(Constants.MoveEditor.UndoDepth, Constants.MoveEditor.UndoCoalesceSeconds)
	-- DraftHistory is plain data; this bumps whenever it changes so CanUndo/CanRedo recompute.
	local historyVersion = scope:Value(0)
	local function historyChanged(): ()
		historyVersion:set(peek(historyVersion) + 1)
	end
	local function canStep(ask: (DraftHistory.History, string) -> boolean)
		return scope:Computed(function(use)
			use(historyVersion)
			local current = use(draft)
			return current ~= nil and current.MoveId ~= "" and ask(history, current.MoveId)
		end)
	end
	local canUndo = canStep(DraftHistory.CanUndo)
	local canRedo = canStep(DraftHistory.CanRedo)

	-- Replaces the draft with one the history handed back, exactly as an edit would.
	local function step(take: (DraftHistory.History, string, MoveTypes.MoveDefinition) -> MoveTypes.MoveDefinition?)
		local current = peek(draft)
		if not current or current.MoveId == "" then
			return
		end
		local target = take(history, current.MoveId, current)
		if not target then
			return
		end
		historyChanged()
		draft:set(target)
		draftEdited:Fire(target)
	end
	local function undo(): ()
		step(DraftHistory.Undo)
	end
	local function redo(): ()
		step(DraftHistory.Redo)
	end

	-- The help strip (Fields.lua's HINTS ARE ON DEMAND): every registered field frame says what it is when the
	-- pointer is on it, a control inside it is selected, or a text box inside it has focus. Weak keys: a frame
	-- a scope destroys drops out with it.
	local helpTitle = scope:Value("")
	local helpText = scope:Value("")
	local helpOwner: Instance? = nil
	local helpOf: { [Instance]: { Title: string, Hint: Fusion.UsedAs<string>? } } = setmetatable({}, { __mode = "k" }) :: any
	local function showHelp(owner: Instance): ()
		local help = helpOf[owner]
		if not help then
			return
		end
		helpOwner = owner
		helpTitle:set(help.Title)
		local hint = if help.Hint == nil then "" else peek(help.Hint)
		helpText:set(if hint ~= "" then hint else "No notes for this one -- its label is the whole story.")
	end
	local function hideHelp(owner: Instance): ()
		if helpOwner == owner then
			helpOwner = nil
			helpTitle:set("")
			helpText:set("")
		end
	end
	-- The nearest registered frame at or above `instance`.
	local function helpAt(instance: Instance?): Instance?
		local cursor = instance
		while cursor do
			if helpOf[cursor] then
				return cursor
			end
			cursor = cursor.Parent
		end
		return nil
	end
	local function followFocus(instance: Instance?): ()
		local owner = helpAt(instance)
		if owner then
			showHelp(owner)
		end
	end
	-- Selection and text focus are not on every client (and not in a headless spec), so each is optional.
	pcall(function()
		local GuiService = game:GetService("GuiService")
		table.insert(
			scope,
			GuiService:GetPropertyChangedSignal("SelectedObject"):Connect(function()
				followFocus(GuiService.SelectedObject)
			end)
		)
	end)
	pcall(function()
		local UserInputService = game:GetService("UserInputService")
		table.insert(scope, UserInputService.TextBoxFocused:Connect(followFocus))
	end)

	local context: Fields.FormContext = {
		Draft = draft,
		IsDefault = isDefault,
		Entry = selectedEntry,
		Saved = savedMove,
		Entries = entries,
		Hints = hintsShown,
		RegisterHelp = function(holder: GuiObject, title: string, hint: Fusion.UsedAs<string>?)
			helpOf[holder] = { Title = title, Hint = hint }
			table.insert(
				scope,
				holder.MouseEnter:Connect(function()
					showHelp(holder)
				end)
			)
			table.insert(
				scope,
				holder.MouseLeave:Connect(function()
					hideHelp(holder)
				end)
			)
		end,
		PreviewAsset = function(kind: string, id: string)
			previewAssetRequested:Fire(kind, id)
		end,
		Edit = function(mutate)
			local current = peek(draft)
			if not current then
				return
			end
			local nextDraft = MoveTypes.Clone(current)
			mutate(nextDraft)
			-- A move the server has not named yet has nowhere to file its history.
			if current.MoveId ~= "" then
				history:Record(current.MoveId, current, os.clock())
				historyChanged()
			end
			draft:set(nextDraft)
			draftEdited:Fire(nextDraft)
		end,
	}

	local function pageVisible(name: string)
		return scope:Computed(function(use)
			return use(tabs.Selected[name]) and use(hasDraft)
		end)
	end
	-- A page, built the first time its tab is shown (see this file's header).
	local function page(name: string, build: (visible: Fusion.Computed<boolean>) -> Instance): Frame
		local visible = pageVisible(name)
		return Fields.Lazy(scope, {
			Name = `{name}Page`,
			Visible = visible,
			Build = function()
				return { build(visible) }
			end,
		})
	end

	local currentType = scope:Computed(function(use): string
		local current = use(draft)
		return if current then moveTypeOf(current) else "Melee"
	end)
	local showTypeBar = scope:Computed(function(use)
		return use(hasDraft) and not use(isDefault)
	end)
	-- The move type bar (see this file's header). A weapon stage is always melee and shows none.
	local typeBarChildren: { Instance } = {
		Fields.Segmented(scope, {
			Options = MOVE_TYPE_OPTIONS,
			Value = currentType,
			LayoutOrder = 1,
			OnChanged = function(kind: string)
				context.Edit(function(move)
					setMoveType(move, kind)
				end)
			end,
		}),
		Fields.Prose(
			scope,
			scope:Computed(function(use)
				return Copy.Hints.MoveTypes[use(currentType)] or ""
			end),
			2
		),
	}
	local typeBar = Stack.New(scope, {
		Name = "TypeBar",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		LayoutOrder = 1,
		Visible = showTypeBar,
		Children = typeBarChildren,
	})

	-- The Realm tab: its sub-tab bar over five pages, each built on its first visit like a top-level page.
	local function realmTab(visible: Fusion.Computed<boolean>): Instance
		local builders: { [string]: (Fusion.Computed<boolean>) -> Instance } = {
			Realm = function(shown)
				return DomainTab.Realm(scope, context, shown)
			end,
			Boundary = function(shown)
				return DomainTab.Boundary(scope, context, shown, { ShowOnCharacter = showOnCharacter })
			end,
			Effects = function(shown)
				return DomainTab.Effects(scope, context, shown)
			end,
			Law = function(shown)
				return DomainTab.Law(scope, context, shown)
			end,
			Clash = function(shown)
				return DomainTab.Clash(scope, context, shown)
			end,
		}
		local subPages: { Instance } = {}
		local options: { Fields.Option } = {}
		for _, name in REALM_PAGES do
			table.insert(options, { Value = name, Text = REALM_PAGE_TEXT[name] })
			local shown = scope:Computed(function(use)
				return use(visible) and use(realmPage) == name
			end)
			table.insert(
				subPages,
				Fields.Lazy(scope, {
					Name = `{name}Page`,
					Visible = shown,
					Build = function()
						return { builders[name](shown) }
					end,
				})
			)
		end
		return Stack.New(scope, {
			Name = "RealmPages",
			Size = UDim2.fromScale(1, 1),
			Gap = Tokens.Space.S,
			Children = {
				Fields.Segmented(scope, {
					Options = options,
					Value = realmPage,
					LayoutOrder = 1,
					OnChanged = function(name: string)
						realmPage:set(name)
					end,
				}),
				Stack.Fill(
					scope,
					scope:New "Frame" {
						Name = "RealmPageHolder",
						Size = UDim2.fromScale(1, 0),
						BackgroundTransparency = 1,
						LayoutOrder = 2,
						[Fusion.Children] = subPages,
					}
				),
			},
		})
	end

	-- Shows a page by the name the editor files it under: a top-level tab, or one of the Realm tab's pages.
	local function showPage(name: string): ()
		if table.find(REALM_PAGES, name) then
			tabs.Current:set("Realm")
			realmPage:set(name)
		else
			tabs.Current:set(name)
		end
	end

	-- Steps the open move through the browser's visible rows (the arrow keys).
	local function stepSelection(delta: number): ()
		local order = peek(browserOrder)
		if #order == 0 then
			return
		end
		local index = table.find(order, peek(selectedId) or "")
		local nextIndex = if index then math.clamp(index + delta, 1, #order) elseif delta > 0 then 1 else #order
		local target = order[nextIndex]
		if target and target ~= peek(selectedId) then
			selectRequested:Fire(target)
		end
	end

	local placeInWorld = function()
		if peek(draft) then
			placementMode:set(true)
		end
	end

	-- Exactly one page is visible at a time, each at the holder's origin; a page is a full-height ScrollArea.
	local pageList: { Instance } = {
		page("Hitbox", function(visible)
			return HitboxTab(scope, context, visible, {
				ShowOnCharacter = showOnCharacter,
				OnPlace = placeInWorld,
			})
		end),
		page("Realm", function(visible)
			return realmTab(visible)
		end),
		page("Timing", function(visible)
			return TimingTab(scope, context, visible)
		end),
		page("Impact", function(visible)
			return ImpactTab(scope, context, visible)
		end),
		page("Presentation", function(visible)
			return PresentationTab(scope, context, {
				OnPreview = function(moment: string)
					previewCueRequested:Fire(moment)
				end,
			}, visible)
		end),
		page("Identity", function(visible)
			return IdentityTab(scope, context, visible)
		end),
		page("Tools", function(visible)
			return ToolsTab(scope, {
				Entry = selectedEntry,
				Entries = entries,
				OnBulkScale = function(request: MoveEditorTypes.BulkScaleRequest)
					bulkScaleRequested:Fire(request)
				end,
				History = historyVersions,
				OnLoadHistory = function()
					loadHistoryRequested:Fire()
				end,
				OnRestoreVersion = function(version: number)
					restoreVersionRequested:Fire(version)
				end,
				ExportText = exportText,
				OnWriteToSource = function()
					writeToSourceRequested:Fire()
				end,
				OnRemoveFromSource = function()
					removeFromSourceRequested:Fire()
				end,
				OnExportSource = function()
					exportSourceRequested:Fire()
				end,
			}, visible)
		end),
		Label(scope, {
			Text = "Pick a move on the left, or make a new one.",
			Scale = "Body",
			Color = Tokens.Color.TextDisabled,
			Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
			Visible = scope:Computed(function(use)
				return not use(hasDraft)
			end),
		}),
	}
	local pages = scope:New "Frame" {
		Name = "Pages",
		Size = UDim2.fromScale(1, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 2,
		[Fusion.Children] = pageList,
	} :: Frame

	-- Under the pages: the hint of the field you are on, and the switch that draws every hint inline instead.
	local helpStrip = Stack.Row(scope, {
		Name = "HelpStrip",
		Size = UDim2.new(1, 0, 0, HELP_HEIGHT),
		Gap = Tokens.Space.M,
		AlignY = Enum.VerticalAlignment.Center,
		LayoutOrder = 3,
		Visible = hasDraft,
		Children = {
			Stack.Fill(
				scope,
				Stack.New(scope, {
					Name = "Help",
					Size = UDim2.fromScale(0, 1),
					Gap = 2,
					LayoutOrder = 1,
					Children = {
						Label(scope, {
							Text = helpTitle,
							Scale = "Body",
							Color = Tokens.Color.TextPrimary,
							Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + 2),
							TextTruncate = Enum.TextTruncate.AtEnd,
							LayoutOrder = 1,
							Visible = scope:Computed(function(use)
								return use(helpTitle) ~= ""
							end),
						}),
						Label(scope, {
							Text = scope:Computed(function(use)
								local text = use(helpText)
								return if text ~= "" then text else HELP_IDLE
							end),
							Scale = "Detail",
							Color = Tokens.Color.TextSecondary,
							Size = UDim2.new(1, 0, 1, -(Tokens.Type.Body.Size + 4)),
							TextWrapped = true,
							TextTruncate = Enum.TextTruncate.AtEnd,
							LayoutOrder = 2,
						}),
					},
				})
			),
			Tab(scope, {
				Text = "Show hints",
				Selected = hintsShown,
				Size = UDim2.fromOffset(104, Tokens.Control.StepButtonSize - 4),
				LayoutOrder = 2,
				OnActivated = function()
					hintsShown:set(not peek(hintsShown))
				end,
			}),
		},
	})

	local formChildren: { Instance } = {
		Inset(scope, { Top = Tokens.Space.M, Bottom = Tokens.Space.S, X = Tokens.Space.L }),
		typeBar,
		-- The pages take whatever the type bar and the help strip leave.
		Stack.Fill(scope, pages),
		helpStrip,
	}
	local form = Stack.New(scope, {
		Name = "Form",
		LayoutOrder = 2,
		Gap = Tokens.Space.M,
		ClipsDescendants = true,
		Children = formChildren,
	})

	ScreenFrame.Mount(scope, playerGui, {
		Name = "MoveEditor",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		-- Shrinks to fit a screen smaller than the panel (a 1366x768 laptop) and grows on a big one.
		FitToViewport = true,
		-- Place mode steps the modal aside -- the SESSION stays open (IsOpen, and the character's freeze),
		-- only the frame goes, so the cursor and camera are free to work the gizmo.
		IsOpen = scope:Computed(function(use)
			return use(isOpen) and not use(placementMode)
		end),
		-- No HeaderAccessory: the tab run spans the whole strip, so anything pinned there sits on top of
		-- the last tab. The move count and unsaved count live in the browser rail's own header instead.
		Tabs = tabs,
		Wordmark = "MOVE EDITOR",
		StatusText = statusText,
		-- A signal, not a write: the driver arms the unsaved-work confirmation before anything closes.
		OnClose = function()
			closeRequested:Fire()
		end,
		Body = Stack.Row(scope, {
			Name = "Body",
			Children = {
				Browser(scope, {
					Width = BROWSER_WIDTH,
					LayoutOrder = 1,
					Entries = entries,
					SelectedId = selectedId,
					IsDirty = isDirty,
					OnSelect = function(moveId: string)
						selectRequested:Fire(moveId)
					end,
					OnNew = function(kind: string)
						newRequested:Fire(kind)
					end,
					Order = browserOrder,
					FilterBox = filterBox,
				}),
				Stack.Fill(scope, form),
				Readout(scope, {
					Width = READOUT_WIDTH,
					LayoutOrder = 3,
					Entry = selectedEntry,
					Draft = draft,
					IsDirty = isDirty,
					HotbarBindings = hotbarBindings,
					VolumesVisible = volumesVisible,
					CanUndo = canUndo,
					CanRedo = canRedo,
					OnUndo = undo,
					OnRedo = redo,
					OnSave = function()
						saveRequested:Fire()
					end,
					OnTest = function()
						testRequested:Fire()
					end,
					OnRevert = function()
						revertRequested:Fire()
					end,
					OnDuplicate = function()
						duplicateRequested:Fire()
					end,
					OnDelete = function()
						deleteRequested:Fire()
					end,
					OnResetDefault = function()
						resetDefaultRequested:Fire()
					end,
					OnBindSlot = function(slot: number)
						bindSlotRequested:Fire(slot)
					end,
					OnSpawnDummy = function()
						spawnDummyRequested:Fire()
					end,
					OnToggleVolumes = function(visible: boolean)
						volumesToggled:Fire(visible)
					end,
					DummyGuard = dummyGuard,
					BotStyle = botStyle,
					BotDifficulty = botDifficulty,
					OnDummyGuard = function(enabled: boolean)
						dummyGuardToggled:Fire(enabled)
					end,
					OnSpawnBot = function()
						spawnBotRequested:Fire()
					end,
					OnClearBench = function()
						clearBenchRequested:Fire()
					end,
					HitLog = hitLog,
					OnClearHitLog = function()
						clearHitLogRequested:Fire()
					end,
					Edit = context.Edit,
					ScrubTime = scrubTime,
					ScrubPlaying = scrubPlaying,
				}),
			},
		}),
	})

	PlacementBar(scope, {
		PlayerGui = playerGui,
		Active = placementMode,
		Tool = placementTool,
		Snap = placementSnap,
		Draft = draft,
	})

	return {
		IsOpen = isOpen,
		ShowOnCharacter = showOnCharacter,
		PlacementMode = placementMode,
		PlacementTool = placementTool,
		PlacementSnap = placementSnap,
		EditDraft = context.Edit,
		StatusText = statusText,
		Entries = entries,
		HotbarBindings = hotbarBindings,
		VolumesVisible = volumesVisible,
		SelectedId = selectedId,
		Draft = draft,
		SelectedEntry = selectedEntry,
		IsDirty = isDirty,
		CurrentTab = tabs.Current,
		ShownTab = tabs.Shown,
		RealmPage = realmPage,
		ShowPage = showPage,
		StepSelection = stepSelection,
		FocusFilter = function()
			local box = peek(filterBox)
			if box then
				box:CaptureFocus()
			end
		end,
		SetMoveType = setMoveType,
		HintsShown = hintsShown,
		SavedMove = savedMove,
		ScrubTime = scrubTime,
		ScrubPlaying = scrubPlaying,
		PreviewAssetRequested = previewAssetRequested.Event,
		IsDomain = isDomain,
		CanUndo = canUndo,
		CanRedo = canRedo,
		Undo = undo,
		Redo = redo,
		ClearHistory = function(moveId: string)
			history:Clear(moveId)
			historyChanged()
		end,
		CloseRequested = closeRequested.Event,
		SelectRequested = selectRequested.Event,
		NewRequested = newRequested.Event,
		DuplicateRequested = duplicateRequested.Event,
		DraftEdited = draftEdited.Event,
		SaveRequested = saveRequested.Event,
		RevertRequested = revertRequested.Event,
		DeleteRequested = deleteRequested.Event,
		ResetDefaultRequested = resetDefaultRequested.Event,
		TestRequested = testRequested.Event,
		BindSlotRequested = bindSlotRequested.Event,
		SpawnDummyRequested = spawnDummyRequested.Event,
		VolumesToggled = volumesToggled.Event,
		DummyGuard = dummyGuard,
		BotStyle = botStyle,
		BotDifficulty = botDifficulty,
		DummyGuardToggled = dummyGuardToggled.Event,
		SpawnBotRequested = spawnBotRequested.Event,
		ClearBenchRequested = clearBenchRequested.Event,
		HitLog = hitLog,
		ClearHitLogRequested = clearHitLogRequested.Event,
		BulkScaleRequested = bulkScaleRequested.Event,
		HistoryVersions = historyVersions,
		LoadHistoryRequested = loadHistoryRequested.Event,
		RestoreVersionRequested = restoreVersionRequested.Event,
		ExportText = exportText,
		WriteToSourceRequested = writeToSourceRequested.Event,
		RemoveFromSourceRequested = removeFromSourceRequested.Event,
		ExportSourceRequested = exportSourceRequested.Event,
		PreviewCueRequested = previewCueRequested.Event,
	} :: any
end

return MoveEditor
