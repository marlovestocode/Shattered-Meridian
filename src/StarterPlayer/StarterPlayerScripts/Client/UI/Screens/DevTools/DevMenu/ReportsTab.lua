--!strict
--[[
	DevMenu/ReportsTab.lua

	Owns: the Reports tab -- bug-report triage. Filters across the top (status, category, mine, a
	search), then the loaded reports as a list: one compact entry each, and one at a time opened in
	place to the full report and its triage (status, priority, claim, jump to the reporter, notes).

	ONE OPEN AT A TIME, AND IT STAYS OPEN THROUGH AN EDIT. The open report is an id at tab level, not
	a flag inside a row, so when a status change comes back from the server and that report's row is
	rebuilt with the new record, it is rebuilt open. (The note box does clear -- which is right, since
	the only edit that rebuilds a row with a note typed is adding that note.)

	FILTERS NARROW WHAT IS LOADED. ListBugReports pages newest-first and has no server-side query, so
	a filter here cannot reach reports on pages not yet fetched; the summary line says how many are
	loaded, and Load more fetches the next page. That is the DataStore's shape, not a choice made here.

	A REPORTER IN THIS SERVER CAN BE INSPECTED: "Select in roster" makes them the panel's target
	(onSelectPlayer), which is how a report about another player's behaviour turns into acting on it.

	Does not own: what any intent does (the driver), or the records (the driver's, patched in place from
	each mutation's answer).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AdminFormat = require(ReplicatedStorage.Shared.Admin.AdminFormat)
local AdminTypes = require(ReplicatedStorage.Shared.Admin.AdminTypes)
local BugReportConstants = require(ReplicatedStorage.Shared.BugReportConstants)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local DropdownModule = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Selection = require(script.Parent.Parent.Parent.Parent.Components.Selection)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local StatusTag = require(script.Parent.Parent.Parent.Parent.Components.StatusTag)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)

local DevMenuTypes = require(script.Parent.Types)
local Kit = require(script.Parent.Kit)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Intent = DevMenuTypes.Intent
type Record = Types.BugReportRecord

export type ReportsTabProps = {
	Visible: UsedAs<boolean>,
	Reports: UsedAs<{ Record }>,
	HasMore: UsedAs<boolean>,
	Loading: UsedAs<boolean>,
	LocalUserId: UsedAs<number>,
	Roster: UsedAs<{ AdminTypes.RosterEntry }>,
	Fire: (Intent) -> (),
	OnSelectPlayer: (userId: number) -> (),
}

local HEADER_HEIGHT = 58
local PREVIEW_LENGTH = 110
local ALL = "All"

local STATUS_TEXT: { [string]: string } = {
	Open = "Open",
	InProgress = "In progress",
	Resolved = "Resolved",
	Dismissed = "Dismissed",
}

local function statusColor(status: string): Color3
	if status == "Open" then
		return Tokens.Color.AccentPrimary
	elseif status == "InProgress" then
		return Tokens.Color.AccentSecondary
	elseif status == "Resolved" then
		return Tokens.Color.Positive
	end
	return Tokens.Color.TextDisabled
end

local function priorityColor(priority: string): Color3
	if priority == "Urgent" then
		return Tokens.Color.DangerBright
	elseif priority == "High" then
		return Tokens.Color.Warning
	end
	return Tokens.Color.TextDisabled
end

local function chip(scope: Scope, label: string, color: Color3, order: number): Instance
	return scope:New "Frame" {
		Name = label,
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		LayoutOrder = order,
		[Children] = StatusTag(scope, { Label = label, Color = color }),
	}
end

local function preview(text: string): string
	local oneLine = string.gsub(text, "%s+", " ")
	if #oneLine <= PREVIEW_LENGTH then
		return oneLine
	end
	return string.sub(oneLine, 1, PREVIEW_LENGTH) .. "..."
end

local function contextText(record: Record): string
	local where = if record.Position then AdminFormat.Position(record.Position) else "no position"
	return `Place {record.PlaceId} · job {record.JobId} · at {where}`
end

local function detail(scope: Scope, record: Record, props: ReportsTabProps, isOpen: UsedAs<boolean>): Frame
	local noteText = scope:Value("")

	local statusOptions: { Kit.Option } = {}
	for _, status in BugReportConstants.Statuses do
		table.insert(statusOptions, { Value = status, Text = STATUS_TEXT[status] or status })
	end
	local priorityOptions: { Kit.Option } = {}
	for _, priority in BugReportConstants.Priorities do
		table.insert(priorityOptions, { Value = priority, Text = priority })
	end

	local reporterHere = scope:Computed(function(use)
		for _, entry in use(props.Roster) do
			if entry.UserId == record.ReporterUserId then
				return true
			end
		end
		return false
	end)
	local mine = scope:Computed(function(use)
		return record.AssignedAdminUserId ~= nil and record.AssignedAdminUserId == use(props.LocalUserId)
	end)

	local noteRows: { Instance } = {}
	for index, note in record.Notes do
		table.insert(
			noteRows,
			Kit.Group(scope, index, {
				Label(scope, {
					Text = `{note.AuthorName}  ·  {AdminFormat.Date(note.CreatedAt)}`,
					Scale = "Detail",
					Color = Tokens.Color.TextDisabled,
					Size = UDim2.new(1, 0, 0, Tokens.Type.Detail.Size + 2),
					LayoutOrder = 1,
				}),
				Kit.Prose(scope, note.Text, 2, nil, Tokens.Color.TextPrimary),
			}, nil, 2)
		)
	end
	if #noteRows == 0 then
		table.insert(noteRows, Kit.Prose(scope, "No notes yet.", 1))
	end

	return Kit.Group(scope, 2, {
		Kit.Prose(scope, record.Description, 1, nil, Tokens.Color.TextPrimary),
		Kit.Prose(scope, contextText(record), 2),
		Kit.Segmented(scope, {
			Options = statusOptions,
			Selected = record.Status,
			OnPick = function(value: string)
				props.Fire({ Kind = "ReportStatus", Id = record.Id, Status = value })
			end,
			Order = 3,
		}),
		Kit.Segmented(scope, {
			Options = priorityOptions,
			Selected = record.Priority,
			OnPick = function(value: string)
				props.Fire({ Kind = "ReportPriority", Id = record.Id, Priority = value })
			end,
			Order = 4,
		}),
		Kit.Row(scope, 5, {
			Kit.Button(scope, {
				Text = scope:Computed(function(use)
					return if use(mine) then "Release claim" else "Claim it"
				end),
				Order = 1,
				Size = Kit.Cell(3),
				OnActivated = function()
					props.Fire({ Kind = "ReportAssign", Id = record.Id, Assign = not peek(mine) })
				end,
			}),
			Kit.Button(scope, {
				Text = "Go to reporter",
				Order = 2,
				Size = Kit.Cell(3),
				Disabled = scope:Computed(function(use)
					return not use(reporterHere)
				end),
				OnActivated = function()
					props.Fire({ Kind = "ReportJump", Id = record.Id })
				end,
			}),
			Kit.Button(scope, {
				Text = "Select in roster",
				Order = 3,
				Size = Kit.Cell(3),
				Disabled = scope:Computed(function(use)
					return not use(reporterHere)
				end),
				OnActivated = function()
					props.OnSelectPlayer(record.ReporterUserId)
				end,
			}),
		}),
		Kit.Prose(
			scope,
			"The reporter is not in this server.",
			6,
			scope:Computed(function(use)
				return not use(reporterHere)
			end)
		),
		Kit.Heading(scope, "NOTES", 7, nil, `{#record.Notes}`),
		Kit.Group(scope, 8, noteRows),
		Kit.Row(scope, 9, {
			Stack.Fill(
				scope,
				TextField(scope, {
					Text = noteText,
					PlaceholderText = "Add an internal note -- admins only, never shown to the reporter",
					MaxLength = BugReportConstants.NoteMaxLength,
					Size = UDim2.fromScale(0, 1),
					LayoutOrder = 1,
				})
			),
			Kit.Button(scope, {
				Text = "Add",
				Order = 2,
				Size = UDim2.fromOffset(72, Kit.ButtonHeight),
				OnActivated = function()
					local text = peek(noteText)
					if (string.gsub(text, "%s", "")) ~= "" then
						props.Fire({ Kind = "ReportNote", Id = record.Id, Text = text })
						noteText:set("")
					end
				end,
			}),
		}),
	}, isOpen, Tokens.Space.S)
end

local function reportRow(
	scope: Scope,
	record: Record,
	order: number,
	props: ReportsTabProps,
	openId: Fusion.Value<string?>
): Frame
	local selection = Selection.New(scope)
	local isOpen = scope:Computed(function(use)
		return use(openId) == record.Id
	end)

	local claimText = if record.AssignedAdminName then `claimed by {record.AssignedAdminName}` else "unclaimed"

	local header = scope:New "TextButton" {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		LayoutOrder = 1,
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Tokens.Wash.AccentBloom.Color,
		BackgroundTransparency = scope:Computed(function(use)
			return if use(selection.Active) or use(isOpen) then Tokens.Wash.AccentBloom.Transparency else 1
		end),
		BorderSizePixel = 0,

		[OnEvent "Activated"] = function()
			openId:set(if peek(openId) == record.Id then nil else record.Id)
		end,
		[OnEvent "MouseEnter"] = selection.OnPointerEnter,
		[OnEvent "MouseLeave"] = selection.OnPointerLeave,
		[OnEvent "SelectionGained"] = selection.OnSelectionGained,
		[OnEvent "SelectionLost"] = selection.OnSelectionLost,

		[Children] = {
			Stack.Row(scope, {
				Name = "Chips",
				Position = UDim2.fromOffset(Tokens.Space.S, 6),
				Size = UDim2.new(1, -Tokens.Space.S * 2, 0, 24),
				Gap = Tokens.Space.XS,
				AlignY = Enum.VerticalAlignment.Center,
				Children = {
					chip(scope, record.Category, Tokens.Color.TextSecondary, 1),
					chip(scope, STATUS_TEXT[record.Status] or record.Status, statusColor(record.Status), 2),
					chip(scope, record.Priority, priorityColor(record.Priority), 3),
					Stack.Fill(
						scope,
						Label(scope, {
							Text = `{record.ReporterName}  ·  {claimText}`,
							Scale = "Body",
							Color = Tokens.Color.TextPrimary,
							Size = UDim2.fromScale(0, 1),
							TextTruncate = Enum.TextTruncate.AtEnd,
							LayoutOrder = 4,
						})
					),
					Label(scope, {
						Text = AdminFormat.Date(record.CreatedAt),
						Scale = "NumeralSmall",
						Color = Tokens.Color.TextDisabled,
						Size = UDim2.new(0, 116, 1, 0),
						TextXAlignment = Enum.TextXAlignment.Right,
						LayoutOrder = 5,
					}),
				},
			}),
			Label(scope, {
				Text = preview(record.Description),
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Position = UDim2.fromOffset(Tokens.Space.S, 34),
				Size = UDim2.new(1, -Tokens.Space.S * 2, 0, Tokens.Type.Detail.Size + 4),
				TextTruncate = Enum.TextTruncate.AtEnd,
			}),
		},
	}

	return Stack.New(scope, {
		Name = `Report_{record.Id}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.S,
		LayoutOrder = order,
		Children = {
			header,
			detail(scope, record, props, isOpen),
			scope:New "Frame" {
				Name = "Rule",
				Size = UDim2.new(1, 0, 0, Tokens.Control.DividerThickness),
				BackgroundColor3 = Tokens.Border.Hairline.Color,
				BackgroundTransparency = Tokens.Border.Hairline.Transparency,
				BorderSizePixel = 0,
				LayoutOrder = 3,
			},
		},
	})
end

local function ReportsTab(scope: Scope, props: ReportsTabProps): ScrollingFrame
	local statusFilter = scope:Value("Open")
	local categoryFilter = scope:Value(ALL)
	local mineOnly = scope:Value(false)
	local searchText = scope:Value("")
	local openId = scope:Value(nil :: string?)

	local statusOptions: { Kit.Option } = { { Value = ALL, Text = "All" } }
	for _, status in BugReportConstants.Statuses do
		table.insert(statusOptions, { Value = status, Text = STATUS_TEXT[status] or status })
	end
	local categoryOptions: { DropdownModule.DropdownOption } = { { Value = ALL, Text = "Every category" } }
	for _, category in BugReportConstants.Categories do
		table.insert(categoryOptions, { Value = category, Text = category })
	end

	local filtered = scope:Computed(function(use)
		local status = use(statusFilter)
		local category = use(categoryFilter)
		local onlyMine = use(mineOnly)
		local localUserId = use(props.LocalUserId)
		local query = string.lower(use(searchText))
		local result: { Record } = {}
		for _, record in use(props.Reports) do
			if status ~= ALL and record.Status ~= status then
				continue
			end
			if category ~= ALL and record.Category ~= category then
				continue
			end
			if onlyMine and record.AssignedAdminUserId ~= localUserId then
				continue
			end
			if query ~= "" then
				local haystack = string.lower(`{record.ReporterName} {record.ReporterUserId} {record.Description}`)
				if not string.find(haystack, query, 1, true) then
					continue
				end
			end
			table.insert(result, record)
		end
		return result
	end)

	-- Keyed by record, so a patched record (a new table from the server) rebuilds its own row and no
	-- other -- see the header on why that keeps it open.
	local rows = scope:ForPairs(filtered, function(_use, innerScope: Scope, index: number, record: Record)
		return record, reportRow(innerScope, record, index, props, openId)
	end)

	local summary = scope:Computed(function(use)
		local all = use(props.Reports)
		local open = 0
		for _, record in all do
			if record.Status == "Open" then
				open += 1
			end
		end
		local more = if use(props.HasMore) then " · more on the server" else ""
		return `Showing {#use(filtered)} of {#all} loaded · {open} open{more}`
	end)
	local isEmpty = scope:Computed(function(use)
		return #use(filtered) == 0 and not use(props.Loading)
	end)

	local children: { Instance } = {
		Kit.Heading(scope, "FILTER", 1),
		Kit.Segmented(scope, {
			Options = statusOptions,
			Selected = statusFilter,
			OnPick = function(value: string)
				statusFilter:set(value)
			end,
			Order = 2,
		}),
		Kit.Pair(
			scope,
			3,
			DropdownModule.Mount(scope, {
				Options = categoryOptions,
				Value = categoryFilter,
				OnChanged = function(value: string)
					categoryFilter:set(value)
				end,
			}),
			Toggle(scope, {
				Label = "Claimed by me",
				Value = mineOnly,
				OnChanged = function(value: boolean)
					mineOnly:set(value)
				end,
			})
		),
		TextField(scope, {
			Text = searchText,
			PlaceholderText = "Search reporter, user id or description",
			MaxLength = 60,
			Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
			LayoutOrder = 4,
		}),
		Kit.Row(scope, 5, {
			Kit.Button(scope, {
				Text = scope:Computed(function(use)
					return if use(props.Loading) then "Loading..." else "Refresh"
				end),
				Order = 1,
				Size = Kit.Cell(2),
				Disabled = props.Loading,
				OnActivated = function()
					props.Fire({ Kind = "ReportsLoad", Mode = "First" })
				end,
			}),
			Kit.Button(scope, {
				Text = scope:Computed(function(use)
					return if use(props.HasMore) then "Load more" else "All loaded"
				end),
				Order = 2,
				Size = Kit.Cell(2),
				Disabled = scope:Computed(function(use)
					return use(props.Loading) or not use(props.HasMore)
				end),
				OnActivated = function()
					props.Fire({ Kind = "ReportsLoad", Mode = "Next" })
				end,
			}),
		}),
		Kit.Heading(scope, "REPORTS", 6, nil, summary),
		Kit.Prose(scope, "No reports match.", 7, isEmpty),
		Stack.New(scope, {
			Name = "List",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 8,
			Children = { rows :: any },
		}),
	}

	return Kit.Page(scope, "ReportsTab", props.Visible, children)
end

return ReportsTab
