--!strict
-- The per-move Presentation block (Shared/Combat/MovePresentationTypes.lua) on the SERVER side: the gate
-- (strict on identity, lenient on numbers), every road a move travels -- Validate, ToWire, Clone,
-- Fingerprint, the DataStore codec, the source writer's file, the Default-move override layer, the
-- version-history summary -- and the catalogue that ships it to clients (MovePresentationSystem) with its
-- versioning rules. The client half (the precedence resolver) is Tests/FX/MovePresentation.spec.lua.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local MovePresentationSystem = require(ServerScriptService.Server.Combat.MovePresentationSystem)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local MoveEditorSystem = require(ServerScriptService.Server.Systems.MoveEditorSystem)
local MoveRecordCodec = require(ServerScriptService.Server.Systems.Support.MoveRecordCodec)
local MoveSourceWriter = require(ServerScriptService.Server.Systems.Support.MoveSourceWriter)
local PresentationAudit = require(ServerScriptService.Server.Systems.Support.PresentationAudit)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)
local Copy = require(StarterPlayer.StarterPlayerScripts.Client.UI.Screens.DevTools.MoveEditor.Copy)

local ROSTER = WeaponFixture.Install()
local FIXTURE_RECORD = require(ServerScriptService.Tests.Fixtures.PresentationRecord) :: { [string]: any }

local function candidate(presentation: any, overrides: { [string]: any }?): { [string]: any }
	local raw: { [string]: any } = {
		MoveId = "presented-move",
		DisplayName = "Presented",
		Author = "Spec",
		CreatedAt = 1,
		UpdatedAt = 2,
		Shape = "Box",
		Dimensions = { Width = 4, Height = 5, Length = 5 },
		OffsetX = 0,
		OffsetY = 0,
		OffsetZ = -3,
		WindupSeconds = 0.3,
		ActiveSeconds = 0.1,
		RecoverySeconds = 0.3,
		Cooldown = 1,
		Damage = 10,
		PostureDamage = 8,
		Presentation = presentation,
	}
	for key, value in overrides or {} do
		raw[key] = value
	end
	return raw
end

local function validMove(presentation: any, overrides: { [string]: any }?): MoveTypes.MoveDefinition
	local move, reason = MoveRegistryManager.Validate(candidate(presentation, overrides))
	if not move then
		error(`rejected: {tostring(reason)}`)
	end
	return move
end

local function deepEqual(a: any, b: any): boolean
	if typeof(a) ~= typeof(b) then
		return false
	end
	if typeof(a) ~= "table" then
		if typeof(a) == "number" then
			return math.abs(a - b) < 1e-9
		end
		return a == b
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local AUTHORED = {
	Active = { SoundId = "111", Pitch = 0.8, TrailColor = "none" },
	HitBlocked = { Volume = 1.5, Sparks = "Trade", SparkColor = "ff8800", HitStopSeconds = 0.05 },
	HitParried = { SoundId = "None", FlashColor = "#00aaff" },
}

