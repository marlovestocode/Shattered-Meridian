--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Schema = require(ReplicatedStorage.Shared.Schema)

local NAN = 0 / 0
local INF = math.huge

-- The hostile values every combinator is asked about.
local function decode(shape: any, raw: unknown): (any, string?)
	return Schema.Decode(shape, raw)
end

return function()
	describe("Schema.Boolean", function()
		it("accepts booleans and refuses everything else", function()
			expect(decode(Schema.Boolean, true)).to.equal(true)
			expect(decode(Schema.Boolean, false)).to.equal(false)
			for _, bad in { "true", 1, 0, NAN, {}, Vector3.zero } do
				local value, reason = decode(Schema.Boolean, bad)
				expect(value).to.equal(nil)
				expect(reason).to.equal("expected boolean")
			end
			local value, reason = decode(Schema.Boolean, nil)
			expect(value).to.equal(nil)
			expect(reason).to.equal("expected boolean")
		end)
	end)

	describe("Schema.Number", function()
		local shape = Schema.Number(1, 10)

		it("passes an in-range number through and clamps an out-of-range one", function()
			expect(decode(shape, 5)).to.equal(5)
			expect(decode(shape, -100)).to.equal(1)
			expect(decode(shape, 100)).to.equal(10)
		end)

		it("clamps +-inf rather than refusing it, as Sanitize.ClampNumber does", function()
			expect(decode(shape, INF)).to.equal(10)
			expect(decode(shape, -INF)).to.equal(1)
		end)

		it("refuses NaN, a string, a table and nil", function()
			for _, bad in { NAN, "5", {}, true } do
				local value, reason = decode(shape, bad)
				expect(value).to.equal(nil)
				expect(reason).to.equal("expected a real number")
			end
			expect(select(2, decode(shape, nil))).to.equal("expected a real number")
		end)
	end)

	describe("Schema.String and NonEmptyString", function()
		it("truncates an oversize string and refuses a non-string", function()
			expect(decode(Schema.String(4), "abcdefgh")).to.equal("abcd")
			expect(decode(Schema.String(4), "ab")).to.equal("ab")
			expect(decode(Schema.String(4), "")).to.equal("")
			expect(select(2, decode(Schema.String(4), 5))).to.equal("expected string")
			expect(select(2, decode(Schema.String(4), nil))).to.equal("expected string")
		end)

		it("survives a very long string", function()
			local long = string.rep("x", 100000)
			expect(#decode(Schema.String(64), long)).to.equal(64)
		end)

		it("NonEmptyString refuses the empty string and bounds a long one", function()
			expect(select(2, decode(Schema.NonEmptyString(4), ""))).to.equal("expected non-empty string")
			expect(select(2, decode(Schema.NonEmptyString(), 7))).to.equal("expected non-empty string")
			expect(decode(Schema.NonEmptyString(4), "abcdefgh")).to.equal("abcd")
			expect(decode(Schema.NonEmptyString(), "abcdefgh")).to.equal("abcdefgh")
		end)
	end)

	describe("Schema.Enum and EnumItem", function()
		it("accepts only the named strings", function()
			local shape = Schema.Enum({ "Hold", "Toggle" })
			expect(decode(shape, "Hold")).to.equal("Hold")
			local value, reason = decode(shape, "hold")
			expect(value).to.equal(nil)
			expect(reason).to.equal("expected one of Hold, Toggle")
			expect(select(2, decode(shape, 1))).to.equal("expected one of Hold, Toggle")
		end)

		it("accepts only an item of the named Enum", function()
			local shape = Schema.EnumItem(Enum.KeyCode)
			expect(decode(shape, Enum.KeyCode.E)).to.equal(Enum.KeyCode.E)
			expect(decode(shape, Enum.UserInputType.MouseButton1)).to.equal(nil)
			expect(select(2, decode(shape, Enum.UserInputType.MouseButton1))).to.be.ok()
			expect(select(2, decode(shape, "E"))).to.be.ok()
		end)
	end)

	describe("Schema.Optional and Default", function()
		it("Optional lets nil through and judges anything else", function()
			local shape = Schema.Optional(Schema.Boolean)
			local value, reason = decode(shape, nil)
			expect(value).to.equal(nil)
			expect(reason).to.equal(nil)
			expect(decode(shape, true)).to.equal(true)
			expect(select(2, decode(shape, "x"))).to.equal("expected boolean")
		end)

		it("Default falls back on nil AND on a wrong type", function()
			local shape = Schema.Default(Schema.Number(0, 1), 0.5)
			expect(decode(shape, nil)).to.equal(0.5)
			expect(decode(shape, "x")).to.equal(0.5)
			expect(decode(shape, NAN)).to.equal(0.5)
			expect(decode(shape, 0.25)).to.equal(0.25)
			expect(decode(shape, 9)).to.equal(1)
		end)
	end)

	describe("Schema.Array", function()
		local shape = Schema.Array(Schema.Number(0, 10), 3)

		it("decodes each element, clamping as the element shape does", function()
			local value = decode(shape, { 1, 50, 3 })
			expect(#value).to.equal(3)
			expect(value[2]).to.equal(10)
		end)

		it("names the failing index, and refuses an oversize array", function()
			expect(select(2, decode(shape, { 1, "x" }))).to.equal("2.expected a real number")
			expect(select(2, decode(shape, { 1, 2, 3, 4 }))).to.equal("more than 3 entries")
			expect(select(2, decode(shape, "x"))).to.equal("expected array")
		end)

		it("refuses a table that carries a metatable", function()
			expect(select(2, decode(shape, setmetatable({ 1 }, {})))).to.equal("expected array")
		end)

		it("ends at the first hole, as ipairs does", function()
			local value = decode(Schema.Array(Schema.Number(0, 10)), { 1, 2, nil, 4 })
			expect(#value).to.equal(2)
		end)
	end)

	describe("Schema.Map", function()
		local shape = Schema.Map(Schema.Enum({ "A", "B" }), Schema.Boolean, 2)

		it("decodes keys and values", function()
			local value = decode(shape, { A = true, B = false })
			expect(value.A).to.equal(true)
			expect(value.B).to.equal(false)
		end)

		it("refuses a wrong key, a wrong value and an oversize map", function()
			expect(select(2, decode(shape, { C = true }))).to.equal("C.expected one of A, B")
			expect(select(2, decode(shape, { A = "x" }))).to.equal("A.expected boolean")
			expect(select(2, decode(Schema.Map(Schema.String(8), Schema.Boolean, 1), { a = true, b = true }))).to.equal(
				"more than 1 entries"
			)
			expect(select(2, decode(shape, 5))).to.equal("expected map")
			expect(select(2, decode(shape, setmetatable({}, {})))).to.equal("expected map")
		end)
	end)

	describe("Schema.Record", function()
		local shape = Schema.Record({
			{ "Id", Schema.NonEmptyString(8) },
			{ "Level", Schema.Number(1, 5) },
			{ "Note", Schema.Optional(Schema.String(4)) },
		})

		it("decodes the named fields, drops the rest, and leaves an absent optional out", function()
			local value = decode(shape, { Id = "abc", Level = 9, Extra = "ignored" })
			expect(value.Id).to.equal("abc")
			expect(value.Level).to.equal(5)
			expect(value.Extra).to.equal(nil)
			expect(value.Note).to.equal(nil)
		end)

		it("names the first failing field, in declared order", function()
			expect(select(2, decode(shape, { Id = "", Level = "x" }))).to.equal("Id.expected non-empty string")
			expect(select(2, decode(shape, { Id = "a", Level = NAN }))).to.equal("Level.expected a real number")
			expect(select(2, decode(shape, { Id = "a", Level = 1, Note = 5 }))).to.equal("Note.expected string")
			expect(select(2, decode(shape, nil))).to.equal("expected table")
			expect(select(2, decode(shape, setmetatable({ Id = "a", Level = 1 }, {})))).to.equal("expected table")
		end)

		it("prefixes the path through nested records", function()
			local nested = Schema.Record({ { "Inner", shape } })
			expect(select(2, decode(nested, { Inner = { Id = "a", Level = "x" } }))).to.equal(
				"Inner.Level.expected a real number"
			)
		end)
	end)

	describe("Schema.WithReason", function()
		it("replaces the path with a fixed code, and a parent does not prefix it", function()
			local shape = Schema.Record({
				{ "Kind", Schema.WithReason("InvalidKind", Schema.Enum({ "A" })) },
			})
			expect(select(2, decode(shape, { Kind = "B" }))).to.equal("InvalidKind")
			expect(decode(shape, { Kind = "A" }).Kind).to.equal("A")
		end)
	end)

	describe("Schema.FieldValue", function()
		local write = Schema.FieldValue({ On = Schema.Boolean, Level = Schema.Number(0, 3) })

		it("returns the field and its decoded value", function()
			local field, value, reason = write("Level", 9)
			expect(field).to.equal("Level")
			expect(value).to.equal(3)
			expect(reason).to.equal(nil)
		end)

		it("refuses a non-string field, an unknown field and a bad value", function()
			expect(select(3, write(5, true))).to.equal("non-string field")
			expect(select(3, write("Nope", true))).to.equal("unknown field Nope")
			expect(select(3, write("On", "yes"))).to.equal("On: expected boolean")
			expect(select(3, write("Level", NAN))).to.equal("Level: expected a real number")
			local field, value = write("On", nil)
			expect(field).to.equal(nil)
			expect(value).to.equal(nil)
		end)

		it("does not reach for a key inherited from the shape table", function()
			expect(select(3, write("__index", true))).to.equal("unknown field __index")
		end)
	end)

	describe("Schema.Custom and the lenient reads", function()
		it("Custom is the shape as written", function()
			local shape = Schema.Custom(function(raw: unknown)
				if raw == 7 then
					return "seven", nil
				end
				return nil, "not seven"
			end)
			expect(decode(shape, 7)).to.equal("seven")
			expect(select(2, decode(shape, 8))).to.equal("not seven")
		end)

		it("IsX are plain type tests", function()
			expect(Schema.IsTable({})).to.equal(true)
			expect(Schema.IsTable("x")).to.equal(false)
			expect(Schema.IsString("x")).to.equal(true)
			expect(Schema.IsString(1)).to.equal(false)
			expect(Schema.IsNumber(NAN)).to.equal(true)
			expect(Schema.IsNumber("1")).to.equal(false)
			expect(Schema.IsBoolean(false)).to.equal(true)
			expect(Schema.IsBoolean(nil)).to.equal(false)
		end)

		it("NumberOr and StringOr tolerate rather than validate", function()
			expect(Schema.NumberOr(3, 0)).to.equal(3)
			expect(Schema.NumberOr("3", 9)).to.equal(9)
			expect(Schema.NumberOr(nil, 9)).to.equal(9)
			expect(Schema.StringOr("a", "z")).to.equal("a")
			expect(Schema.StringOr(1, "z")).to.equal("z")
		end)
	end)
end
