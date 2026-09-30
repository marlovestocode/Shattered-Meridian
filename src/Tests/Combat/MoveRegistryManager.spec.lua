--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)

local LIMITS = Constants.MoveEditor.Limits

-- Validate is the one gate a client draft, a DataStore record and a Default override all pass, so its
-- two answers are pinned separately: a table that is not a move is REJECTED with a stable reason code
-- (the editor turns those into prose), a move with an out-of-range number is CLAMPED.
--
-- Every case that touches the registry starts from Init(): TestEZ runs every spec in one VM, and the
-- registry is module state.

local function wire(overrides: { [string]: any }?): { [string]: any }
	local candidate: { [string]: any } = {
		MoveId = "spec-move",
		DisplayName = "Spec Move",
		Author = "Spec",
		CreatedAt = 1,
		UpdatedAt = 2,
		Shape = "Box",
		Dimensions = { Width = 4, Height = 5, Length = 6 },
		OffsetX = 0,
		OffsetY = 0,
		OffsetZ = -3,
		WindupSeconds = 0.3,
		ActiveSeconds = 0.15,
		RecoverySeconds = 0.35,
		Cooldown = 0.8,
		Damage = 10,
		PostureDamage = 8,
	}
	for key, value in pairs(overrides or {}) do
		candidate[key] = value
	end
	return candidate
end

