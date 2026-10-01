--!strict
-- Covers Server/Systems/Support/MoveSourceWriter.lua -- a stored move record as the text of a ModuleScript.

local ServerScriptService = game:GetService("ServerScriptService")

local MoveSourceWriter = require(ServerScriptService.Server.Systems.Support.MoveSourceWriter)

local RECORD = {
	SchemaVersion = 3,
	MoveId = "rising-palm-4821",
	DisplayName = "Rising Palm",
	Damage = 12,
	WindupSeconds = 0.26,
	Dimensions = { Width = 4, Height = 5.5, Length = 6 },
	Art = { TreeId = "common_foundation", Node = 1 },
	LocksMovement = false,
}

return function()
	describe("MoveSourceWriter.ToLua", function()
		it("is deterministic: the same record writes byte-identical text", function()
			local copy = table.clone(RECORD)
			copy.Dimensions = { Length = 6, Width = 4, Height = 5.5 }
			expect(MoveSourceWriter.ToLua(RECORD)).to.equal(MoveSourceWriter.ToLua(copy))
		end)

		it("sorts keys at every level and closes with trailing commas", function()
			local text = MoveSourceWriter.ToLua(RECORD)
			local art = string.find(text, "\tArt = {", 1, true) :: number
			local damage = string.find(text, "\tDamage = 12,", 1, true) :: number
			local windup = string.find(text, "\tWindupSeconds = 0.26,", 1, true) :: number
			expect(art < damage and damage < windup).to.equal(true)
			local height = string.find(text, "\t\tHeight = 5.5,", 1, true) :: number
			local width = string.find(text, "\t\tWidth = 4,", 1, true) :: number
			expect(height < width).to.equal(true)
			expect(string.find(text, "\n\t},\n", 1, true) ~= nil).to.equal(true)
		end)

		it("is a module that returns the record", function()
			local text = MoveSourceWriter.ToLua(RECORD)
			expect(string.sub(text, 1, 10)).to.equal("--!strict\n")
			expect(string.find(text, "\nreturn {\n", 1, true) ~= nil).to.equal(true)
			expect(string.sub(text, -3)).to.equal("\n}\n")
		end)

		it("writes arrays in index order", function()
			local text = MoveSourceWriter.ToLua({ List = { "c", "a", "b" } })
			expect(string.find(text, '"c",\n\t\t"a",\n\t\t"b",', 1, true) ~= nil).to.equal(true)
		end)
	end)

	describe("MoveSourceWriter formatting", function()
		it("writes integers without a decimal and floats at six significant figures", function()
			expect(MoveSourceWriter.FormatNumber(12)).to.equal("12")
			expect(MoveSourceWriter.FormatNumber(-3)).to.equal("-3")
			expect(MoveSourceWriter.FormatNumber(0.26)).to.equal("0.26")
			expect(MoveSourceWriter.FormatNumber(1 / 3)).to.equal("0.333333")
			expect(MoveSourceWriter.FormatNumber(0 / 0)).to.equal("0 / 0")
		end)

		it("escapes quotes, backslashes, newlines and control characters on one line", function()
			expect(MoveSourceWriter.QuoteString('say "hi"')).to.equal('"say \\"hi\\""')
			expect(MoveSourceWriter.QuoteString("a\\b")).to.equal('"a\\\\b"')
			expect(MoveSourceWriter.QuoteString("line1\nline2")).to.equal('"line1\\nline2"')
			expect(MoveSourceWriter.QuoteString("bell\7")).to.equal('"bell\\007"')
			-- A long-bracket closer is inert inside a quoted string.
			expect(MoveSourceWriter.QuoteString("]]")).to.equal('"]]"')
		end)

		it("brackets a key that is not a plain identifier", function()
			local text = MoveSourceWriter.ToLua({ ["odd key"] = 1, ["end"] = 2 })
			expect(string.find(text, '["odd key"] = 1,', 1, true) ~= nil).to.equal(true)
			expect(string.find(text, '["end"] = 2,', 1, true) ~= nil).to.equal(true)
		end)
	end)

	describe("MoveSourceWriter.FileName", function()
		it("replaces everything outside [A-Za-z0-9-] with an underscore", function()
			expect(MoveSourceWriter.FileName("default:Sword:Basic:1")).to.equal("default_Sword_Basic_1.lua")
			expect(MoveSourceWriter.FileName("rising-palm-4821")).to.equal("rising-palm-4821.lua")
			expect(MoveSourceWriter.FileName("../evil")).to.equal("___evil.lua")
		end)
	end)
end
