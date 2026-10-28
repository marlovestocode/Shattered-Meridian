--!strict
--[[
	ArchitectOptimizer.lua

	Owns: the World Architect's world analysis -- counting what the managed world actually costs and proposing the
	changes that lower it without changing how anything plays. Pure: it reads records and returns a report; the server
	applies a chosen subset as ONE ordinary undoable edit, so every applied change is revertable with Undo.

	EVERY NUMBER IS A COUNT, NEVER A GUESS. The report says "removes 14 parts from physics simulation", "42 fewer parts in
	the touch broadphase" -- facts about the records -- and never "saves 3 ms", which nothing here measured.

	WHAT IT MAY CHANGE, AND THE EVIDENCE FOR EACH (the rule the brief asked for: only when the role and the codebase's
	own dependencies prove a capability unused):

	  Anchored -> true     nothing the builder makes is meant to move (it creates no constraints, no scripts, no
	                       vehicles), so an unanchored part is a part that falls or settles; Safe.
	  CanTouch -> false    the only Touched listeners in this codebase are vessel hulls (Server/Vessel/VesselContacts),
	                       which count player limbs touching THEIR OWN parts; a built part never needs to fire Touched; Safe.
	  CanCollide -> false  ONLY for Role = Decor -- the admin declared it visual-only. Structure, Walkable and Barrier
	                       keep collision whatever else is true of them; Safe.
	  CanQuery -> false    ONLY for Decor that does not collide (the engine refuses CanQuery off on a colliding part).
	                       Parkour probes, lock-on line of sight and the editor's own picking stop seeing it, which is
	                       what Decor means; Safe.
	  CastShadow -> false  parts under a stud on every axis, and Neon (which emits light): their shadow is noise; Safe.
	  Delete               exact duplicates (same shape, size, position, orientation) and invisible, non-colliding Decor
	                       that can affect nothing; DESTRUCTIVE -- never in "Apply safe", always listed separately.

	WHAT IT ONLY REPORTS: invisible parts that still collide (maybe an intended barrier -- set the role), heavily
	overlapping parts, oversized parts, loose root-level parts, deep nesting, and how close the world is to its budget.

	NEVER: merging parts, unions, collision groups, streaming settings, or anything outside the managed world.
]]

local ArchitectConstants = require(script.Parent.ArchitectConstants)
local ArchitectRecord = require(script.Parent.ArchitectRecord)
local ArchitectTransform = require(script.Parent.ArchitectTransform)

type NodeRecord = ArchitectRecord.NodeRecord

local ArchitectOptimizer = {}

export type Safety = "Safe" | "Destructive"
export type Severity = "High" | "Medium" | "Low" | "Info"

export type Change = {
	NodeId: string,
	-- A record field, or "Delete".
	Field: string,
	To: any,
	Safety: Safety,
}

export type Finding = {
	Id: string,
	Severity: Severity,
	Title: string,
	Detail: string,
	Impact: string,
	Count: number,
	-- Affected node ids (capped at NodeListCap for the wire; Count is the real number).
	Nodes: { string },
	Changes: { Change },
}

export type Metrics = {
	Nodes: number,
	Parts: number,
	Groups: number,
	Budget: number,
	Unanchored: number,
	Collidable: number,
	Touchable: number,
	Queryable: number,
	ShadowCasters: number,
	Invisible: number,
	RootParts: number,
	MaxDepth: number,
	FromTemplates: number,
	ByRole: { [string]: number },
	ByTemplate: { [string]: number },
}

export type Report = {
	Metrics: Metrics,
	Findings: { Finding },
	SafeChanges: number,
	DestructiveChanges: number,
}

ArchitectOptimizer.NodeListCap = 200

local SEVERITY_ORDER: { [Severity]: number } = { High = 1, Medium = 2, Low = 3, Info = 4 }
local OVERLAP_CELL = 16
local OVERLAP_PAIR_CAP = 400

local function depthOf(byId: { [string]: NodeRecord }, record: NodeRecord): number
	local depth = 1
	local parent = record.Parent
	while parent and byId[parent] and depth < 64 do
		depth += 1
		parent = byId[parent].Parent
	end
	return depth
end

local function signature(record: NodeRecord): string
	local function r(n: number): string
		return string.format("%.2f", n)
	end
	local p, o, s = record.Position, record.Orientation, record.Size
	return table.concat({ record.Shape, r(p.X), r(p.Y), r(p.Z), r(o.X), r(o.Y), r(o.Z), r(s.X), r(s.Y), r(s.Z) }, "|")
