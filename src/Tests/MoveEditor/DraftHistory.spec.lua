--!strict
-- Covers Shared/Authoring/DraftHistory.lua -- the Move Editor's undo/redo stacks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DraftHistory = require(ReplicatedStorage.Shared.Authoring.DraftHistory)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local COALESCE = 0.4

-- A move whose Damage is the only thing that varies -- enough to tell drafts apart.
local function draft(moveId: string, damage: number): MoveTypes.MoveDefinition
	return {
		MoveId = moveId,
		DisplayName = "Spec",
		Description = "",
		Category = "",
		Author = "Spec",
		CreatedAt = 1,
		UpdatedAt = 1,
		Shape = "Box",
		Dimensions = { Width = 4, Height = 5, Length = 5, Radius = 2, InnerRadius = 0, AngleDegrees = 90 },
		Offset = CFrame.new(0, 0, -3),
		OffsetRotation = Vector3.zero,
		AttachmentPart = "Root",
		LocksMovement = false,
		WindupSeconds = 0.3,
		ActiveSeconds = 0.15,
		RecoverySeconds = 0.35,
		Cooldown = 0.8,
		Damage = damage,
		PostureDamage = 8,
		AnimationId = "",
	}
end

-- Records the edits damage 1 -> 2 -> ... -> n on `moveId`, each far enough apart not to coalesce.
local function editThrough(history: DraftHistory.History, moveId: string, n: number): MoveTypes.MoveDefinition
	for damage = 1, n - 1 do
		history:Record(moveId, draft(moveId, damage), damage * 10)
	end
	return draft(moveId, n)
end

return function()
	describe("DraftHistory -- order", function()
		it("undoes newest first and redoes in the order it undid", function()
			local history = DraftHistory.new(50, COALESCE)
			local current = editThrough(history, "a", 3)

			local back1 = history:Undo("a", current) :: MoveTypes.MoveDefinition
			expect(back1.Damage).to.equal(2)
			local back2 = history:Undo("a", back1) :: MoveTypes.MoveDefinition
			expect(back2.Damage).to.equal(1)
			expect(history:Undo("a", back2)).to.equal(nil)

			local forward1 = history:Redo("a", back2) :: MoveTypes.MoveDefinition
			expect(forward1.Damage).to.equal(2)
			local forward2 = history:Redo("a", forward1) :: MoveTypes.MoveDefinition
			expect(forward2.Damage).to.equal(3)
			expect(history:Redo("a", forward2)).to.equal(nil)
		end)

		it("drops the redo stack when a new edit lands after an undo", function()
			local history = DraftHistory.new(50, COALESCE)
			local current = editThrough(history, "a", 3)
			local back = history:Undo("a", current) :: MoveTypes.MoveDefinition
			expect(history:CanRedo("a")).to.equal(true)

			history:Record("a", back, 1000)
			expect(history:CanRedo("a")).to.equal(false)
			expect(history:CanUndo("a")).to.equal(true)
		end)

		it("reports what it can do", function()
			local history = DraftHistory.new(50, COALESCE)
			expect(history:CanUndo("a")).to.equal(false)
			expect(history:CanRedo("a")).to.equal(false)
			history:Record("a", draft("a", 1), 0)
			expect(history:CanUndo("a")).to.equal(true)
			expect(history:CanRedo("a")).to.equal(false)
		end)
	end)

	describe("DraftHistory -- coalescing", function()
		it("turns a burst of edits into one step, however long the burst", function()
			local history = DraftHistory.new(50, COALESCE)
			-- Twenty edits 0.1s apart: the window slides with each, so only the first records.
			for i = 1, 20 do
				history:Record("a", draft("a", i), i * 0.1)
			end
			local back = history:Undo("a", draft("a", 21)) :: MoveTypes.MoveDefinition
			expect(back.Damage).to.equal(1)
			expect(history:CanUndo("a")).to.equal(false)
		end)

		it("records an edit that arrives after the window", function()
			local history = DraftHistory.new(50, COALESCE)
			history:Record("a", draft("a", 1), 0)
			history:Record("a", draft("a", 2), COALESCE + 0.01)
			local back = history:Undo("a", draft("a", 3)) :: MoveTypes.MoveDefinition
			expect(back.Damage).to.equal(2)
		end)

		it("never merges the first edit after an undo into the step it undid", function()
			local history = DraftHistory.new(50, COALESCE)
			history:Record("a", draft("a", 1), 0)
			local back = history:Undo("a", draft("a", 2)) :: MoveTypes.MoveDefinition
			-- Immediately after the undo, well inside what would have been the window.
			history:Record("a", back, 0.05)
			expect(history:CanUndo("a")).to.equal(true)
		end)
	end)

	describe("DraftHistory -- isolation and bounds", function()
		it("keeps one history per move", function()
			local history = DraftHistory.new(50, COALESCE)
			history:Record("a", draft("a", 1), 0)
			expect(history:CanUndo("b")).to.equal(false)
			expect(history:Undo("b", draft("b", 5))).to.equal(nil)
			-- A burst on another move does not coalesce into this one.
			history:Record("b", draft("b", 1), 0.1)
			expect(history:CanUndo("b")).to.equal(true)
		end)

		it("evicts the oldest step past its capacity", function()
			local history = DraftHistory.new(3, COALESCE)
			local current = editThrough(history, "a", 6)
			local seen: { number } = {}
			local step: MoveTypes.MoveDefinition? = history:Undo("a", current)
			while step do
				table.insert(seen, step.Damage)
				step = history:Undo("a", step)
			end
			expect(table.concat(seen, ",")).to.equal("5,4,3")
		end)

		it("forgets a move on Clear", function()
			local history = DraftHistory.new(50, COALESCE)
			local current = editThrough(history, "a", 3)
			history:Undo("a", current)
			history:Clear("a")
			expect(history:CanUndo("a")).to.equal(false)
			expect(history:CanRedo("a")).to.equal(false)
		end)

		it("stores copies, so mutating a draft afterwards cannot rewrite history", function()
			local history = DraftHistory.new(50, COALESCE)
			local before = draft("a", 1)
			history:Record("a", before, 0)
			before.Damage = 99
			before.Dimensions.Width = 99
			local back = history:Undo("a", draft("a", 2)) :: MoveTypes.MoveDefinition
			expect(back.Damage).to.equal(1)
			expect(back.Dimensions.Width).to.equal(4)
			-- And what it hands back is a copy too.
			back.Damage = 50
			local forward = history:Redo("a", back) :: MoveTypes.MoveDefinition
			expect(forward.Damage).to.equal(2)
			local again = history:Undo("a", forward) :: MoveTypes.MoveDefinition
			expect(again.Damage).to.equal(50)
		end)
	end)
end
