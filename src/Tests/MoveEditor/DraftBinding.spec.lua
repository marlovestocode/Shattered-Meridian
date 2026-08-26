--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local DraftBinding = require(StarterPlayer.StarterPlayerScripts.Client.UI.Screens.DevTools.MoveEditor.DraftBinding)

-- Apply and Field are the two primitives every form panel in the Move Editor commits and reads
-- through, and neither needs a mounted screen to exercise: Apply is clone-then-mutate-then-publish
-- over plain tables, and Field is one Computed. Row/Stack/TextRow/VisibleWhen build real Instances
-- and are deliberately NOT covered here -- they are layout, and a headless assertion about a Frame's
-- children would test Fusion rather than this module.
--
-- The contract worth pinning is Apply's CLONE DEPTH. It is shallow on purpose (see its own header),
-- which means the record handed to OnFieldChanged must be a different table from the one in Draft,
-- while every sub-table is still SHARED -- and that shared-ness is precisely why each panel clones
-- the sub-table it is about to write. A silent change to either half is how an edit starts reaching
-- back into the previous draft that MoveList's own cache is still holding.

local function makeDraft(): MoveTypes.MoveDefinition
	return {
		MoveId = "spec-move",
		DisplayName = "Spec Move",
		Description = "",
		Category = "Testing",
		Author = "Spec",
		CreatedAt = 0,
		UpdatedAt = 0,
		Shape = "Box",
		Dimensions = {
			Width = 4,
			Height = 4,
			Depth = 4,
			Length = 0,
			Thickness = 0,
			Radius = 0,
			InnerRadius = 0,
			AngleDegrees = 0,
		},
		Size = Vector3.new(4, 4, 4),
		Radius = nil,
		Offset = CFrame.new(0, 0, -3),
		OffsetRotation = Vector3.zero,
		WindupSeconds = 0.2,
		ActiveSeconds = 0.15,
		RecoverySeconds = 0.3,
		Cooldown = 0.6,
		Damage = 5,
		PostureDamage = 5,
		ArcDegrees = 100,
		MaxTargets = 5,
		AnimationId = "",
		Animations = {},
		Movement = { LungeDistanceStuds = 8, LungeDurationSeconds = 0.2 },
		Knockback = nil,
		Grab = nil,
		Slam = nil,
		Projectile = nil,
		ObjectStun = nil,
		Art = nil,
	} :: any
end

-- The shape every panel receives: a Value to read from, and somewhere for a committed record to go.
-- `published` is what OnFieldChanged was last handed, which is the only thing Apply actually produces.
local function makeContext(scope: any): (DraftBinding.DraftContext, () -> MoveTypes.MoveDefinition?)
	local draft: Fusion.Value<MoveTypes.MoveDefinition?> = scope:Value(makeDraft())
	local published: MoveTypes.MoveDefinition? = nil
	local context: DraftBinding.DraftContext = {
		Draft = draft,
		OnFieldChanged = function(updated: MoveTypes.MoveDefinition)
			published = updated
		end,
	}
	return context, function()
		return published
	end
end

