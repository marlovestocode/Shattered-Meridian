--!strict
-- MoveRecordCodec, old against new. Tests/Fixtures/MoveRecordCodecLegacy.lua is the codec exactly as it stood before it
-- was converted to Shared/Schema (2026-10-25, W4); the real one is the converted code. Both run over one corpus --
-- a valid current record, v1 and v2 records of every legacy shape, and every single-field corruption of each (nil, NaN,
-- +-inf, the wrong type, an oversize string, an empty table) -- and must return identical candidates and identical
-- dropped-field lists from Decode and DecodeOverride. The frozen copy is deleted when this spec is.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local MoveRecordCodec = require(ServerScriptService.Server.Systems.Support.MoveRecordCodec)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Legacy = require(ServerScriptService.Tests.Fixtures.MoveRecordCodecLegacy)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

local NAN = 0 / 0
local INF = math.huge

WeaponFixture.Install()

-- NaN-aware structural equality (NaN ~= NaN is exactly what a corrupted field produces).
local function same(a: any, b: any): boolean
	if a == b then
		return true
	end
	if typeof(a) == "number" and typeof(b) == "number" then
		return a ~= a and b ~= b
	end
	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not same(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil and b[key] ~= nil then
			return false
		end
	end
	return true
end

local HOSTILE: { any } = {
	NAN,
	INF,
	-INF,
	-1,
	0,
	"",
	"Box",
	string.rep("z", 3000),
	true,
	false,
	{},
	{ 1, 2, 3 },
	{ X = 1, Y = 2, Z = 3 },
	Vector3.new(1, 2, 3),
}

local function validMove(fields: { [string]: any }): MoveTypes.MoveDefinition
	local move, reason = MoveRegistryManager.Validate(fields)
	assert(move, `spec move rejected: {tostring(reason)}`)
	return move :: MoveTypes.MoveDefinition
end

local function legacyRecord(version: number, fields: { [string]: any }): { [string]: any }
	local record: { [string]: any } = {
		SchemaVersion = version,
		MoveId = "legacy-move",
		DisplayName = "Legacy",
		Description = "",
		Category = "",
		Author = "OldAdmin",
		CreatedAt = 10,
		UpdatedAt = 20,
		OffsetX = 0,
		OffsetY = 0,
		OffsetZ = -3,
		OffsetRotationX = 5,
		OffsetRotationY = 10,
		OffsetRotationZ = 15,
		WindupSeconds = 0.3,
		ActiveSeconds = 0.2,
		RecoverySeconds = 0.3,
		Cooldown = 0.8,
		Damage = 12,
		PostureDamage = 9,
		AnimationId = "",
	}
	for key, value in fields do
		record[key] = value
	end
	return record
end

local function corpus(): { { [string]: any } }
	local records: { { [string]: any } } = {}

	-- A current (v3) record, exactly as a save produces it.
	local move = validMove({
		MoveId = "saved-move",
		DisplayName = "Saved",
		Author = "Spec",
		CreatedAt = 1,
		UpdatedAt = 2,
		Shape = "Capsule",
		Dimensions = { Radius = 1.5, Length = 4 },
		OffsetX = 0.5,
		OffsetY = 0,
		OffsetZ = -2,
		OffsetYaw = 20,
		AttachmentPart = "RightHand",
		WindupSeconds = 0.25,
		ActiveSeconds = 0.1,
		RecoverySeconds = 0.3,
		Cooldown = 2,
		Damage = 14,
		PostureDamage = 10,
		Knockback = { UpVelocity = 5, HorizontalVelocity = 30, StartsAirCombo = true },
	})
	table.insert(records, Legacy.Encode(move))

	-- v1: Size/Radius, no Dimensions.
	table.insert(records, legacyRecord(1, { Shape = "Box", Size = { X = 4, Y = 5, Z = 6 }, Radius = 2 }))
	table.insert(records, legacyRecord(1, { Shape = "Sphere", Size = Vector3.new(3, 3, 3), Radius = 3 }))
	table.insert(records, legacyRecord(1, {}))

	-- v2: every legacy shape, with the dimensions each reads.
	local dimensions = {
		Width = 4,
		Height = 5,
		Depth = 6,
		Length = 7,
		Thickness = 8,
		Radius = 2,
		InnerRadius = 1,
		AngleDegrees = 90,
	}
	for _, shape in
		{
			"Box",
			"Sphere",
			"Cone",
			"Arc",
			"Beam",
			"Cylinder",
			"Capsule",
			"Disc",
			"Wedge",
			"Blade",
			"Slice",
			"Pyramid",
			"Teapot",
		}
	do
		table.insert(records, legacyRecord(2, { Shape = shape, Dimensions = table.clone(dimensions) }))
	end

	-- v2 with a timeline, retired blocks and a ragdoll knockback.
	table.insert(
		records,
		legacyRecord(2, {
			Shape = "Box",
			Dimensions = table.clone(dimensions),
			AnimationId = "",
			Animations = {
				{ AnimationId = "", Enabled = true },
				{ AnimationId = "rbxassetid://spec-clip", Enabled = true },
				{ AnimationId = "rbxassetid://spec-clip-2", Enabled = false },
			},
			Movement = { Distance = 5 },
			Projectile = { Speed = 10 },
			ObjectStun = {},
			Slam = {},
			ArcDegrees = 45,
			Knockback = { UpVelocity = 3, HorizontalVelocity = 20, RagdollSeconds = 1.5, StartsAirCombo = true },
			PowerLevel = 2,
			Feintable = true,
			Grab = { Duration = 1 },
			Art = { TreeId = "x", Node = 1 },
		})
	)
	return records
end

-- Every single-field corruption of every record, at the top level and one level into the nested tables.
local function corruptions(records: { { [string]: any } }): { any }
	local out: { any } = {}
	for _, record in records do
		table.insert(out, record)
		for key, original in record do
			for _, bad in HOSTILE do
				local mutated = table.clone(record)
				mutated[key] = bad
				table.insert(out, mutated)
			end
			local gone = table.clone(record)
			gone[key] = nil
			table.insert(out, gone)
			if typeof(original) == "table" and getmetatable(original) == nil then
				for subKey in original do
					for _, bad in HOSTILE do
						local mutated = table.clone(record)
						local inner = table.clone(original)
						inner[subKey] = bad
						mutated[key] = inner
						table.insert(out, mutated)
					end
				end
			end
		end
	end
	for _, bad in HOSTILE do
		table.insert(out, bad)
	end
	return out
end

return function()
	local cases = corruptions(corpus())

	describe("MoveRecordCodec.Decode, old against new", function()
		it("agrees on the valid records and every single-field corruption", function()
			expect(#cases > 1000).to.equal(true)
			for index, case in cases do
				local oldCandidate, oldDropped = Legacy.Decode(case)
				local newCandidate, newDropped = MoveRecordCodec.Decode(case)
				if not (same(oldCandidate, newCandidate) and same(oldDropped, newDropped)) then
					error(`Decode disagrees on corpus case {index}`)
				end
			end
		end)

		it("agrees on nil", function()
			local oldCandidate, oldDropped = Legacy.Decode(nil)
			local newCandidate, newDropped = MoveRecordCodec.Decode(nil)
			expect(newCandidate).to.equal(oldCandidate)
			expect(#newDropped).to.equal(#oldDropped)
		end)
	end)

	describe("MoveRecordCodec.DecodeOverride, old against new", function()
		it("agrees on the valid records and every single-field corruption", function()
			local built = validMove({
				MoveId = "built-move",
				DisplayName = "Built",
				Author = "Spec",
				CreatedAt = 1,
				UpdatedAt = 2,
				Shape = "Box",
				Dimensions = { Width = 3, Height = 3, Length = 3 },
				OffsetX = 0,
				OffsetY = 0,
				OffsetZ = -2,
				WindupSeconds = 0.2,
				ActiveSeconds = 0.1,
				RecoverySeconds = 0.2,
				Cooldown = 1,
				Damage = 8,
				PostureDamage = 5,
			})
			for index, case in cases do
				local oldCandidate, oldDropped = Legacy.DecodeOverride(built, case)
				local newCandidate, newDropped = MoveRecordCodec.DecodeOverride(built, case)
				if not (same(oldCandidate, newCandidate) and same(oldDropped, newDropped)) then
					error(`DecodeOverride disagrees on corpus case {index}`)
				end
			end
		end)
	end)

	describe("MoveRecordCodec.Encode, old against new", function()
		it("writes the same record", function()
			local move = validMove({
				MoveId = "enc-move",
				DisplayName = "Enc",
				Author = "Spec",
				CreatedAt = 1,
				UpdatedAt = 2,
				Shape = "Box",
				Dimensions = { Width = 3, Height = 3, Length = 3 },
				OffsetX = 0,
				OffsetY = 0,
				OffsetZ = -2,
				WindupSeconds = 0.2,
				ActiveSeconds = 0.1,
				RecoverySeconds = 0.2,
				Cooldown = 1,
				Damage = 8,
				PostureDamage = 5,
			})
			expect(same(Legacy.Encode(move), MoveRecordCodec.Encode(move))).to.equal(true)
			expect(same(Legacy.EncodeOverride(move), MoveRecordCodec.EncodeOverride(move))).to.equal(true)
		end)
	end)
end
