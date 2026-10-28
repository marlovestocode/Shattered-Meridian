--!strict
--[[
	WorldArchitect/Style.lua

	Owns: the World Architect console's reading rules. The console is used over a bright, busy 3D world for long
	sessions, so its prose and secondary text sit one step brighter than the admin panel's (Kit.Prose defaults to the
	disabled grey, which is right inside an opaque modal and too faint here), and the whole console is scaled up by
	READABILITY on top of the project's viewport curve (UI/ViewportScale).

	Does not own: the components (Components/*) or the panel vocabulary (DevMenu/Kit) -- this only picks their colours.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Kit = require(script.Parent.Parent.DevMenu.Kit)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local Style = {}

-- Multiplies ViewportScale's answer for the console: its type is small Detail/Body steps read over the world.
Style.Readability = 1.2

-- Secondary rather than disabled text for every explanatory line and row detail.
Style.Quiet = Tokens.Color.TextSecondary

function Style.Prose(
	scope: Scope,
	text: UsedAs<string>,
	order: number,
	visible: UsedAs<boolean>?,
	color: UsedAs<Color3>?
): Instance
	return Kit.Prose(scope, text, order, visible, color or Style.Quiet)
end

return Style