return function()
	describe("MovePresentationTypes.Validate", function()
		it("reads absent as today's behaviour: no block, no error", function()
			local block, reason = MovePresentationTypes.Validate(nil)
			expect(block).to.equal(nil)
			expect(reason).to.equal(nil)
		end)

		it("normalises ids, colours and None, and keeps what was authored", function()
			local block = MovePresentationTypes.Validate(AUTHORED) :: MovePresentationTypes.Presentation
			expect(block.Active.SoundId).to.equal("rbxassetid://111")
			expect(block.Active.TrailColor).to.equal("None")
			expect(block.HitBlocked.SparkColor).to.equal("#FF8800")
			expect(block.HitParried.SoundId).to.equal("None")
			expect(block.HitParried.FlashColor).to.equal("#00AAFF")
			expect(block.HitBlocked.Sparks).to.equal("Trade")
		end)

		it("accepts the legacy asset URL through the shared normaliser", function()
			local block = MovePresentationTypes.Validate({
				HitClean = { SoundId = "https://www.roblox.com/asset/?id=4242" },
			}) :: MovePresentationTypes.Presentation
			expect(block.HitClean.SoundId).to.equal("rbxassetid://4242")
		end)

		it("rejects an unknown moment", function()
			local _, reason = MovePresentationTypes.Validate({ Hittt = { Volume = 1 } })
			expect(reason).to.equal("UnknownPresentationMoment")
		end)

		it("rejects an unknown preset", function()
			local _, reason = MovePresentationTypes.Validate({ HitClean = { Sparks = "Fireworks" } })
			expect(reason).to.equal("UnknownPresentationPreset")
			local _, shakeReason = MovePresentationTypes.Validate({ Windup = { Shake = "Earthquake" } })
			expect(shakeReason).to.equal("UnknownPresentationPreset")
		end)

		it("rejects a non-string id and a string that is not an id", function()
			local _, numeric = MovePresentationTypes.Validate({ HitClean = { SoundId = 123 } })
			expect(numeric).to.equal("InvalidPresentationAsset")
			local _, garbage = MovePresentationTypes.Validate({ HitClean = { SoundId = "my cool sound" } })
			expect(garbage).to.equal("InvalidPresentationAsset")
			-- None silences a sound; a texture has nothing to silence, so None is not an id there.
			local _, textureNone = MovePresentationTypes.Validate({ HitClean = { SparkTexture = "None" } })
			expect(textureNone).to.equal("InvalidPresentationAsset")
		end)

		it("rejects a malformed colour, a malformed template name and a cue that is not a table", function()
			local _, color = MovePresentationTypes.Validate({ HitClean = { SparkColor = "orange" } })
			expect(color).to.equal("InvalidPresentationColor")
			local _, template = MovePresentationTypes.Validate({ HitClean = { Template = "a/b" } })
			expect(template).to.equal("InvalidPresentationTemplate")
			local _, cue = MovePresentationTypes.Validate({ HitClean = "loud" })
			expect(cue).to.equal("InvalidPresentation")
			local _, notTable = MovePresentationTypes.Validate("loud")
			expect(notTable).to.equal("InvalidPresentation")
		end)

		it("clamps numbers rather than refusing them, and refuses a number that is not one", function()
			local block = MovePresentationTypes.Validate({
				HitClean = { Volume = 99, HitStopSeconds = -1 },
			}) :: MovePresentationTypes.Presentation
			expect(block.HitClean.Volume).to.equal(MovePresentationTypes.Limits.Volume.Max)
			expect(block.HitClean.HitStopSeconds).to.equal(0)
			local _, reason = MovePresentationTypes.Validate({ HitClean = { Volume = "loud" } })
			expect(reason).to.equal("InvalidPresentation")
		end)

		it("carries a signed SoundDelay on the moments that have a sound, clamped to its bounds", function()
			local limits = MovePresentationTypes.Limits.SoundDelay
			expect(limits.Min < 0 and limits.Max > 0).to.equal(true)
			local block = MovePresentationTypes.Validate({
				DomainActive = { SoundDelay = -0.4 },
				HitClean = { SoundDelay = 99 },
				Recovery = { SoundDelay = -99 },
			}) :: MovePresentationTypes.Presentation
			-- Negative is a lead and is kept as authored; out-of-range is clamped, not refused.
			expect(block.DomainActive.SoundDelay).to.be.near(-0.4, 1e-9)
			expect(block.HitClean.SoundDelay).to.equal(limits.Max)
			expect(block.Recovery.SoundDelay).to.equal(limits.Min)
			local _, reason = MovePresentationTypes.Validate({ DomainActive = { SoundDelay = "soon" } })
			expect(reason).to.equal("InvalidPresentation")
		end)

		it("carries Loop on the swing moments and the realm's long moments, and refuses an unknown value", function()
			for _, moment in { "Windup", "Active", "Recovery", "DomainOpen", "DomainActive", "DomainClose" } do
				expect(MovePresentationTypes.MomentHasField(moment, "Loop")).to.equal(true)
			end
			-- Instants and shots' own flight loop do not offer it.
			for _, moment in { "HitClean", "HitBlocked", "Launch", "InFlight", "Bounce", "DomainPulse" } do
				expect(MovePresentationTypes.MomentHasField(moment, "Loop")).to.equal(false)
			end
			local block = MovePresentationTypes.Validate({
				Active = { SoundId = "rbxassetid://9118823101", Loop = "RestOfMove" },
			}) :: MovePresentationTypes.Presentation
			expect(block.Active.Loop).to.equal("RestOfMove")
			local _, reason = MovePresentationTypes.Validate({ Active = { Loop = "Forever" } })
			expect(reason).to.equal("UnknownPresentationPreset")
			-- Blank is "play once", not an error.
			expect(MovePresentationTypes.Validate({ Active = { Loop = "" } })).to.equal(nil)
		end)

		it("carries FadeIn and FadeOut, clamped, on every one-shot sound and not on a looping flight", function()
			local limits = MovePresentationTypes.Limits.FadeIn
			expect(limits.Min).to.equal(0)
			local block = MovePresentationTypes.Validate({
				HitClean = { FadeIn = 0.3, FadeOut = 99 },
				DomainActive = { FadeOut = -1 },
			}) :: MovePresentationTypes.Presentation
			expect(block.HitClean.FadeIn).to.be.near(0.3, 1e-9)
			expect(block.HitClean.FadeOut).to.equal(MovePresentationTypes.Limits.FadeOut.Max)
			expect(block.DomainActive.FadeOut).to.equal(0)
			for _, moment in
				{ "Windup", "Active", "Recovery", "HitClean", "Launch", "DomainOpen", "DomainActive", "DomainClose" }
			do
				expect(MovePresentationTypes.MomentHasField(moment, "FadeIn")).to.equal(true)
				expect(MovePresentationTypes.MomentHasField(moment, "FadeOut")).to.equal(true)
			end
			expect(MovePresentationTypes.MomentHasField("InFlight", "FadeOut")).to.equal(false)
		end)

		it("offers SoundDelay everywhere a one-shot sound plays, and not on a shot's looping flight", function()
			for _, moment in
				{ "Windup", "Active", "Recovery", "HitClean", "Launch", "DomainOpen", "DomainActive", "DomainClose" }
			do
				expect(MovePresentationTypes.MomentHasField(moment, "SoundDelay")).to.equal(true)
			end
			expect(MovePresentationTypes.MomentHasField("InFlight", "SoundDelay")).to.equal(false)
		end)

		it("drops a field its moment does not read, then an emptied cue, then an emptied block", function()
			-- Audience is a projectile field; a swing is heard by its thrower alone.
			local block, reason = MovePresentationTypes.Validate({ Windup = { Audience = "Participants" } })
			expect(reason).to.equal(nil)
			expect(block).to.equal(nil)
			-- An evade touched nobody: no flash field.
			local evaded = MovePresentationTypes.Validate({
				HitEvaded = { FlashColor = "#FFFFFF", Volume = 0.5 },
			}) :: MovePresentationTypes.Presentation
			expect(evaded.HitEvaded.FlashColor).to.equal(nil)
			expect(evaded.HitEvaded.Volume).to.equal(0.5)
			-- Blank text is "unset", not an error.
			local blank = MovePresentationTypes.Validate({ HitClean = { SoundId = "", SparkColor = " " } })
			expect(blank).to.equal(nil)
		end)

		it("has prose for every reason code it can produce", function()
			for _, code in
				{
					"InvalidPresentation",
					"UnknownPresentationMoment",
					"UnknownPresentationPreset",
					"InvalidPresentationAsset",
					"InvalidPresentationColor",
					"InvalidPresentationTemplate",
				}
			do
				local failure = Copy.Failure(code)
				expect(failure.Message ~= code).to.equal(true)
				expect(failure.Tab).to.equal("Presentation")
			end
		end)

		it("offers only presets the effects actually have", function()
			for _, name in MovePresentationTypes.SparkPresets do
				expect(MovePresentationTypes.Field("Sparks")).to.be.ok()
				expect(name ~= MovePresentationTypes.None).to.equal(true)
			end
			expect(table.find(MovePresentationTypes.ShakePresets, "NoiseSeeds")).to.equal(nil)
			expect(table.find(MovePresentationTypes.ShakePresets, "Parry") ~= nil).to.equal(true)
		end)
	end)

	describe("a move's round trips", function()
		it("MoveRegistryManager.Validate carries the block and refuses a bad one with its code", function()
			local move = validMove(AUTHORED)
			expect((move.Presentation :: any).Active.SoundId).to.equal("rbxassetid://111")
			local _, reason = MoveRegistryManager.Validate(candidate({ Nope = {} }))
			expect(reason).to.equal("UnknownPresentationMoment")
		end)

		it("survives ToWire -> Validate, Clone and a second encode unchanged", function()
			local move = validMove(AUTHORED)
			local again = validMove(nil, MoveTypes.ToWire(move))
			expect(MoveTypes.Fingerprint(again)).to.equal(MoveTypes.Fingerprint(move))
			local clone = MoveTypes.Clone(move)
			expect(deepEqual(clone.Presentation, move.Presentation)).to.equal(true)
			-- A clone is a copy: editing it must not reach the original (the editor mutates its clone).
			local cloneActive = (clone.Presentation :: any).Active
			cloneActive.Pitch = 2
			expect((move.Presentation :: any).Active.Pitch).to.equal(0.8)
		end)

		it("survives the DataStore codec", function()
			local move = validMove(AUTHORED)
			local decoded = MoveRecordCodec.Decode(MoveRecordCodec.Encode(move))
			local loaded = validMove(nil, decoded :: any)
			expect(MoveTypes.Fingerprint(loaded)).to.equal(MoveTypes.Fingerprint(move))
		end)

		it("loads from a source-written file as the move that wrote it", function()
			-- The fixture is a record in MoveSourceWriter's layout (a "Write to source" file); reading it
			-- back must give a move whose own record IS that file's table.
			local decoded = MoveRecordCodec.Decode(FIXTURE_RECORD)
			local move = validMove(nil, decoded :: any)
			local record = MoveRecordCodec.Encode(move)
			expect(deepEqual(record, FIXTURE_RECORD)).to.equal(true)
			local text = MoveSourceWriter.ToLua(record)
			expect(MoveSourceWriter.ToLua(MoveRecordCodec.Encode(MoveTypes.Clone(move)))).to.equal(text)
			expect(string.find(text, 'SoundId = "rbxassetid://111"', 1, true) ~= nil).to.equal(true)
			expect(string.find(text, "Presentation = {", 1, true) ~= nil).to.equal(true)
		end)

		it("changes the fingerprint when presentation changes, and not when an emptied block goes away", function()
			local plain = validMove(nil)
			local presented = validMove(AUTHORED)
			expect(MoveTypes.Fingerprint(plain) ~= MoveTypes.Fingerprint(presented)).to.equal(true)
			local louder = validMove({
				Active = AUTHORED.Active,
				HitBlocked = { Volume = 1.6, Sparks = "Trade", SparkColor = "ff8800", HitStopSeconds = 0.05 },
				HitParried = AUTHORED.HitParried,
			})
			expect(MoveTypes.Fingerprint(louder) ~= MoveTypes.Fingerprint(presented)).to.equal(true)
			local emptied = validMove({ HitClean = {} })
			expect(emptied.Presentation).to.equal(nil)
			expect(MoveTypes.Fingerprint(emptied)).to.equal(MoveTypes.Fingerprint(plain))
		end)

		it("never reaches the engine projection", function()
			local definition = MoveTypes.ToEngineAttackDefinition(validMove(AUTHORED))
			expect((definition :: any).Presentation).to.equal(nil)
		end)

		it("names nested presentation fields in a version summary", function()
			local before = MoveTypes.ToWire(validMove(AUTHORED))
			local afterMove = validMove(AUTHORED)
			local blocked = (afterMove.Presentation :: any).HitBlocked
			blocked.Volume = 2
			local summary = MoveEditorSystem.SummarizeChange(before, MoveTypes.ToWire(afterMove))
			expect(summary).to.equal("Presentation.HitBlocked.Volume 1.50->2")
		end)
	end)

	describe("a Default move's override", function()
		local moveId = `default:{ROSTER[1]}:Basic:1`

		afterEach(function()
			DefaultMoveRegistry.Reset(moveId)
		end)

		it("may carry presentation, and Reset takes it away", function()
			local wire = MoveTypes.ToWire(DefaultMoveRegistry.Get(moveId) :: MoveTypes.MoveDefinition)
			wire.Presentation = AUTHORED
			local applied = DefaultMoveRegistry.ApplyEdit(moveId, wire) :: MoveTypes.MoveDefinition
			expect((applied.Presentation :: any).HitParried.SoundId).to.equal("None")
			expect(((DefaultMoveRegistry.Get(moveId) :: any).Presentation :: any).Active.Pitch).to.equal(0.8)
			local reset = DefaultMoveRegistry.Reset(moveId) :: MoveTypes.MoveDefinition
			expect(reset.Presentation).to.equal(nil)
		end)

		it("reads an override record's missing block as none, not as the built move's", function()
			local built = DefaultMoveRegistry.GetBuilt(moveId) :: MoveTypes.MoveDefinition
			local shippedLike = MoveTypes.Clone(built)
			shippedLike.Presentation = MovePresentationTypes.Validate(AUTHORED)
			local record = MoveRecordCodec.EncodeOverride(built)
			local decoded = MoveRecordCodec.DecodeOverride(shippedLike, record) :: { [string]: any }
			expect(decoded.Presentation).to.equal(nil)
		end)
	end)

	describe("MovePresentationSystem's catalogue", function()
		beforeEach(function()
			MoveRegistryManager.Init()
			MovePresentationSystem.ResetForTesting()
			MovePresentationSystem.RebuildForTesting()
		end)

		afterEach(function()
			MovePresentationSystem.ResetForTesting()
			MoveRegistryManager.Init()
		end)

		it("sends a versioned delta for a changed block and nothing for an unrelated edit", function()
			local move = validMove(AUTHORED)
			MoveRegistryManager.Upsert(move)
			MovePresentationSystem.MarkChangedForTesting(move.MoveId)
			local delta = MovePresentationSystem.CollectDeltaForTesting() :: MovePresentationTypes.CatalogMessage
			expect(delta.Kind).to.equal("Delta")
			expect(delta.Base).to.equal(0)
			expect(delta.Version).to.equal(1)
			expect(delta.Entries[move.MoveId]).to.be.ok()

			-- Damage is not presentation: nothing reaches a client.
			local harder = validMove(AUTHORED, { Damage = 30 })
			MoveRegistryManager.Upsert(harder)
			MovePresentationSystem.MarkChangedForTesting(harder.MoveId)
			expect(MovePresentationSystem.CollectDeltaForTesting()).to.equal(nil)
			expect(MovePresentationSystem.Snapshot().Version).to.equal(1)
		end)

		it("sends a removal when the move goes, and snapshots only moves with a block", function()
			local move = validMove(AUTHORED)
			MoveRegistryManager.Upsert(move)
			MoveRegistryManager.Upsert(validMove(nil, { MoveId = "plain-move" }))
			MovePresentationSystem.MarkChangedForTesting(move.MoveId)
			MovePresentationSystem.MarkChangedForTesting("plain-move")
			MovePresentationSystem.CollectDeltaForTesting()
			local snapshot = MovePresentationSystem.Snapshot()
			expect(snapshot.Entries[move.MoveId]).to.be.ok()
			expect(snapshot.Entries["plain-move"]).to.equal(nil)

			MoveRegistryManager.Delete(move.MoveId)
			MovePresentationSystem.MarkChangedForTesting(move.MoveId)
			local delta = MovePresentationSystem.CollectDeltaForTesting() :: MovePresentationTypes.CatalogMessage
			expect(table.find(delta.Removes :: { string }, move.MoveId) ~= nil).to.equal(true)
			expect(MovePresentationSystem.Snapshot().Entries[move.MoveId]).to.equal(nil)
		end)
	end)

	describe("MovePresentationTypes.ApplyCatalogMessage", function()
		local block = MovePresentationTypes.Validate(AUTHORED) :: MovePresentationTypes.Presentation

		it("applies a snapshot, then a delta built on it", function()
			local state = { Version = 0, Entries = {} }
			local result = MovePresentationTypes.ApplyCatalogMessage(state, {
				Kind = "Snapshot",
				Version = 3,
				Entries = { a = block },
			})
			expect(result).to.equal("Applied")
			local deltaResult, changed = MovePresentationTypes.ApplyCatalogMessage(state, {
				Kind = "Delta",
				Base = 3,
				Version = 4,
				Entries = { b = block },
				Removes = { "a" },
			})
			expect(deltaResult).to.equal("Applied")
			expect(state.Version).to.equal(4)
			expect(state.Entries.a).to.equal(nil)
			expect(state.Entries.b).to.be.ok()
			expect(#changed).to.equal(2)
		end)

		it("calls a gap stale and ignores what it already covers", function()
			local state = { Version = 4, Entries = {} }
			expect(MovePresentationTypes.ApplyCatalogMessage(state, {
				Kind = "Delta",
				Base = 5,
				Version = 6,
				Entries = {},
			})).to.equal("Stale")
			expect(MovePresentationTypes.ApplyCatalogMessage(state, {
				Kind = "Delta",
				Base = 3,
				Version = 4,
				Entries = {},
			})).to.equal("Ignored")
			expect(MovePresentationTypes.ApplyCatalogMessage(state, {
				Kind = "Snapshot",
				Version = 2,
				Entries = {},
			})).to.equal("Ignored")
			expect(state.Version).to.equal(4)
		end)
	end)

	describe("PresentationAudit.Describe", function()
		local function allOk(): (PresentationAudit.AssetStatus, string?)
			return "Ok", nil
		end

		it("says nothing about a clean block", function()
			local notes = PresentationAudit.Describe(validMove(AUTHORED), allOk, function()
				return true
			end)
			expect(#notes).to.equal(0)
		end)

		it("flags a missing asset, a wrong-kind asset and a missing template, naming the moment", function()
			local move = validMove({
				HitClean = { SoundId = "1", SparkTexture = "2", Template = "Nope" },
			})
			local notes = PresentationAudit.Describe(move, function(assetId, _kind)
				if assetId == "rbxassetid://1" then
					return "Missing", nil
				end
				return "WrongType", "a Decal"
			end, function()
				return false
			end)
			expect(#notes).to.equal(3)
			for _, note in notes do
				expect(string.find(note, "Hit: clean", 1, true) ~= nil).to.equal(true)
			end
		end)

		it("flags a projectile cue on a melee move", function()
			local notes = PresentationAudit.Describe(validMove({ Launch = { Volume = 0.5 } }), allOk, function()
				return true
			end)
			expect(#notes).to.equal(1)
			expect(string.find(notes[1], "Launch", 1, true) ~= nil).to.equal(true)
		end)
	end)
end
