--!strict
local StarterPlayer = game:GetService("StarterPlayer")
local MoveEditState = require(StarterPlayer.StarterPlayerScripts.Client.MoveEditor.MoveEditState)

-- Undo/redo is a state machine whose failures are all silent: a redo branch that survives a fresh
-- edit hands back a state the author already replaced, a stack that never trims grows for the whole
-- session, and a deleted move whose history stayed behind can be pushed back to the server by one
-- Ctrl+Z (UpdateDraft mints a fresh MoveId for an unknown one -- see MoveEditorClient's own
-- cancelPendingDraftUpdate). None of those show up in a manual pass, and none of them need a mounted
-- screen to find, which is exactly why this state lives in its own module -- see its header.

-- Only the fields this module actually touches (MoveId, and something to tell states apart by).
-- MoveEditState is deliberately blind to the rest of the record: it stores whole drafts by reference
-- and never reads into them, so a real MoveDefinition here would test MoveTypes, not this.
local function draft(moveId: string, damage: number): any
	return { MoveId = moveId, Damage = damage }
end

return function()
	describe("MoveEditState.Record", function()
		it("does not push an undo entry before a baseline exists", function()
			local state = MoveEditState.New()
			state:Record(draft("a", 1))
			expect(state:Undo(draft("a", 1))).to.equal(nil)
		end)

		it("makes the previous state -- not the new one -- the undo entry", function()
			local state = MoveEditState.New()
			local loaded = draft("a", 1)
			state:SetBaseline("a", loaded)

			local edited = draft("a", 2)
			state:Record(edited)

			expect(state:Undo(edited)).to.equal(loaded)
		end)

		it("marks the move unsaved", function()
			local state = MoveEditState.New()
			expect(state:UnsavedCount()).to.equal(0)
			state:Record(draft("a", 1))
			expect(state:UnsavedCount()).to.equal(1)
		end)

		it("counts moves, not edits", function()
			local state = MoveEditState.New()
			state:Record(draft("a", 1))
			state:Record(draft("a", 2))
			state:Record(draft("a", 3))
			state:Record(draft("b", 1))
			expect(state:UnsavedCount()).to.equal(2)
		end)

		-- The bound that keeps a long tuning session from retaining every state it ever passed through.
		it("caps a move's history at the configured depth", function()
			local state = MoveEditState.New(3)
			state:SetBaseline("a", draft("a", 0))
			for damage = 1, 10 do
				state:Record(draft("a", damage))
			end

			-- Three undos available, and the fourth finds nothing.
			local current = draft("a", 10)
			for _ = 1, 3 do
				local restored = state:Undo(current)
				expect(restored).to.be.ok()
				current = restored :: any
			end
			expect(state:Undo(current)).to.equal(nil)
		end)
	end)

	describe("MoveEditState.Undo / Redo", function()
		it("walks back through several edits in order", function()
			local state = MoveEditState.New()
			local v1, v2, v3 = draft("a", 1), draft("a", 2), draft("a", 3)
			state:SetBaseline("a", v1)
			state:Record(v2)
			state:Record(v3)

			expect(state:Undo(v3)).to.equal(v2)
			expect(state:Undo(v2)).to.equal(v1)
			expect(state:Undo(v1)).to.equal(nil)
		end)

		it("redo returns what undo stepped away from", function()
			local state = MoveEditState.New()
			local v1, v2 = draft("a", 1), draft("a", 2)
			state:SetBaseline("a", v1)
			state:Record(v2)

			expect(state:Undo(v2)).to.equal(v1)
			expect(state:Redo(v1)).to.equal(v2)
		end)

		it("has nothing to redo until something has been undone", function()
			local state = MoveEditState.New()
			state:SetBaseline("a", draft("a", 1))
			state:Record(draft("a", 2))
			expect(state:Redo(draft("a", 2))).to.equal(nil)
		end)

		-- The rule every undo stack has and the one most easily left out: the states ahead of the
		-- cursor described a future that a fresh edit has just replaced.
		it("drops the redo branch when a new edit lands", function()
			local state = MoveEditState.New()
			local v1, v2 = draft("a", 1), draft("a", 2)
			state:SetBaseline("a", v1)
			state:Record(v2)
			expect(state:Undo(v2)).to.equal(v1)

			state:Record(draft("a", 99))
			expect(state:Redo(draft("a", 99))).to.equal(nil)
		end)

		-- The bug the per-move keying exists to prevent: editing A, switching to B, and undoing there
		-- used to be able to reach into whichever history was most recent rather than B's own.
		it("keeps each move's history to itself", function()
			local state = MoveEditState.New()
			local a1, a2 = draft("a", 1), draft("a", 2)
			local b1, b2 = draft("b", 1), draft("b", 2)
			state:SetBaseline("a", a1)
			state:SetBaseline("b", b1)
			state:Record(a2)
			state:Record(b2)

			expect(state:Undo(b2)).to.equal(b1)
			-- B's history is now empty; A's is untouched.
			expect(state:Undo(b1)).to.equal(nil)
			expect(state:Undo(a2)).to.equal(a1)
		end)

		it("leaves the baseline where the step landed, so the next edit undoes to it", function()
			local state = MoveEditState.New()
			local v1, v2 = draft("a", 1), draft("a", 2)
			state:SetBaseline("a", v1)
			state:Record(v2)
			state:Undo(v2)

			local v3 = draft("a", 3)
			state:Record(v3)
			expect(state:Undo(v3)).to.equal(v1)
		end)
	end)

	describe("MoveEditState.MarkSaved", function()
		it("clears the move's unsaved mark without touching its history", function()
			local state = MoveEditState.New()
			local v1, v2 = draft("a", 1), draft("a", 2)
			state:SetBaseline("a", v1)
			state:Record(v2)

			state:MarkSaved("a")
			expect(state:UnsavedCount()).to.equal(0)
			-- A save is not a history boundary: undoing past one is exactly what an author who saved
			-- by reflex and then thought better of it needs.
			expect(state:Undo(v2)).to.equal(v1)
		end)

		it("leaves other moves' marks alone", function()
			local state = MoveEditState.New()
			state:Record(draft("a", 1))
			state:Record(draft("b", 1))
			state:MarkSaved("a")
			expect(state:UnsavedCount()).to.equal(1)
		end)

		-- Undo re-diverges from storage even when it lands back on the loaded values: every
		-- intermediate edit already reached the server's live registry, and only a Save reconciles it.
		it("does not survive a subsequent undo", function()
			local state = MoveEditState.New()
			local v1, v2 = draft("a", 1), draft("a", 2)
			state:SetBaseline("a", v1)
			state:Record(v2)
			state:MarkSaved("a")

			state:Undo(v2)
			expect(state:UnsavedCount()).to.equal(1)
		end)
	end)

	describe("MoveEditState.Forget", function()
		-- The one that matters: a surviving undo stack for a deleted move can push it back to the
		-- server, where an unknown MoveId is minted fresh rather than rejected.
		it("leaves a deleted move with no history to restore", function()
			local state = MoveEditState.New()
			local v1, v2 = draft("a", 1), draft("a", 2)
			state:SetBaseline("a", v1)
			state:Record(v2)

			state:Forget("a")
			expect(state:Undo(v2)).to.equal(nil)
			expect(state:Redo(v2)).to.equal(nil)
			expect(state:Baseline("a")).to.equal(nil)
			expect(state:UnsavedCount()).to.equal(0)
		end)

		it("leaves every other move intact", function()
			local state = MoveEditState.New()
			local b1, b2 = draft("b", 1), draft("b", 2)
			state:SetBaseline("a", draft("a", 1))
			state:SetBaseline("b", b1)
			state:Record(draft("a", 2))
			state:Record(b2)

			state:Forget("a")
			expect(state:UnsavedCount()).to.equal(1)
			expect(state:Undo(b2)).to.equal(b1)
		end)
	end)
end