return function()
	describe("DraftBinding.Apply", function()
		it("publishes a record carrying the mutation", function()
			local scope = Fusion.scoped(Fusion)
			local context, lastPublished = makeContext(scope)

			DraftBinding.Apply(context, function(updated)
				updated.Damage = 42
			end)

			local published = lastPublished()
			expect(published).to.be.ok()
			expect((published :: MoveTypes.MoveDefinition).Damage).to.equal(42)
			Fusion.doCleanup(scope)
		end)

		-- Apply never writes Draft: the screen does that optimistically before forwarding, so a panel
		-- that assumed Apply had already landed would be reading one edit behind.
		it("does not write the draft Value itself", function()
			local scope = Fusion.scoped(Fusion)
			local context, _ = makeContext(scope)
			local before = Fusion.peek(context.Draft) :: MoveTypes.MoveDefinition

			DraftBinding.Apply(context, function(updated)
				updated.Damage = 42
			end)

			expect(before.Damage).to.equal(5)
			expect(Fusion.peek(context.Draft)).to.equal(before)
			Fusion.doCleanup(scope)
		end)

		it("hands over a different table, so a top-level write never touches the old record", function()
			local scope = Fusion.scoped(Fusion)
			local context, lastPublished = makeContext(scope)
			local before = Fusion.peek(context.Draft) :: MoveTypes.MoveDefinition

			DraftBinding.Apply(context, function(updated)
				updated.Damage = 42
			end)

			expect(lastPublished()).never.to.equal(before)
			Fusion.doCleanup(scope)
		end)

		-- The half that is easy to forget, and the reason every panel clones the sub-table it edits.
		it("SHARES sub-tables, which is why a panel must clone the one it writes", function()
			local scope = Fusion.scoped(Fusion)
			local context, lastPublished = makeContext(scope)
			local before = Fusion.peek(context.Draft) :: MoveTypes.MoveDefinition

			DraftBinding.Apply(context, function(updated)
				updated.Damage = 42
			end)

			local published = lastPublished() :: MoveTypes.MoveDefinition
			expect(published.Movement).to.equal(before.Movement)
		end)

		it("keeps the old record intact when a panel clones the sub-table first", function()
			local scope = Fusion.scoped(Fusion)
			local context, lastPublished = makeContext(scope)
			local before = Fusion.peek(context.Draft) :: MoveTypes.MoveDefinition

			-- Exactly what EffectsEditor.applyToSubTable and ObjectStunEditor.applyStun do.
			DraftBinding.Apply(context, function(updated)
				local movement = table.clone(updated.Movement :: any)
				movement.LungeDistanceStuds = 99
				updated.Movement = movement
			end)

			local published = lastPublished() :: MoveTypes.MoveDefinition
			expect((published.Movement :: any).LungeDistanceStuds).to.equal(99)
			expect((before.Movement :: any).LungeDistanceStuds).to.equal(8)
			Fusion.doCleanup(scope)
		end)

		it("publishes nothing when no move is selected", function()
			local scope = Fusion.scoped(Fusion)
			local context, lastPublished = makeContext(scope)
			context.Draft:set(nil)

			DraftBinding.Apply(context, function(updated)
				updated.Damage = 42
			end)

			expect(lastPublished()).to.equal(nil)
			Fusion.doCleanup(scope)
		end)
	end)

	describe("DraftBinding.Field", function()
		it("reads the field off the current draft", function()
			local scope = Fusion.scoped(Fusion)
			local context, _ = makeContext(scope)

			local damage = DraftBinding.Field(context, scope, function(d): number
				return d.Damage
			end, 0)
			expect(Fusion.peek(damage)).to.equal(5)
			Fusion.doCleanup(scope)
		end)

		-- The whole reason this exists: no control anywhere has to nil-check its own Value prop.
		it("falls back to the default while nothing is selected", function()
			local scope = Fusion.scoped(Fusion)
			local context, _ = makeContext(scope)
			context.Draft:set(nil)

			local damage = DraftBinding.Field(context, scope, function(d): number
				return d.Damage
			end, 7)
			expect(Fusion.peek(damage)).to.equal(7)
			Fusion.doCleanup(scope)
		end)

		it("tracks a draft change rather than freezing at its first read", function()
			local scope = Fusion.scoped(Fusion)
			local context, _ = makeContext(scope)

			local damage = DraftBinding.Field(context, scope, function(d): number
				return d.Damage
			end, 0)
			expect(Fusion.peek(damage)).to.equal(5)

			local next = makeDraft()
			next.Damage = 11
			context.Draft:set(next)
			expect(Fusion.peek(damage)).to.equal(11)
			Fusion.doCleanup(scope)
		end)
	end)
end