return function()
	-- Inside the returned function on purpose: TestEZ injects `expect` into THIS function's environment
	-- only, so a module-level helper calling it calls nil.
	local function rejects(overrides: { [string]: any }, reason: string): ()
		local validated, actual = MoveRegistryManager.Validate(wire(overrides))
		expect(validated).to.equal(nil)
		expect(actual).to.equal(reason)
	end

	describe("MoveRegistryManager.Validate -- rejections", function()
		it("rejects anything that is not a table", function()
			local validated, reason = MoveRegistryManager.Validate("move")
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidShape")
		end)

		it("rejects a missing identity", function()
			rejects({ MoveId = "" }, "InvalidMoveId")
			rejects({ DisplayName = "   " }, "InvalidDisplayName")
			rejects({ Author = "" }, "InvalidAuthor")
			rejects({ CreatedAt = "yesterday" }, "InvalidTimestamp")
		end)

		it("rejects a shape the engine does not have, including the retired twelve-shape names", function()
			rejects({ Shape = "Hexagon" }, "InvalidShapeKind")
			rejects({ Shape = "Wedge" }, "InvalidShapeKind")
			rejects({ Shape = "Disc" }, "InvalidShapeKind")
		end)

		it("rejects geometry it cannot place", function()
			rejects({ Dimensions = "big" }, "MissingDimensions")
			rejects({ OffsetZ = "forward" }, "InvalidOffset")
			rejects({ AttachmentPart = "Tail" }, "InvalidAttachmentPart")
		end)

		it("rejects non-numeric timing and damage", function()
			rejects({ WindupSeconds = "soon" }, "InvalidTiming")
			rejects({ Cooldown = 0 / 0 }, "InvalidTiming")
			rejects({ Damage = "lots" }, "InvalidDamage")
			rejects({ MaxTargets = "all" }, "InvalidMaxTargets")
			rejects({ AnimationId = 12345 }, "InvalidAnimationId")
		end)

		it("rejects a malformed optional block rather than dropping it", function()
			rejects({ Knockback = "far" }, "InvalidKnockback")
			rejects({ Knockback = { UpVelocity = 1 } }, "InvalidKnockback")
			rejects(
				{ Knockback = { UpVelocity = 1, HorizontalVelocity = 1, StartsAirCombo = "yes" } },
				"InvalidKnockback"
			)
			rejects({ Grab = { HoldSeconds = 1 } }, "InvalidGrab")
			rejects({ Art = "art" }, "InvalidArt")
		end)
	end)

	describe("MoveRegistryManager.Validate -- normalisation", function()
		it("clamps out-of-range numbers into Constants.MoveEditor.Limits", function()
			local validated = MoveRegistryManager.Validate(wire({
				WindupSeconds = 99,
				Cooldown = -5,
				Damage = 5000,
				OffsetZ = -400,
				Dimensions = { Width = 0, Height = 9999, Length = 6 },
			})) :: any
			expect(validated.WindupSeconds).to.equal(LIMITS.PhaseSeconds.Max)
			expect(validated.Cooldown).to.equal(LIMITS.CooldownSeconds.Min)
			expect(validated.Damage).to.equal(LIMITS.Damage.Max)
			expect(validated.Offset.Z).to.equal(LIMITS.OffsetStuds.Min)
			expect(validated.Dimensions.Width).to.equal(LIMITS.Dimensions.Width.Min)
			expect(validated.Dimensions.Height).to.equal(LIMITS.Dimensions.Height.Max)
		end)

		it("fills every dimension, and keeps an Arc's hub inside its rim", function()
			local validated = MoveRegistryManager.Validate(wire({
				Shape = "Arc",
				Dimensions = { Radius = 4, InnerRadius = 9, Height = 3, AngleDegrees = 120 },
			})) :: any
			expect(validated.Dimensions.InnerRadius).to.equal(4)
			expect(validated.Dimensions.Width).to.be.ok()
			expect(validated.Dimensions.Length).to.be.ok()
		end)

		it("builds Offset from the six flat numbers, rotation included", function()
			local validated = MoveRegistryManager.Validate(wire({ OffsetYaw = 90 })) :: any
			expect(validated.OffsetRotation.Y).to.equal(90)
			expect(validated.Offset.Position.Z).to.be.near(-3, 1e-6)
			-- Yawed a quarter turn, the volume's forward (-Z) now points along -X.
			expect(validated.Offset.LookVector.X).to.be.near(-1, 1e-6)
		end)

		it("defaults the anchor to Root and movement to unlocked", function()
			local validated = MoveRegistryManager.Validate(wire()) :: any
			expect(validated.AttachmentPart).to.equal("Root")
			expect(validated.LocksMovement).to.equal(false)
		end)

		it("normalises a bare animation id into rbxassetid form", function()
			local validated = MoveRegistryManager.Validate(wire({ AnimationId = "12345" })) :: any
			expect(validated.AnimationId).to.equal("rbxassetid://12345")
		end)

		it("rounds PowerLevel to a whole class and keeps Feintable only when literally true", function()
			local validated = MoveRegistryManager.Validate(wire({ PowerLevel = 2.6, Feintable = "yes" })) :: any
			expect(validated.PowerLevel).to.equal(3)
			expect(validated.Feintable).to.equal(nil)
		end)

		it("ignores an attach offset an old record still carries -- placement is the mode's, not a number", function()
			local validated = MoveRegistryManager.Validate(wire({
				Grab = {
					AttachOffset = CFrame.new(0, 100, 0),
					HoldSeconds = 2,
					ThrowUpVelocity = 20,
					ThrowHorizontalVelocity = 30,
					ThrowImpactDamage = 5,
					ThrowSelfDamage = 5,
				},
			})) :: any
			expect(validated.Grab.AttachOffset).to.equal(nil)
			expect(validated.Grab.Mode).to.equal(GrabConstants.DefaultMode)
		end)

		it("keeps a grab's mode, defaulting a record saved before modes existed", function()
			local function grabWith(fields: { [string]: any }): any
				local grab: { [string]: any } = {
					HoldSeconds = 2,
					ThrowUpVelocity = 20,
					ThrowHorizontalVelocity = 30,
					ThrowImpactDamage = 5,
					ThrowSelfDamage = 5,
				}
				for key, value in fields do
					grab[key] = value
				end
				return MoveRegistryManager.Validate(wire({ Grab = grab }))
			end

			local legacy = grabWith({})
			expect(legacy.Grab.Mode).to.equal(GrabConstants.DefaultMode)

			local drag = grabWith({ Mode = "Drag" })
			expect(drag.Grab.Mode).to.equal("Drag")
		end)

		it("refuses a grab mode that does not exist rather than holding some other way", function()
			local validated, reason = MoveRegistryManager.Validate(wire({
				Grab = {
					Mode = "Suplex",
					HoldSeconds = 2,
					ThrowUpVelocity = 20,
					ThrowHorizontalVelocity = 30,
					ThrowImpactDamage = 5,
					ThrowSelfDamage = 5,
				},
			}))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidGrab")
		end)

		it("normalises grab animation ids and treats an absent one as none", function()
			local validated = MoveRegistryManager.Validate(wire({
				Grab = {
					VictimAnimation = "12345",
					HoldSeconds = 2,
					ThrowUpVelocity = 20,
					ThrowHorizontalVelocity = 30,
					ThrowImpactDamage = 5,
					ThrowSelfDamage = 5,
				},
			})) :: any
			expect(validated.Grab.VictimAnimation).to.equal("rbxassetid://12345")
			expect(validated.Grab.AttackerAnimation).to.equal("")
		end)

		it("truncates free text rather than refusing it", function()
			local validated = MoveRegistryManager.Validate(wire({
				Description = string.rep("x", LIMITS.DescriptionLength + 50),
				Category = string.rep("c", LIMITS.CategoryLength + 5),
			})) :: any
			expect(#validated.Description).to.equal(LIMITS.DescriptionLength)
			expect(#validated.Category).to.equal(LIMITS.CategoryLength)
		end)

		it("ignores every retired field instead of rejecting a record that still carries one", function()
			local validated = MoveRegistryManager.Validate(wire({
				ArcDegrees = 90,
				Projectile = { Speed = 50, MaxRange = 50 },
				Animations = {},
			})) :: any
			expect(validated).to.be.ok()
			expect(validated.ArcDegrees).to.equal(nil)
			expect(validated.Projectile).to.equal(nil)
		end)
	end)

	describe("MoveRegistryManager registry", function()
		it("Upsert then Get round-trips, and Delete removes", function()
			MoveRegistryManager.Init()
			MoveRegistryManager.Upsert(MoveRegistryManager.Validate(wire()) :: any)
			expect(MoveRegistryManager.Get("spec-move")).to.be.ok()
			expect(#MoveRegistryManager.List()).to.equal(1)
			MoveRegistryManager.Delete("spec-move")
			expect(MoveRegistryManager.Get("spec-move")).to.equal(nil)
		end)

		it("hands out copies, never the live record", function()
			MoveRegistryManager.Init()
			MoveRegistryManager.Upsert(MoveRegistryManager.Validate(wire({
				Knockback = { UpVelocity = 5, HorizontalVelocity = 6 },
			})) :: any)
			local copy = MoveRegistryManager.Get("spec-move") :: any
			copy.Damage = 999
			copy.Dimensions.Width = 999
			copy.Knockback.UpVelocity = 999
			local fresh = MoveRegistryManager.Get("spec-move") :: any
			expect(fresh.Damage).to.equal(10)
			expect(fresh.Dimensions.Width).to.equal(4)
			expect(fresh.Knockback.UpVelocity).to.equal(5)
			MoveRegistryManager.Init()
		end)
	end)

	describe("MoveRegistryManager.GenerateMoveId", function()
		it("slugifies the display name and never collides", function()
			MoveRegistryManager.Init()
			local first = MoveRegistryManager.GenerateMoveId("Rising Palm!")
			expect(string.match(first, "^rising%-palm%-%d%d%d%d$")).to.be.ok()
			MoveRegistryManager.Upsert(MoveRegistryManager.Validate(wire({ MoveId = first })) :: any)
			for _ = 1, 20 do
				expect(MoveRegistryManager.GenerateMoveId("Rising Palm!") ~= first).to.equal(true)
			end
			MoveRegistryManager.Init()
		end)

		it("can never produce an id in the Default registry's space", function()
			local id = MoveRegistryManager.GenerateMoveId("default:Sword:Basic:1")
			expect(string.sub(id, 1, 8) ~= "default:").to.equal(true)
		end)

		it("falls back to a generic base for a name with no letters or digits", function()
			expect(string.match(MoveRegistryManager.GenerateMoveId("!!!"), "^move%-%d+$")).to.be.ok()
		end)
	end)
end