end

local function newFinding(id: string, severity: Severity, title: string, detail: string): Finding
	return {
		Id = id,
		Severity = severity,
		Title = title,
		Detail = detail,
		Impact = "",
		Count = 0,
		Nodes = {},
		Changes = {},
	}
end

local function note(finding: Finding, nodeId: string): ()
	finding.Count += 1
	if #finding.Nodes < ArchitectOptimizer.NodeListCap then
		table.insert(finding.Nodes, nodeId)
	end
end

local function propose(finding: Finding, nodeId: string, field: string, to: any, safety: Safety): ()
	table.insert(finding.Changes, { NodeId = nodeId, Field = field, To = to, Safety = safety })
end

-- Pairs of parts whose bounds overlap by more than 90% of the smaller one's volume, via a coarse spatial hash so the
-- cost is near linear rather than every-pair.
local function overlaps(parts: { NodeRecord }): { { string } }
	local cells: { [string]: { number } } = {}
	local boxes: { { Vector3 } } = {}
	for index, part in parts do
		local low, high = ArchitectTransform.BoxBounds(ArchitectRecord.CFrameOf(part), part.Size)
		boxes[index] = { low, high }
		local key =
			`{math.floor(part.Position.X / OVERLAP_CELL)},{math.floor(part.Position.Y / OVERLAP_CELL)},{math.floor(
				part.Position.Z / OVERLAP_CELL
			)}`
		local list = cells[key] or {}
		table.insert(list, index)
		cells[key] = list
	end
	local found: { { string } } = {}
	for _, list in cells do
		for i = 1, #list do
			for j = i + 1, #list do
				local a, b = boxes[list[i]], boxes[list[j]]
				local low = a[1]:Max(b[1])
				local high = a[2]:Min(b[2])
				local overlap = high - low
				if overlap.X > 0 and overlap.Y > 0 and overlap.Z > 0 then
					local shared = overlap.X * overlap.Y * overlap.Z
					local va = (a[2] - a[1])
					local vb = (b[2] - b[1])
					local smaller = math.min(va.X * va.Y * va.Z, vb.X * vb.Y * vb.Z)
					if smaller > 0 and shared / smaller > 0.9 then
						table.insert(found, { parts[list[i]].Id, parts[list[j]].Id })
						if #found >= OVERLAP_PAIR_CAP then
							return found
						end
					end
				end
			end
		end
	end
	return found
end

