--!strict
--[[
	BugReportConstants.lua

	Owns: the in-game bug reporting feature's surface -- the closed category/status/priority
	vocabularies a submission is validated against, description length bounds, and the per-remote call
	budgets.

	Moved verbatim, carrying its four `:: { Types.BugReportCategory }`-style annotations, which is why
	this module requires Types. Those four casts are what make the vocabularies a closed set the type
	checker enforces rather than four loose string arrays.

	Does not own: the DataStore this writes to (Server/Config/StorageConfig.lua), the open-count
	bookkeeping (BugReportSystem computes deltas; see its own spec), or the admin surface that reads
	reports back.

	Lifted out of Constants.lua. Constants.BugReport re-exports this module, so every existing
	Constants.BugReport.X call site keeps working unchanged; new code should require this module
	directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

-- Player-facing bug report feature (Server/Systems/BugReportSystem.lua,
-- Client/BugReport/BugReportClient.lua, Client/UI/Screens/BugReport/init.lua). Unlike
-- Constants.Debug.DevMenu, this is NOT whitelist-gated -- every player can submit. The two ADMIN
-- remote names (list/triage) live in Constants.Debug.DevMenu.RemoteNames instead, since
-- DevMenuSystem is what creates/handles those -- see that table's own comment.
local BugReportConstants = {
	Categories = { "Bug", "Exploit", "Suggestion", "Other" } :: { Types.BugReportCategory },

	-- Every valid Status value, in triage order -- BugReportSystem derives its STATUS_SET
	-- validation table from this the same way it already derives CATEGORY_SET from Categories
	-- above, and the admin Reports tab's status filter/selector both iterate this instead of
	-- hand-listing the four strings a second time.
	Statuses = { "Open", "InProgress", "Resolved", "Dismissed" } :: { Types.BugReportStatus },

	-- Admin-settable severity, lowest to highest -- BugReportSystem.SetPriority validates against
	-- this set; the Reports tab's priority selector iterates it the same way it iterates Statuses
	-- above.
	Priorities = { "Low", "Normal", "High", "Urgent" } :: { Types.BugReportPriority },

	-- Default Priority for a freshly Submitted report -- an admin re-triages from here. Nothing
	-- about the reporter's chosen Category auto-escalates this (an Exploit report isn't assumed
	-- more urgent than a Suggestion just by category); that judgment call stays with the admin.
	DefaultPriority = "Normal" :: Types.BugReportPriority,

	DescriptionMinLength = 10,
	DescriptionMaxLength = 1000,

	-- Internal triage note length cap (BugReportSystem.AddNote) -- short by design, a coordination
	-- breadcrumb, not a second description field.
	NoteMaxLength = 300,

	-- Anti-spam: a player may only successfully submit once per this many seconds
	-- (BugReportSystem's own per-player cooldown tracking, distinct from the generic
	-- per-second RateLimiter bucket below -- that one catches a client hammering the remote
	-- itself, e.g. a modified client retrying in a tight loop, before the cooldown check even runs).
	SubmitCooldownSeconds = 60,
	SubmitMaxCallsPerSecond = 2,

	-- Admin list pagination page size (BugReportSystem.ListReports / GetSortedAsync pageSize).
	ListPageSize = 20,

	-- DataStore names moved to ServerScriptService/Server/Config/StorageConfig.lua (they replicated
	-- to clients from here, where they are useless to legitimate code and pure reconnaissance
	-- otherwise). The version-suffix convention this table established lives on there. Retry/backoff
	-- tuning above stays here -- only the store identifiers moved.

	-- Seconds a submission confirmation/error message stays visible before the form auto-clears its
	-- status line -- same idea as Constants.Debug.DevMenu.StatusClearDelaySeconds.
	ConfirmationClearDelaySeconds = 3,

	-- Public remote BugReportSystem itself creates/handles (any player may call this -- no admin
	-- check).
	RemoteNames = {
		Submit = "BugReport_Submit",
	},
}

return BugReportConstants
