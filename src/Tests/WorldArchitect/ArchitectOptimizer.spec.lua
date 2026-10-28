--!strict
-- ArchitectOptimizer: real counts, role-aware proposals, and the gameplay-critical properties it must never touch.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArchitectOptimizer = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectOptimizer)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)

type NodeRecord = ArchitectRecord.NodeRecord

local function part(id: string, role: string, overrides: { [string]: any }?): NodeRecord
	local record = ArchitectRecord.Default("Part", role, id)
	record.Position = Vector3.new(#id * 10, 0, 0)
	for key, value in overrides or {} do
		(record :: any)[key] = value
	end
	return record
end

local function finding(report: ArchitectOptimizer.Report, id: string): ArchitectOptimizer.Finding?
	for _, entry in report.Findings do
		if entry.Id == id then
			return entry
		end
	end
	return nil
end

return function()
	it("counts what the records actually hold", function()
		local report = ArchitectOptimizer.Analyze({
			part("a", "Structure", { Anchored = false }),
			part("bb", "Decor"),
			ArchitectRecord.Default("Group", nil, "g"),
		})
		expect(report.Metrics.Nodes).to.equal(3)
		expect(report.Metrics.Parts).to.equal(2)
		expect(report.Metrics.Groups).to.equal(1)
		expect(report.Metrics.Unanchored).to.equal(1)
		expect(report.Metrics.Collidable).to.equal(1)
	end)

	it("proposes anchoring unanchored parts as a safe change", function()
		local report = ArchitectOptimizer.Analyze({ part("a", "Structure", { Anchored = false }) })
		local entry = finding(report, "unanchored")
		assert(entry, "finding")
		expect(entry.Changes[1].Field).to.equal("Anchored")
		expect(entry.Changes[1].To).to.equal(true)
		expect(entry.Changes[1].Safety).to.equal("Safe")
	end)

	it("never proposes collision or query changes for Structure, Walkable or Barrier", function()
		local report = ArchitectOptimizer.Analyze({
			part("a", "Structure", { CanTouch = true }),
			part("bb", "Walkable"),
			part("ccc", "Barrier", { Transparency = 1 }),
		})
		for _, entry in report.Findings do
			for _, change in entry.Changes do
				expect(change.Field ~= "CanCollide" and change.Field ~= "CanQuery").to.equal(true)
			end
		end
	end)

	it("turns collision off for colliding Decor, and queries only once it no longer collides", function()
		local report = ArchitectOptimizer.Analyze({ part("a", "Decor", { CanCollide = true, CanQuery = true }) })
		expect(finding(report, "decor-collision")).to.be.ok()
		expect(finding(report, "decor-query")).to.be.ok()
		local patches = ArchitectOptimizer.Plan(report, nil, false)
		expect(patches.a.CanCollide).to.equal(false)
		expect(patches.a.CanQuery).to.equal(false)
	end)

	it("marks exact duplicates destructive and keeps the first of each set", function()
		local report = ArchitectOptimizer.Analyze({
			part("a", "Structure", { Position = Vector3.zero }),
			part("b", "Structure", { Position = Vector3.zero }),
		})
		local entry = finding(report, "duplicates")
		assert(entry, "duplicates finding")
		expect(entry.Count).to.equal(1)
		expect(entry.Changes[1].NodeId).to.equal("b")
		expect(entry.Changes[1].Safety).to.equal("Destructive")
	end)

	it("Plan leaves destructive changes out unless asked", function()
		local report = ArchitectOptimizer.Analyze({
			part("a", "Structure", { Position = Vector3.zero }),
			part("b", "Structure", { Position = Vector3.zero }),
		})
		local _, safeDeletes = ArchitectOptimizer.Plan(report, nil, false)
		local _, allDeletes = ArchitectOptimizer.Plan(report, nil, true)
		expect(#safeDeletes).to.equal(0)
		expect(#allDeletes).to.equal(1)
	end)

	it("Plan honours the chosen findings", function()
		local report = ArchitectOptimizer.Analyze({ part("a", "Decor", { Anchored = false, CanCollide = true }) })
		local patches = ArchitectOptimizer.Plan(report, { "unanchored" }, false)
		expect(patches.a.Anchored).to.equal(true)
		expect(patches.a.CanCollide).to.equal(nil)
	end)

	it("reports invisible colliders without proposing a change", function()
		local report = ArchitectOptimizer.Analyze({ part("a", "Structure", { Transparency = 1 }) })
		local entry = finding(report, "invisible-collider")
		assert(entry, "finding")
		expect(#entry.Changes).to.equal(0)
	end)

	it("orders findings by severity", function()
		local report = ArchitectOptimizer.Analyze({
			part("a", "Structure", { Anchored = false }),
			part("bb", "Decor", { Size = Vector3.new(0.5, 0.5, 0.5) }),
		})
		expect(report.Findings[1].Severity).to.equal("High")
	end)

	it("ForWire strips per-change lists but keeps their counts", function()
		local report =
			ArchitectOptimizer.ForWire(ArchitectOptimizer.Analyze({ part("a", "Structure", { Anchored = false }) }))
		expect(#report.Findings[1].Changes).to.equal(0)
		expect((report.Findings[1] :: any).SafeCount).to.equal(1)
	end)
end
