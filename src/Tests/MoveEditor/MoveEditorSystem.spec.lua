--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local MoveEditorSystem = require(ServerScriptService.Server.Systems.MoveEditorSystem)

-- The System's remotes are admin-gated and DataStore-backed, which this harness cannot stand up (see
-- scripts/run-tests.lua). What it CAN pin is the pure part an author actually reads -- the notes each
-- entry carries -- and that the New-move template is a move the server accepts unchanged.

local function move(overrides: { [string]: any }?): MoveTypes.MoveDefinition
	local candidate: { [string]: any } = {
		MoveId = "spec-move",
		DisplayName = "Spec",
		Author = "Spec",
		CreatedAt = 1,
		UpdatedAt = 1,
		Shape = "Sphere",
		Dimensions = { Radius = 3 },
		OffsetX = 0,
		OffsetY = 0,
		OffsetZ = -3,
		WindupSeconds = 0.3,
		ActiveSeconds = 0.2,
		RecoverySeconds = 0.3,
		Cooldown = 0.8,
		Damage = 10,
		PostureDamage = 8,
		Art = { TreeId = "common_foundation", Node = 1, QiCost = 10, RequiredTier = 1 },
	}
	for key, value in pairs(overrides or {}) do
		candidate[key] = value
	end
	-- `Art = false` in an override means "no art block": a nil in a table literal would not override.
	if candidate.Art == false then
		candidate.Art = nil
	end
	return MoveRegistryManager.Validate(candidate) :: MoveTypes.MoveDefinition
end

local CLEAN_TIMING = {
	WindupSeconds = 0.3,
	ActiveSeconds = 0.2,
	RecoverySeconds = 0.3,
	Cooldown = 0.8,
	PlaybackSpeed = 1,
	AnimationId = "rbxassetid://1",
	ClipSeconds = 0.8,
}

local function noArts(_artId: string): boolean
	return false
end

local function notesFor(subject: MoveTypes.MoveDefinition, source: "Custom" | "Default", timing: any?): { string }
	return MoveEditorSystem.DescribeMove(subject, source, timing, noArts)
end

local function mentions(notes: { string }, fragment: string): boolean
	for _, note in notes do
		if string.find(note, fragment, 1, true) then
			return true
		end
	end
	return false
end

return function()
	describe("MoveEditorSystem.DescribeMove", function()
		it("says nothing about a clean, root-anchored art with a synced clip", function()
			expect(#notesFor(move(), "Custom", CLEAN_TIMING)).to.equal(0)
		end)

		it("warns that a custom move with no art binding is unreachable in play", function()
			expect(mentions(notesFor(move({ Art = false }), "Custom", CLEAN_TIMING), "no player can reach it")).to.equal(
				true
			)
			-- A weapon move is reached by its string, not a slot.
			expect(mentions(notesFor(move({ Art = false }), "Default", CLEAN_TIMING), "no player can reach it")).to.equal(
				false
			)
		end)

		it("warns that a weapon-anchored Box takes the blade's size", function()
			local notes = notesFor(
				move({ Shape = "Box", Dimensions = { Width = 2, Height = 2, Length = 2 }, AttachmentPart = "Weapon" }),
				"Custom",
				CLEAN_TIMING
			)
			expect(mentions(notes, "blade's own size")).to.equal(true)
		end)

		it("warns when the hitbox is still open after the clip ends", function()
			local timing = table.clone(CLEAN_TIMING)
			timing.ClipSeconds = 0.4
			expect(mentions(notesFor(move(), "Custom", timing), "still open when the clip ends")).to.equal(true)
		end)

		it("says when the clip has not been read, and when there is none", function()
			local unread = table.clone(CLEAN_TIMING)
			unread.ClipSeconds = nil
			expect(mentions(notesFor(move(), "Custom", unread), "has not been read yet")).to.equal(true)
			local none = table.clone(CLEAN_TIMING)
			none.AnimationId = ""
			none.ClipSeconds = nil
			expect(mentions(notesFor(move(), "Custom", none), "No clip")).to.equal(true)
		end)

		it("warns about a prerequisite that is not an art", function()
			local subject = move({
				Art = {
					TreeId = "common_foundation",
					Node = 2,
					QiCost = 10,
					RequiredTier = 1,
					Prerequisite = "missing-art",
				},
			})
			expect(mentions(notesFor(subject, "Custom", CLEAN_TIMING), "can never be unlocked")).to.equal(true)
		end)

		it("warns when the catalogue cannot resolve the move at all", function()
			expect(mentions(notesFor(move(), "Custom", nil), "cannot resolve")).to.equal(true)
		end)
	end)

	describe("Constants.MoveEditor.NewMoveTemplate", function()
		it("is a move the server accepts without clamping anything", function()
			local template = Constants.MoveEditor.NewMoveTemplate
			local validated = MoveRegistryManager.Validate({
				MoveId = "template",
				DisplayName = template.DisplayName,
				Author = "Spec",
				CreatedAt = 0,
				UpdatedAt = 0,
				Shape = template.Shape,
				Dimensions = template.Dimensions,
				OffsetX = 0,
				OffsetY = 0,
				OffsetZ = template.OffsetZ,
				WindupSeconds = template.WindupSeconds,
				ActiveSeconds = template.ActiveSeconds,
				RecoverySeconds = template.RecoverySeconds,
				Cooldown = template.Cooldown,
				Damage = template.Damage,
				PostureDamage = template.PostureDamage,
				MaxTargets = template.MaxTargets,
			}) :: any
			expect(validated).to.be.ok()
			for field, value in pairs(template.Dimensions) do
				expect(validated.Dimensions[field]).to.equal(value)
			end
			expect(validated.WindupSeconds).to.equal(template.WindupSeconds)
			expect(validated.Cooldown).to.equal(template.Cooldown)
			expect(validated.Damage).to.equal(template.Damage)
		end)
	end)
end
