--!strict
--[[
	DebugKeys.lua

	Owns: the RAW developer keys -- the function-row toggles that are deliberately not KeybindActions, so they never appear in the
	player-facing rebind list -- and the one check that none of them collides with another or with a keyboard default.

	WHY (coworking plan W13). Each dev tool declared its raw key in its own Constants table (FpsCounter and Storybook in
	DebugConstants, the parkour overlay in ParkourConstants) and checked for collisions BY HAND, in a comment: "checked against both
	tables at the time of writing". That is how F5 (the Live Console) and F6 (the parkour overlay) once fired on one press. The keys
	now live here, the old fields read from this table, and `Clashes()` -- asserted by Tests/Input/DebugKeys.spec.lua -- is the check.

	F5 (OpenDevConsole) and F8 (OpenBugReport) are NOT here: they are ordinary KeybindActions in KeybindConstants.Defaults, rebindable,
	and Clashes() checks the raw keys against them. Gamepad chords cannot collide with a keyboard key and are not compared.

	NOT F9: Roblox binds it to its own developer console at the engine level (the parkour overlay's first key lost to it). Listed in
	ENGINE_RESERVED so Clashes() refuses it.
]]

local KeybindConstants = require(script.Parent.KeybindConstants)

local DebugKeys = {
	-- Client/Diagnostics/FpsCounter.lua. Not gated: it reads only the local frame clock.
	FpsCounter = Enum.KeyCode.F3,
	-- Client/Parkour/ParkourDebug.lua, the read-only probe overlay.
	ParkourDebug = Enum.KeyCode.F6,
	-- Client/DevTools/Storybook/StorybookClient.lua, the component storybook (Studio/admin tooling).
	Storybook = Enum.KeyCode.F7,
}

-- Keys the engine itself answers, which a dev key must never take.
local ENGINE_RESERVED: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.F9] = "the engine's developer console",
	[Enum.KeyCode.F11] = "the engine's fullscreen toggle",
	[Enum.KeyCode.F12] = "the engine's screenshot/record",
}

-- Every collision, as readable lines: a raw key used twice, a raw key also bound as a keyboard default, or an engine-reserved key.
-- Empty when the table is sound.
function DebugKeys.Clashes(): { string }
	local problems: { string } = {}
	local byKey: { [Enum.KeyCode]: string } = {}
	local names: { string } = {}
	for name in DebugKeys :: any do
		if typeof((DebugKeys :: any)[name]) == "EnumItem" then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for _, name in names do
		local key: Enum.KeyCode = (DebugKeys :: any)[name]
		if byKey[key] then
			table.insert(problems, `{key.Name}: raw dev keys {byKey[key]} and {name}`)
		end
		byKey[key] = name
		if ENGINE_RESERVED[key] then
			table.insert(problems, `{key.Name}: {name} takes a key reserved for {ENGINE_RESERVED[key]}`)
		end
	end
	for action, binding in KeybindConstants.Defaults :: any do
		local key = (binding :: any).KeyCode
		if key and byKey[key] then
			table.insert(problems, `{key.Name}: raw dev key {byKey[key]} and keybind action {action}`)
		end
	end
	return problems
end

return DebugKeys