function ArchitectOptimizer.Analyze(records: { NodeRecord }): Report
	local byId: { [string]: NodeRecord } = {}
	for _, record in records do
		byId[record.Id] = record
	end
	-- Stable order, so the same world gives the same report (and the same duplicate kept).
	local sorted = table.clone(records)
	table.sort(sorted, function(a, b)
		return a.Id < b.Id
	end)

	local metrics: Metrics = {
		Nodes = #records,
		Parts = 0,
		Groups = 0,
		Budget = ArchitectConstants.Limits.MaxNodes,
		Unanchored = 0,
		Collidable = 0,
		Touchable = 0,
		Queryable = 0,
		ShadowCasters = 0,
		Invisible = 0,
		RootParts = 0,
		MaxDepth = 0,
		FromTemplates = 0,
		ByRole = {},
		ByTemplate = {},
	}

	local unanchored = newFinding(
		"unanchored",
		"High",
		"Unanchored static geometry",
		"Built parts are static, but these are unanchored: each one is simulated and will fall or settle."
	)
	local touch = newFinding(
		"touch",
		"Medium",
		"Touch events enabled",
		"Nothing listens for Touched on built parts (the only listeners are vessel hulls), so touch pairs are wasted."
	)
	local decorCollision = newFinding(
		"decor-collision",
		"Medium",
		"Decor that collides",
		"These are marked Decor (visual only) but still collide. Turning collision off leaves Structure, Walkable and Barrier untouched."
	)
	local decorQuery = newFinding(
		"decor-query",
		"Low",
		"Decor visible to queries",
		"Non-colliding Decor still answers raycasts and spatial queries (parkour probes, line of sight, picking)."
	)
	local shadows = newFinding(
		"shadows",
		"Low",
		"Shadows that add nothing",
		"Parts under a stud on every axis, and Neon, cast shadows that read as noise."
	)
	local duplicates = newFinding(
		"duplicates",
		"High",
		"Exact duplicates",
		"Parts with the same shape, size, position and orientation as another. Deleting the copies is destructive."
	)
	local invisibleDecor = newFinding(
		"invisible-decor",
		"Low",
		"Invisible, non-colliding Decor",
		"Fully transparent Decor that collides with nothing affects nothing. Deleting it is destructive."
	)
	local invisibleCollider = newFinding(
		"invisible-collider",
		"Medium",
		"Invisible parts that collide",
		"Fully transparent but solid. If that is intended, set their role to Barrier; otherwise check them."
	)
	local oversized = newFinding(
		"oversized",
		"Info",
		"Oversized parts",
		"Parts 256 studs or more on an axis stream and light as one block; split them if they span a region."
	)

	local seen: { [string]: string } = {}
	local parts: { NodeRecord } = {}

	for _, record in sorted do
		local depth = depthOf(byId, record)
		metrics.MaxDepth = math.max(metrics.MaxDepth, depth)
		if record.Kind == "Group" then
			metrics.Groups += 1
			continue
		end
		metrics.Parts += 1
		table.insert(parts, record)
		metrics.ByRole[record.Role] = (metrics.ByRole[record.Role] or 0) + 1
		if record.Template then
			metrics.FromTemplates += 1
			metrics.ByTemplate[record.Template] = (metrics.ByTemplate[record.Template] or 0) + 1
		end
		if record.Parent == nil then
			metrics.RootParts += 1
		end
		if not record.Anchored then
			metrics.Unanchored += 1
		end
		if record.CanCollide then
			metrics.Collidable += 1
		end
		if record.CanTouch then
			metrics.Touchable += 1
		end
		if record.CanQuery then
			metrics.Queryable += 1
		end
		if record.CastShadow then
			metrics.ShadowCasters += 1
		end
		local invisible = record.Transparency >= 1
		if invisible then
			metrics.Invisible += 1
		end

		-- Duplicates first: a part about to be deleted gets no other proposal.
		local key = signature(record)
		if seen[key] then
			note(duplicates, record.Id)
			propose(duplicates, record.Id, "Delete", true, "Destructive")
			continue
		end
		seen[key] = record.Id

		if invisible and record.Role == "Decor" and not record.CanCollide then
			note(invisibleDecor, record.Id)
			propose(invisibleDecor, record.Id, "Delete", true, "Destructive")
			continue
		end
		if invisible and record.CanCollide and record.Role ~= "Barrier" then
			note(invisibleCollider, record.Id)
		end

		if not record.Anchored then
			note(unanchored, record.Id)
			propose(unanchored, record.Id, "Anchored", true, "Safe")
		end
		if record.CanTouch then
			note(touch, record.Id)
			propose(touch, record.Id, "CanTouch", false, "Safe")
		end
		local willCollide = record.CanCollide
		if record.Role == "Decor" and record.CanCollide then
			note(decorCollision, record.Id)
			propose(decorCollision, record.Id, "CanCollide", false, "Safe")
			willCollide = false
		end
		if record.Role == "Decor" and record.CanQuery and not willCollide then
			note(decorQuery, record.Id)
			propose(decorQuery, record.Id, "CanQuery", false, "Safe")
		end
		local s = record.Size
		if record.CastShadow and ((s.X < 1 and s.Y < 1 and s.Z < 1) or record.Material == "Neon") then
			note(shadows, record.Id)
			propose(shadows, record.Id, "CastShadow", false, "Safe")
		end
		if math.max(s.X, s.Y, s.Z) >= 256 then
			note(oversized, record.Id)
		end
	end

	unanchored.Impact = `Removes {unanchored.Count} parts from physics simulation.`
	touch.Impact = `{touch.Count} fewer parts in the touch broadphase.`
	decorCollision.Impact =
		`{decorCollision.Count} fewer collidable parts; no Structure, Walkable or Barrier part changes.`
	decorQuery.Impact = `{decorQuery.Count} fewer parts answering raycasts and spatial queries.`
	shadows.Impact = `{shadows.Count} fewer shadow casters.`
	duplicates.Impact = `{duplicates.Count} redundant parts removed; the first of each set is kept.`
	invisibleDecor.Impact = `{invisibleDecor.Count} parts that affect nothing removed.`
	invisibleCollider.Impact = "Report only. No change is proposed."
	oversized.Impact = "Report only. No change is proposed."

	local overlap = newFinding(
		"overlap",
		"Low",
		"Heavily overlapping parts",
		"Pairs whose bounds overlap by more than 90% of the smaller part: often a duplicate placed slightly off."
	)
	for _, pair in overlaps(parts) do
		note(overlap, pair[1])
		note(overlap, pair[2])
	end
	overlap.Count //= 2
	overlap.Impact = "Report only. Review and delete the redundant part by hand."

	local findings: { Finding } = {}
	for _, finding in
		{
			unanchored,
			duplicates,
			touch,
			decorCollision,
			invisibleCollider,
			decorQuery,
			shadows,
			invisibleDecor,
			overlap,
			oversized,
		}
	do
		if finding.Count > 0 then
			table.insert(findings, finding)
		end
	end

	local budgetShare = metrics.Nodes / metrics.Budget
	if budgetShare >= 0.8 then
		local budget = newFinding(
			"budget",
			if budgetShare >= 0.95 then "High" else "Medium",
			"Close to the object budget",
			`{metrics.Nodes} of {metrics.Budget} nodes used. New placements will be refused at the limit.`
		)
		budget.Count = metrics.Nodes
		budget.Impact = "Report only."
		table.insert(findings, budget)
	end
	if metrics.RootParts > 150 then
		local loose = newFinding(
			"loose",
			"Info",
			"Loose root-level parts",
			`{metrics.RootParts} parts sit at the root. Grouping them makes the scene easier to select, move and save as templates.`
		)
		loose.Count = metrics.RootParts
		loose.Impact = "Report only."
		table.insert(findings, loose)
	end
	if metrics.MaxDepth > 5 then
		local deep = newFinding("deep", "Info", "Deep nesting", `Groups nest {metrics.MaxDepth} levels deep.`)
		deep.Count = metrics.MaxDepth
		deep.Impact = "Report only."
		table.insert(findings, deep)
	end

	table.sort(findings, function(a, b)
		if SEVERITY_ORDER[a.Severity] ~= SEVERITY_ORDER[b.Severity] then
			return SEVERITY_ORDER[a.Severity] < SEVERITY_ORDER[b.Severity]
		end
		return a.Count > b.Count
	end)

	local safe, destructive = 0, 0
	for _, finding in findings do
		for _, change in finding.Changes do
			if change.Safety == "Safe" then
				safe += 1
			else
				destructive += 1
			end
		end
	end
	return { Metrics = metrics, Findings = findings, SafeChanges = safe, DestructiveChanges = destructive }
