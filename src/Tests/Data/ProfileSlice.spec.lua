--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileSlice = require(ServerScriptService.Server.Data.ProfileSlice)

local function slice(name: string, fields: { string }, overrides: { [string]: any }?): ProfileSlice.Slice
	local base: any = {
		Name = name,
		Fields = fields,
		Default = function()
			local out: { [string]: any } = {}
			for _, field in fields do
				out[field] = `{name}-default`
			end
			return out
		end,
		Copy = function(profile: any)
			local out: { [string]: any } = {}
			for _, field in fields do
				out[field] = profile[field]
			end
			return out
		end,
		Encode = function(profile: any)
			local out: { [string]: any } = {}
			for _, field in fields do
				out[field] = profile[field]
			end
			return out
		end,
		Decode = function(raw: any)
			local out: { [string]: any } = {}
			for _, field in fields do
				out[field] = raw[field]
			end
			return out
		end,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return ProfileSlice.Define(base)
end

return function()
	describe("ProfileSlice.Define", function()
		it("refuses a slice with no name, no fields or a missing function", function()
			expect(function()
				ProfileSlice.Define({ Name = "", Fields = { "a" } } :: any)
			end).to.throw()
			expect(function()
				ProfileSlice.Define({ Name = "x", Fields = {} } :: any)
			end).to.throw()
			expect(function()
				ProfileSlice.Define({ Name = "x", Fields = { "a" } } :: any)
			end).to.throw()
		end)
	end)

	describe("ProfileSlice.Compose", function()
		it("merges every slice's keys for each of the four operations", function()
			local composite = ProfileSlice.Compose({ slice("one", { "a", "b" }), slice("two", { "c" }) })
			local default = composite.Default(5)
			expect(default.a).to.equal("one-default")
			expect(default.b).to.equal("one-default")
			expect(default.c).to.equal("two-default")

			local profile = { a = 1, b = 2, c = 3, extra = 4 }
			expect(composite.Copy(profile).c).to.equal(3)
			expect(composite.Copy(profile).extra).to.equal(nil)
			expect(composite.Encode(profile).a).to.equal(1)
			expect(composite.Decode(profile, 5).b).to.equal(2)
			expect(composite.Decode(profile, 5).extra).to.equal(nil)
		end)

		it("refuses two slices that own the same key", function()
			expect(function()
				ProfileSlice.Compose({ slice("one", { "a" }), slice("two", { "a" }) })
			end).to.throw()
		end)

		it("fails loudly when a slice writes a key it does not own", function()
			local rogue = slice("rogue", { "a" }, {
				Encode = function()
					return { a = 1, stolen = 2 }
				end,
			})
			local composite = ProfileSlice.Compose({ rogue })
			expect(function()
				composite.Encode({})
			end).to.throw()
			expect(composite.Default(1).a).to.equal("rogue-default")
		end)

		it("exposes which slice owns each key", function()
			local composite = ProfileSlice.Compose({ slice("one", { "a" }), slice("two", { "c" }) })
			expect(composite.Fields.a).to.equal("one")
			expect(composite.Fields.c).to.equal("two")
			expect(composite.Fields.zzz).to.equal(nil)
		end)

		it("chains migration steps per version, in slice order, and leaves other versions empty", function()
			local trace: { string } = {}
			local function step(label: string)
				return function(record: any)
					table.insert(trace, label)
					return record
				end
			end
			local composite = ProfileSlice.Compose({
				slice("one", { "a" }, { Migrations = { [2] = step("one-2"), [4] = step("one-4") } }),
				slice("two", { "c" }, { Migrations = { [2] = step("two-2") } }),
			})
			expect(composite.Migrations[1]).to.equal(nil)
			expect(composite.Migrations[3]).to.equal(nil)
			local record = { SchemaVersion = 2 }
			expect(composite.Migrations[2](record)).to.equal(record)
			composite.Migrations[4](record)
			expect(table.concat(trace, ",")).to.equal("one-2,two-2,one-4")
		end)

		it("an empty list composes to nothing", function()
			local composite = ProfileSlice.Compose({})
			expect(next(composite.Default(1))).to.equal(nil)
			expect(next(composite.Migrations)).to.equal(nil)
		end)
	end)
end
