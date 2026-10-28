--!strict
--[[
	WorldArchitect/OptimizePanel.lua

	Owns: the Optimize tab -- running the server's analysis of the managed world, its measured counts, the findings by
	severity, and the preview-then-apply flow: each finding with proposed changes has an Include switch (included
	findings are outlined in the world, amber), "Apply safe" applies the safe changes of the included findings, and the
	armed "Apply incl. destructive" also applies their deletions. Either is ONE undoable edit.

	Every number shown is a count the server took from the records (ArchitectOptimizer's header); nothing here claims
	a frame-time saving.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local StatusTag = require(script.Parent.Parent.Parent.Parent.Components.StatusTag)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)
local Kit = require(script.Parent.Parent.DevMenu.Kit)

local Style = require(script.Parent.Style)
local WorldArchitectTypes = require(script.Parent.Types)

type Scope = Fusion.Scope<typeof(Fusion)>
type Handle = WorldArchitectTypes.Handle

local peek = Fusion.peek

local SEVERITY_COLOR: { [string]: Color3 } = {
	High = Tokens.Color.DangerBright,
	Medium = Tokens.Color.Warning,
	Low = Tokens.Color.FactionCelestial,
	Info = Tokens.Color.TextSecondary,
}

local function OptimizePanel(scope: Scope, handle: Handle, visible: Fusion.UsedAs<boolean>): ScrollingFrame
	local report = handle.Report
	local hasReport = scope:Computed(function(use)
		return use(report) ~= nil
	end)
	local findings = scope:Computed(function(use)
		local r = use(report)
		return if r then r.Findings else {}
	end)
	local function metric(pick: (any) -> string): Fusion.Computed<string>
		return scope:Computed(function(use)
			local r = use(report)
			return if r then pick(r.Metrics) else "—"
		end)
	end

	local includedCounts = scope:Computed(function(use)
		local included = use(handle.PreviewFindings)
		local safe, destructive = 0, 0
		for _, finding in use(findings) do
			if included[finding.Id] then
				safe += finding.SafeCount or 0
				destructive += finding.DestructiveCount or 0
			end
		end
		return { Safe = safe, Destructive = destructive }
	end)

	local rows = scope:ForPairs(findings, function(_use, inner: Scope, index: number, finding: any)
		local actionable = (finding.SafeCount or 0) + (finding.DestructiveCount or 0) > 0
		local changes = if actionable
			then `\n{finding.SafeCount or 0} safe changes, {finding.DestructiveCount or 0} destructive.`
			else ""
		return index,
			Kit.Group(inner, index, {
				Kit.Row(inner, 1, {
					StatusTag(inner, {
						Label = string.upper(finding.Severity),
						Color = SEVERITY_COLOR[finding.Severity] or Tokens.Color.TextSecondary,
						LayoutOrder = 1,
					}),
					Label(inner, {
						Text = `{finding.Title} ({finding.Count})`,
						Scale = "Body",
						Color = Tokens.Color.TextPrimary,
						Size = UDim2.new(1, -96, 1, 0),
						TextTruncate = Enum.TextTruncate.AtEnd,
						LayoutOrder = 2,
					}),
				}),
				Style.Prose(inner, `{finding.Detail}\n{finding.Impact}{changes}`, 2),
				Kit.Holder(
					inner,
					"Include",
					3,
					Toggle(inner, {
						Label = "Include and outline in world",
						Value = inner:Computed(function(use)
							return use(handle.PreviewFindings)[finding.Id] == true
						end),
						OnChanged = function(value: boolean)
							local included = table.clone(peek(handle.PreviewFindings))
							included[finding.Id] = value or nil
							handle.PreviewFindings:set(included)
						end,
					}),
					actionable or #finding.Nodes > 0
				),
			}, nil, Tokens.Space.XS)
	end)

	return Kit.Page(scope, "Optimize", visible, {
		Style.Prose(
			scope,
			"Analyses the managed world only. Changes are role-aware: collision is never touched on Structure, Walkable or Barrier.",
			1
		),
		Kit.Button(scope, {
			Text = "ANALYZE WORLD",
			Order = 2,
			OnActivated = function()
				handle.Fire({ Kind = "Analyze" })
			end,
		}),
		Kit.Heading(scope, "COUNTS", 10, hasReport),
		Kit.Stat(
			scope,
			"Nodes (parts / groups)",
			metric(function(m)
				return `{m.Nodes} ({m.Parts} / {m.Groups})`
			end),
			11,
			hasReport
		),
		Kit.Stat(
			scope,
			"Simulated (unanchored)",
			metric(function(m)
				return tostring(m.Unanchored)
			end),
			12,
			hasReport
		),
		Kit.Stat(
			scope,
			"Collidable",
			metric(function(m)
				return tostring(m.Collidable)
			end),
			13,
			hasReport
		),
		Kit.Stat(
			scope,
			"Touch-enabled",
			metric(function(m)
				return tostring(m.Touchable)
			end),
			14,
			hasReport
		),
		Kit.Stat(
			scope,
			"Query-visible",
			metric(function(m)
				return tostring(m.Queryable)
			end),
			15,
			hasReport
		),
		Kit.Stat(
			scope,
			"Shadow casters",
			metric(function(m)
				return tostring(m.ShadowCasters)
			end),
			16,
			hasReport
		),
		Kit.Stat(
			scope,
			"From templates",
			metric(function(m)
				return `{m.FromTemplates} parts`
			end),
			17,
			hasReport
		),
		Kit.Stat(
			scope,
			"Root-level parts / depth",
			metric(function(m)
				return `{m.RootParts} / {m.MaxDepth}`
			end),
			18,
			hasReport
		),
		Kit.Heading(scope, "FINDINGS", 20, hasReport),
		Style.Prose(
			scope,
			"No findings: nothing to improve.",
			21,
			scope:Computed(function(use)
				return use(hasReport) and #use(findings) == 0
			end),
			Tokens.Color.Positive
		),
		Kit.Group(scope, 22, { rows :: any }, hasReport, Tokens.Space.L),
		Kit.Heading(scope, "APPLY", 30, hasReport),
		Kit.Button(scope, {
			Text = scope:Computed(function(use)
				return `APPLY SAFE ({use(includedCounts).Safe})`
			end),
			Order = 31,
			Visible = hasReport,
			Disabled = scope:Computed(function(use)
				return use(includedCounts).Safe == 0
			end),
			OnActivated = function()
				handle.Fire({ Kind = "Optimize", IncludeDestructive = false })
			end,
		}),
		Kit.Armed(scope, {
			Idle = scope:Computed(function(use)
				local counts = use(includedCounts)
				return `APPLY INCL. DESTRUCTIVE ({counts.Safe + counts.Destructive})`
			end),
			Armed = "CONFIRM — DELETES PARTS",
			Order = 32,
			Visible = hasReport,
			Disabled = scope:Computed(function(use)
				return use(includedCounts).Destructive == 0
			end),
			OnConfirm = function()
				handle.Fire({ Kind = "Optimize", IncludeDestructive = true })
			end,
		}),
		Style.Prose(scope, "Applied changes are one edit: Undo reverts all of them.", 33, hasReport),
	})
end

return OptimizePanel