end

-- The changes to apply: every Safe change, plus Destructive ones only when `includeDestructive`, restricted to the
-- findings named in `findingIds` (nil = all). Grouped per node: { [nodeId]: patch }, and the set of nodes to delete.
function ArchitectOptimizer.Plan(
	report: Report,
	findingIds: { string }?,
	includeDestructive: boolean
): ({ [string]: { [string]: any } }, { string })
	local wanted: { [string]: boolean }? = nil
	if findingIds then
		wanted = {}
		for _, id in findingIds do
			(wanted :: { [string]: boolean })[id] = true
		end
	end
	local patches: { [string]: { [string]: any } } = {}
	local deletes: { string } = {}
	for _, finding in report.Findings do
		if wanted == nil or (wanted :: { [string]: boolean })[finding.Id] then
			for _, change in finding.Changes do
				if change.Field == "Delete" then
					if includeDestructive then
						table.insert(deletes, change.NodeId)
					end
				elseif change.Safety == "Safe" or includeDestructive then
					local patch = patches[change.NodeId] or {}
					patch[change.Field] = change.To
					patches[change.NodeId] = patch
				end
			end
		end
	end
	return patches, deletes
end

-- The report without its per-change lists, for the wire: Count and capped Nodes per finding are enough to draw it.
function ArchitectOptimizer.ForWire(report: Report): Report
	local findings: { Finding } = {}
	for _, finding in report.Findings do
		local copy = table.clone(finding)
		local safe, destructive = 0, 0
		for _, change in finding.Changes do
			if change.Safety == "Safe" then
				safe += 1
			else
				destructive += 1
			end
		end
		copy.Changes = {}
		(copy :: any).SafeCount = safe;
		(copy :: any).DestructiveCount = destructive
		table.insert(findings, copy)
	end
	return {
		Metrics = report.Metrics,
		Findings = findings,
		SafeChanges = report.SafeChanges,
		DestructiveChanges = report.DestructiveChanges,
	}
end

return ArchitectOptimizer
