--!strict
--[[
	ArmedButton.lua

	Owns: the two-press button every irreversible action in the authoring tools wears. The first press
	ARMS it and its text says so ("Delete? Again"); a second press inside WindowSeconds commits; the
	window lapsing disarms it. A stale timer from an earlier arm never disarms a later one (the stamp
	check below).

	PROMOTED FROM Screens/DevTools/MoveEditor/Fields.lua when the admin panel became its second caller,
	and the admin panel's old roster had a third, hand-rolled copy (two of them, in fact -- one per
	armed action, each with its own generation counter). Fields.ArmedButton is now a thin wrapper
	over this.

	THE LEGACY BUTTON PATH (Variant nil), deliberately: the text changes live, and a Variant button
	reads its text once (Components/Button.lua's header).

	Returns a holder Frame sized by the caller with the button filling it, so Visible and Size live on
	one object a layout can place.

	Does not own: what the action does (OnConfirm), or the window's length (the caller's constant --
	Constants.MoveEditor.ConfirmWindowSeconds, Constants.Debug.DevMenu.ConfirmWindowSeconds).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Button = require(script.Parent.Button)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ArmedButtonProps = {
	Idle: UsedAs<string>,
	-- What the button says while armed.
	Armed: string,
	WindowSeconds: number,
	Size: UsedAs<UDim2>,
	LayoutOrder: UsedAs<number>?,
	Disabled: UsedAs<boolean>?,
	Visible: UsedAs<boolean>?,
	OnConfirm: () -> (),
}

local function ArmedButton(scope: Scope, props: ArmedButtonProps): Frame
	local armed = scope:Value(false)
	local armedAt = 0
	return scope:New "Frame" {
		Name = "ArmedButton",
		Size = props.Size,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,

		[Fusion.Children] = Button(scope, {
			Text = scope:Computed(function(use)
				return if use(armed) then props.Armed else use(props.Idle)
			end),
			Size = UDim2.fromScale(1, 1),
			Disabled = props.Disabled,
			OnActivated = function()
				if peek(armed) then
					armed:set(false)
					props.OnConfirm()
					return
				end
				armed:set(true)
				local stamp = os.clock()
				armedAt = stamp
				task.delay(props.WindowSeconds, function()
					if armedAt == stamp then
						armed:set(false)
					end
				end)
			end,
		}),
	} :: Frame
end

return ArmedButton
